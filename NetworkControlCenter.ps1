<#
=====================================================================
 Network Control Center
 ---------------------------------------------------------------------
 Fast, native (WPF) control panel to change IP / mask / gateway / DNS /
 MTU / VLAN ID on your network adapters, plus one-click profiles for the
 gear you swap between in the field.

 KEY POINT: this script runs elevated. Launched from the installed
 shortcut (Install-Shortcut.ps1) it starts elevated directly; launched any
 other way it self-elevates ONCE. Either way: one UAC prompt per session.

 Speed: the adapter list from the last session is shown instantly from a
 cache and refreshed from live data in the background. All network
 queries/changes run in background runspaces, so the window never freezes.

 Safety net: every input is validated before anything is touched; if
 Windows rejects a change, the previous config is restored automatically;
 "Undo" puts back the last successful change; every change is logged to
 %APPDATA%\NetworkControlCenter\changes.log.

 Requirements : Windows 10 / 11, Windows PowerShell 5.1 (built in).
=====================================================================
#>

$script:AppVersion = '2.4.0'
$script:AppId      = 'FieldTools.NetworkControlCenter'

# ---------------------------------------------------------------------
# 1. SELF-ELEVATION  (single UAC / fingerprint prompt per launch)
# ---------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $psArgs  = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    try {
        # "conhost --headless" runs PowerShell with no console window at all. A plain
        # "-WindowStyle Hidden" is not enough on Windows 11: when Windows Terminal is the default
        # terminal it still opens (and keeps) an empty terminal window behind the app.
        if (Test-Path $conhost) {
            Start-Process -FilePath $conhost -ArgumentList "--headless `"$psExe`" $psArgs" -Verb RunAs | Out-Null
        } else {
            Start-Process -FilePath $psExe -ArgumentList $psArgs -Verb RunAs | Out-Null
        }
    } catch {
        # User dismissed the UAC prompt - just exit quietly.
    }
    exit
}

# ---------------------------------------------------------------------
# 2. ASSEMBLIES, DPI & APP IDENTITY
# ---------------------------------------------------------------------
# powershell.exe has no DPI manifest, so Windows treats it as DPI-unaware: on a 125/150% screen it
# draws the window at 100% and stretches the bitmap, which blurs every glyph. Declare per-monitor
# (v2) awareness before any window exists, and tell WPF to scale itself per monitor (these switches
# are off by default for a host like powershell.exe). Text is then rendered natively at each
# screen's scale, also after the window moves to a monitor with a different scale.
[AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false)
[AppContext]::SetSwitch('Switch.System.Windows.DoNotUsePresentationDpiCapabilityTier2OrGreater', $false)
[AppContext]::SetSwitch('Switch.System.Windows.DoNotUsePresentationDpiCapabilityTier3OrGreater', $false)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$ErrorActionPreference = 'Continue'

# Native calls through a Reflection.Emit P/Invoke stub, because Add-Type would start the C#
# compiler (~1s) on every launch.
function New-NativeStub {
    $asm = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
        (New-Object Reflection.AssemblyName 'NccInterop'), [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $tb = $asm.DefineDynamicModule('NccInterop').DefineType('NccNative', 'Public, Class')
    $attrs = [Reflection.MethodAttributes]'Public, Static, PinvokeImpl'
    $m = $tb.DefinePInvokeMethod('SetCurrentProcessExplicitAppUserModelID', 'shell32.dll', $attrs,
        [Reflection.CallingConventions]::Standard, [int], [Type[]]@([string]),
        [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::Unicode)
    $m.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
    $m = $tb.DefinePInvokeMethod('SetProcessDpiAwarenessContext', 'user32.dll', $attrs,
        [Reflection.CallingConventions]::Standard, [bool], [Type[]]@([IntPtr]),
        [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::Auto)
    $m.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
    return $tb.CreateType()
}
try { $script:Native = New-NativeStub } catch { $script:Native = $null }

# -4 = DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (Windows 10 1703+). On older builds the call
# fails and the window just stays bitmap-scaled, as before.
if ($script:Native) {
    try { [void]$script:Native.GetMethod('SetProcessDpiAwarenessContext').Invoke($null, [object[]]@([IntPtr](-4))) } catch { }
}

# Explicit AppUserModelID = the same ID the installed shortcut carries, so Windows groups this
# window under the pinned taskbar button instead of showing a generic PowerShell icon.
function Set-AppIdentity([string]$Id) {
    if (-not $script:Native) { return }
    try { [void]$script:Native.GetMethod('SetCurrentProcessExplicitAppUserModelID').Invoke($null, [object[]]@($Id)) } catch { }
}
Set-AppIdentity $script:AppId

# ---------------------------------------------------------------------
# 3. USER INTERFACE (XAML)
#    Single-quoted here-string -> nothing is interpolated by PowerShell.
#    Glyphs are Segoe Fluent Icons / Segoe MDL2 Assets code points.
# ---------------------------------------------------------------------
$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Network Control Center" Height="760" Width="1180"
    MinHeight="560" MinWidth="980" WindowStartupLocation="Manual"
    Background="#F2F2F7" Foreground="#1D1D1F"
    FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
    UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">

  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <!-- Optical sizes, like SF Pro Display/Text: the Display cut is drawn tighter for large titles -->
    <FontFamily x:Key="Display">Segoe UI Variable Display, Segoe UI</FontFamily>

    <!-- ===== Motion =====
         Press responds at once (80 ms) and settles back with an ease-out (no overshoot); hover fades.
         Storyboards have no From, so an interrupted animation continues from where it is. -->
    <CubicEase x:Key="EaseOut" EasingMode="EaseOut"/>
    <Storyboard x:Key="PressIn">
      <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="0.97" Duration="0:0:0.08" EasingFunction="{StaticResource EaseOut}"/>
      <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="0.97" Duration="0:0:0.08" EasingFunction="{StaticResource EaseOut}"/>
      <DoubleAnimation Storyboard.TargetName="pv" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.06"/>
    </Storyboard>
    <Storyboard x:Key="PressOut">
      <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.3" EasingFunction="{StaticResource EaseOut}"/>
      <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.3" EasingFunction="{StaticResource EaseOut}"/>
      <DoubleAnimation Storyboard.TargetName="pv" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.25"/>
    </Storyboard>
    <Storyboard x:Key="HoverIn"><DoubleAnimation Storyboard.TargetName="ov" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.12"/></Storyboard>
    <Storyboard x:Key="HoverOut"><DoubleAnimation Storyboard.TargetName="ov" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.25"/></Storyboard>

    <!-- ===== Buttons: one template; hover/press are translucent overlays so it works on any colour ===== -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#1D1D1F"/>
      <Setter Property="BorderBrush" Value="#D2D2D7"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid x:Name="root" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
              <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8"/>
              <Border x:Name="ov" Background="#0B000000" Opacity="0" CornerRadius="8"/>
              <Border x:Name="pv" Background="#14000000" Opacity="0" CornerRadius="8"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center"
                                HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions><BeginStoryboard Storyboard="{StaticResource HoverIn}"/></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard Storyboard="{StaticResource HoverOut}"/></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions><BeginStoryboard Storyboard="{StaticResource PressIn}"/></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard Storyboard="{StaticResource PressOut}"/></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnAccent" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#0071E3"/>
      <Setter Property="BorderBrush" Value="#0071E3"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="BtnGhost" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
    </Style>
    <Style x:Key="Glyph" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <!-- Toolbar-style icon-over-label buttons for adapter actions: no chrome until hovered -->
    <Style x:Key="ActionTile" TargetType="Button">
      <Setter Property="Width" Value="96"/>
      <Setter Property="Height" Value="74"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#1D1D1F"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid x:Name="root" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
              <Border x:Name="ov" Background="#E3E3E8" Opacity="0" CornerRadius="10"/>
              <Border x:Name="pv" Background="#0F000000" Opacity="0" CornerRadius="10"/>
              <ContentPresenter Margin="4,8,4,6" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions><BeginStoryboard Storyboard="{StaticResource HoverIn}"/></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard Storyboard="{StaticResource HoverOut}"/></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions><BeginStoryboard Storyboard="{StaticResource PressIn}"/></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard Storyboard="{StaticResource PressOut}"/></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ActionGlyph" TargetType="TextBlock" BasedOn="{StaticResource Glyph}">
      <Setter Property="FontSize" Value="20"/>
      <Setter Property="Foreground" Value="#0071E3"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="ActionText" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,6,0,0"/>
      <Setter Property="TextAlignment" Value="Center"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
    </Style>

    <!-- ===== Text boxes: filled, accent border + soft focus ring, Tag = placeholder =====
         The ring sits outside the field (negative margin), so focusing never shifts the text. -->
    <Style TargetType="TextBox">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Padding" Value="9,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Background" Value="#F2F2F7"/>
      <Setter Property="BorderBrush" Value="#F2F2F7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Grid>
              <Border x:Name="ring" Margin="-3" CornerRadius="11" BorderBrush="#590071E3" BorderThickness="3" Opacity="0"/>
              <Border x:Name="bd" CornerRadius="8" Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
                <Grid>
                  <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
                  <TextBlock x:Name="ph" Text="{TemplateBinding Tag}" Foreground="#A1A1A6" FontFamily="Segoe UI" FontSize="12.5"
                             Margin="{TemplateBinding Padding}" Padding="2,0,0,0" IsHitTestVisible="False" Visibility="Collapsed"
                             VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
                </Grid>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Text" Value=""><Setter TargetName="ph" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#D2D2D7"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#0071E3"/>
                <Setter TargetName="bd" Property="Background" Value="White"/>
                <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="ring" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.15"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="ring" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.2"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== Editable combo boxes in the same look, with a rounded menu ===== -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="bd" Background="Transparent" CornerRadius="6" Padding="9,6" Margin="0,1">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="bd" Property="Background" Value="#EAF2FD"/></Trigger>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#0071E3"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Height" Value="34"/>
      <Setter Property="IsEditable" Value="True"/>
      <Setter Property="MaxDropDownHeight" Value="320"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="ring" Margin="-3" CornerRadius="11" BorderBrush="#590071E3" BorderThickness="3" Opacity="0"/>
              <Border x:Name="bd" CornerRadius="8" Background="#F2F2F7" BorderBrush="#F2F2F7" BorderThickness="1"/>
              <TextBox x:Name="PART_EditableTextBox" Style="{x:Null}" Margin="1,1,30,1" Padding="8,0,0,0"
                       Background="Transparent" BorderThickness="0" VerticalContentAlignment="Center"
                       FontFamily="{TemplateBinding FontFamily}" FontSize="{TemplateBinding FontSize}"
                       IsReadOnly="{TemplateBinding IsReadOnly}"/>
              <ToggleButton HorizontalAlignment="Right" Width="30" Focusable="False" Cursor="Hand"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent">
                      <TextBlock Text="&#xE70D;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10"
                                 Foreground="#6E6E73" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                <!-- Shadow on a separate empty layer, so the list text keeps ClearType (see Tile). -->
                <Grid Margin="0,6,14,14" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                      MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <Border Background="White" CornerRadius="10">
                    <Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="5" Opacity="0.18"/></Border.Effect>
                  </Border>
                  <!-- A transparent popup turns ClearType off; the list surface is opaque, so turn it back on -->
                  <Border Background="White" BorderBrush="#1F000000" BorderThickness="0.5" CornerRadius="10" RenderOptions.ClearTypeHint="Enabled">
                    <ScrollViewer Margin="5" VerticalScrollBarVisibility="Auto">
                      <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                    </ScrollViewer>
                  </Border>
                </Grid>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#D2D2D7"/></Trigger>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#0071E3"/>
                <Setter TargetName="bd" Property="Background" Value="White"/>
                <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="ring" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.15"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="ring" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.2"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== Typography & cards ===== -->
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#3A3A3C"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="LabelIcon" TargetType="TextBlock" BasedOn="{StaticResource Glyph}">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#8E8E93"/>
      <Setter Property="Margin" Value="0,0,7,0"/>
    </Style>
    <Style x:Key="FieldHead" TargetType="StackPanel">
      <Setter Property="Orientation" Value="Horizontal"/>
      <Setter Property="Margin" Value="2,0,0,6"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6E6E73"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6E6E73"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Display}"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <!-- Settings-style coloured squares: each card keeps one colour, so it can be found at a glance -->
    <Style x:Key="CardIcon" TargetType="Border">
      <Setter Property="Width" Value="28"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="CornerRadius" Value="7"/>
      <Setter Property="Background" Value="#0A84FF"/>
      <Setter Property="Margin" Value="0,0,11,0"/>
    </Style>
    <!-- Grouped cards: white on the grey page, no outline or shadow (only things you click float) -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="20"/>
      <Setter Property="Margin" Value="0,0,0,16"/>
    </Style>
    <Style x:Key="InfoKey" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6E6E73"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
    <Style x:Key="InfoVal" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>

    <!-- Segmented control (DHCP / Manual) -->
    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#6E6E73"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <!-- Shadow on a separate empty layer, so the label keeps ClearType (see Tile).
                 The selected "pill" fades in/out instead of jumping. -->
            <Grid Margin="2">
              <Border x:Name="sh" Background="White" CornerRadius="7" Opacity="0">
                <Border.Effect><DropShadowEffect BlurRadius="6" ShadowDepth="1" Opacity="0.16"/></Border.Effect>
              </Border>
              <Border x:Name="sel" Background="White" CornerRadius="7" Opacity="0"/>
              <Border x:Name="bd" Background="Transparent" CornerRadius="7" Padding="14,7">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#1D1D1F"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter Property="FontWeight" Value="SemiBold"/>
                <Setter Property="Foreground" Value="#1D1D1F"/>
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sel" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.18"/>
                  <DoubleAnimation Storyboard.TargetName="sh" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.18"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sel" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.18"/>
                  <DoubleAnimation Storyboard.TargetName="sh" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.18"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Toggle switch -->
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <!-- The knob slides and the track colour blends; the knob's shadow has no text to blur. -->
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Grid Width="38" Height="22" VerticalAlignment="Center">
                <Border x:Name="track" CornerRadius="11">
                  <Border.Background><SolidColorBrush Color="#E3E3E8"/></Border.Background>
                </Border>
                <Ellipse x:Name="thumb" Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="2,0,0,0">
                  <Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform>
                  <Ellipse.Effect><DropShadowEffect BlurRadius="4" ShadowDepth="1" Opacity="0.25"/></Ellipse.Effect>
                </Ellipse>
              </Grid>
              <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="thumb" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="16" Duration="0:0:0.22" EasingFunction="{StaticResource EaseOut}"/>
                  <ColorAnimation Storyboard.TargetName="track" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#0071E3" Duration="0:0:0.22"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="thumb" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="0" Duration="0:0:0.22" EasingFunction="{StaticResource EaseOut}"/>
                  <ColorAnimation Storyboard.TargetName="track" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#E3E3E8" Duration="0:0:0.22"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== Adapter tiles ===== -->
    <Style x:Key="Tile" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <!-- The shadow lives on its own empty layer: a WPF Effect turns everything inside it
                 into a bitmap without ClearType, which made the tile text look blurry. -->
            <Grid x:Name="root" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
              <Border Background="White" CornerRadius="14">
                <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="1" Opacity="0.07"/></Border.Effect>
              </Border>
              <Border x:Name="ov" Background="White" CornerRadius="14" Opacity="0">
                <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="6" Opacity="0.13"/></Border.Effect>
              </Border>
              <Border x:Name="bd" Background="White" BorderBrush="#0D000000" BorderThickness="1" CornerRadius="14" Padding="14,12">
                <ContentPresenter/>
              </Border>
              <Border x:Name="pv" Background="#0A000000" CornerRadius="14" Opacity="0" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions><BeginStoryboard Storyboard="{StaticResource HoverIn}"/></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard Storyboard="{StaticResource HoverOut}"/></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions><BeginStoryboard Storyboard="{StaticResource PressIn}"/></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard Storyboard="{StaticResource PressOut}"/></Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <DataTemplate x:Key="TileBody">
      <Grid>
        <!-- Cached (last session) data is drawn faded until the live scan replaces it -->
        <Grid.Style>
          <Style TargetType="Grid">
            <Style.Triggers>
              <DataTrigger Binding="{Binding Cached}" Value="True"><Setter Property="Opacity" Value="0.55"/></DataTrigger>
            </Style.Triggers>
          </Style>
        </Grid.Style>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Width="42" Height="42" CornerRadius="10" Background="{Binding IconBg}" VerticalAlignment="Center">
          <TextBlock Text="{Binding Glyph}" FontFamily="{StaticResource Icons}" FontSize="20"
                     Foreground="{Binding IconFg}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Grid.Column="1" Margin="12,0,6,0" VerticalAlignment="Center">
          <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="14" TextTrimming="CharacterEllipsis"/>
          <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
            <Ellipse Width="7" Height="7" Fill="{Binding StatusBrush}" VerticalAlignment="Center"/>
            <TextBlock Text="{Binding StatusText}" Foreground="#6E6E73" FontSize="12" Margin="6,0,0,0"/>
          </StackPanel>
          <TextBlock Text="{Binding IPText}" FontFamily="Consolas" FontSize="12" Foreground="#3A3A3C" Margin="0,4,0,0"
                     TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <TextBlock Grid.Column="2" Text="&#xE76C;" FontFamily="{StaticResource Icons}" FontSize="11"
                   Foreground="#C7C7CC" VerticalAlignment="Center"/>
      </Grid>
    </DataTemplate>
    <!-- Wired tiles plug into the laptop with a cable; wireless ones show radio waves -->
    <DataTemplate x:Key="TileLeft">
      <Grid Margin="0,0,0,12">
        <Grid.ColumnDefinitions><ColumnDefinition Width="270"/><ColumnDefinition Width="46"/></Grid.ColumnDefinitions>
        <Button Style="{StaticResource Tile}" Content="{Binding}" ContentTemplate="{StaticResource TileBody}" ToolTip="{Binding Tooltip}"/>
        <Grid Grid.Column="1" VerticalAlignment="Center">
          <Border Height="4" CornerRadius="2" Background="{Binding CableBrush}" Margin="0,0,9,0"/>
          <Border Width="12" Height="14" CornerRadius="2" Background="{Binding CableBrush}" HorizontalAlignment="Right" Margin="0,0,-10,0"/>
        </Grid>
      </Grid>
    </DataTemplate>
    <DataTemplate x:Key="TileRight">
      <Grid Margin="0,0,0,12">
        <Grid.ColumnDefinitions><ColumnDefinition Width="46"/><ColumnDefinition Width="270"/></Grid.ColumnDefinitions>
        <TextBlock Text="&#xE701;" FontFamily="{StaticResource Icons}" FontSize="22" Foreground="{Binding CableBrush}"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
        <Button Grid.Column="1" Style="{StaticResource Tile}" Content="{Binding}" ContentTemplate="{StaticResource TileBody}" ToolTip="{Binding Tooltip}"/>
      </Grid>
    </DataTemplate>
    <DataTemplate x:Key="TileSmall">
      <Button Width="270" Margin="0,0,12,12" Style="{StaticResource Tile}" Content="{Binding}"
              ContentTemplate="{StaticResource TileBody}" ToolTip="{Binding Tooltip}"/>
    </DataTemplate>

    <!-- ===== Profile chips: the name loads the profile, the x deletes it ===== -->
    <Style x:Key="ChipBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="Transparent" CornerRadius="14" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#D6E7FB"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#C2DBF8"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <DataTemplate x:Key="Chip">
      <Border Background="#EAF2FD" CornerRadius="16" Margin="0,0,8,8">
        <StackPanel Orientation="Horizontal">
          <Button Style="{StaticResource ChipBtn}" Padding="12,6,6,6" CommandParameter="load" ToolTip="{Binding Summary}">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="{Binding Glyph}" FontFamily="{StaticResource Icons}" FontSize="12" Foreground="#0071E3"
                         VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Text="{Binding Name}" Foreground="#0066CC" FontWeight="SemiBold"/>
            </StackPanel>
          </Button>
          <Button Style="{StaticResource ChipBtn}" Padding="6,6,10,6" CommandParameter="delete" ToolTip="Delete this profile">
            <TextBlock Text="&#xE711;" FontFamily="{StaticResource Icons}" FontSize="9" Foreground="#6E9BD0"/>
          </Button>
        </StackPanel>
      </Border>
    </DataTemplate>

    <!-- ===== Slim Windows 11 style scrollbars ===== -->
    <ControlTemplate x:Key="ThumbTemplate" TargetType="Thumb">
      <Border x:Name="th" Background="#C7C7CC" CornerRadius="3"/>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="th" Property="Background" Value="#8E8E93"/></Trigger>
        <Trigger Property="IsDragging" Value="True"><Setter TargetName="th" Property="Background" Value="#6E6E73"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <!-- Invisible track halves: clicking above/below the thumb pages up/down -->
    <Style x:Key="ScrollPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="14"/>
      <Setter Property="MinWidth" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
                <Track.Thumb><Thumb x:Name="thumb" Template="{StaticResource ThumbTemplate}" Width="6" Margin="0,3"/></Track.Thumb>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="thumb" Property="Width" Value="9"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="14"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="Transparent">
                  <Track x:Name="PART_Track">
                    <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                    <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
                    <Track.Thumb><Thumb x:Name="thumb" Template="{StaticResource ThumbTemplate}" Height="6" Margin="3,0"/></Track.Thumb>
                  </Track>
                </Grid>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="thumb" Property="Height" Value="9"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- Scroll-edge fades over a page's ScrollViewer (shown by Update-ScrollEdges) -->
    <Style x:Key="EdgeTop" TargetType="Border">
      <Setter Property="Height" Value="22"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
      <Setter Property="Margin" Value="0,0,14,0"/>
      <Setter Property="IsHitTestVisible" Value="False"/>
      <Setter Property="Visibility" Value="Collapsed"/>
      <Setter Property="Background">
        <Setter.Value>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF2F2F7" Offset="0"/><GradientStop Color="#00F2F2F7" Offset="1"/></LinearGradientBrush>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="EdgeBottom" TargetType="Border" BasedOn="{StaticResource EdgeTop}">
      <Setter Property="Height" Value="30"/>
      <Setter Property="VerticalAlignment" Value="Bottom"/>
      <Setter Property="Background">
        <Setter.Value>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#00F2F2F7" Offset="0"/><GradientStop Color="#FFF2F2F7" Offset="1"/></LinearGradientBrush>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Keyboard keys for the laptop drawing -->
    <DrawingBrush x:Key="Keys" TileMode="Tile" Viewport="0,0,13,9" ViewportUnits="Absolute" Viewbox="0,0,13,9" ViewboxUnits="Absolute">
      <DrawingBrush.Drawing>
        <DrawingGroup>
          <GeometryDrawing Brush="#202328"><GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,13,9"/></GeometryDrawing.Geometry></GeometryDrawing>
          <GeometryDrawing Brush="#3A4049"><GeometryDrawing.Geometry><RectangleGeometry Rect="1,1,11,7" RadiusX="1.6" RadiusY="1.6"/></GeometryDrawing.Geometry></GeometryDrawing>
        </DrawingGroup>
      </DrawingBrush.Drawing>
    </DrawingBrush>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>   <!-- app bar  -->
      <RowDefinition Height="*"/>      <!-- pages    -->
      <RowDefinition Height="Auto"/>   <!-- status   -->
    </Grid.RowDefinitions>

    <!-- ============ App bar ============ -->
    <!-- One continuous surface with the page (unified toolbar): no divider line -->
    <Border Grid.Row="0" Background="#F2F2F7" Padding="20,12,20,4">
      <Grid>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="30" Height="30" CornerRadius="8">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#2E9BFF" Offset="0"/><GradientStop Color="#0068D6" Offset="1"/></LinearGradientBrush>
            </Border.Background>
            <TextBlock Text="&#xE7F8;" Style="{StaticResource Glyph}" Foreground="White" FontSize="16" HorizontalAlignment="Center"/>
          </Border>
          <TextBlock Text="Network Control Center" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center" Margin="11,0,0,0"/>
          <TextBlock x:Name="txtVersion" Foreground="#8E8E93" FontSize="12" VerticalAlignment="Center" Margin="8,1,0,0"/>
        </StackPanel>
        <StackPanel x:Name="pnlAppBar" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock x:Name="txtScanGlyph" Text="&#xE895;" Style="{StaticResource Glyph}" FontSize="12" Foreground="#8E8E93" Margin="0,0,6,0"/>
          <TextBlock x:Name="txtScanState" Foreground="#6E6E73" FontSize="12" VerticalAlignment="Center" Margin="0,0,18,0"/>
          <CheckBox x:Name="chkShowAll" Style="{StaticResource Switch}" Content="Show virtual adapters"
                    VerticalAlignment="Center" Margin="0,0,16,0"
                    ToolTip="Also show VPN, Hyper-V, Bluetooth and other virtual adapters"/>
          <Button x:Name="btnRefresh" Style="{StaticResource Btn}" ToolTip="Rescan adapters (F5)">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE72C;" Style="{StaticResource Glyph}"/>
              <TextBlock Text="Refresh" Margin="8,0,0,0"/>
            </StackPanel>
          </Button>
          <Border Margin="12,0,0,0" CornerRadius="12" Background="#E3E3E8" Padding="10,4" VerticalAlignment="Center"
                  ToolTip="Running as administrator: changes apply without further prompts">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE7EF;" Style="{StaticResource Glyph}" FontSize="12" Foreground="#3A3A3C"/>
              <TextBlock Text="Admin" Foreground="#3A3A3C" FontSize="12" FontWeight="SemiBold" Margin="6,0,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ============ HOME: the laptop and its connections ============ -->
    <Grid x:Name="pnlHome" Grid.Row="1" Margin="24,10,24,14">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0">
        <TextBlock Text="Connections" FontFamily="{StaticResource Display}" FontSize="30" FontWeight="SemiBold"/>
        <TextBlock Text="Click a connection to change its IP address, gateway, DNS and more." Style="{StaticResource Hint}" FontSize="13" Margin="1,2,0,0"/>
      </StackPanel>

      <!-- The stage scales down on small screens instead of being cut off -->
      <Viewbox x:Name="vbStage" Grid.Row="1" Stretch="Uniform" StretchDirection="DownOnly" Margin="0,6,0,6">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="320"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="320"/>
          </Grid.ColumnDefinitions>

          <StackPanel Grid.Column="0" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,-22,2">
            <StackPanel Orientation="Horizontal" Margin="2,0,0,10">
              <TextBlock Text="&#xE839;" Style="{StaticResource Glyph}" FontSize="12" Foreground="#6E6E73" Margin="0,0,6,0"/>
              <TextBlock Text="WIRED" Style="{StaticResource Section}"/>
            </StackPanel>
            <ItemsControl x:Name="icWired" ItemTemplate="{StaticResource TileLeft}"/>
            <TextBlock x:Name="txtNoWired" Text="No wired adapters found" Style="{StaticResource Hint}" Margin="2,0,56,24"/>
          </StackPanel>

          <!-- Laptop illustration (HP-style: dark lid, hp mark, silver keyboard deck) -->
          <Grid Grid.Column="1" Width="460" Height="304" VerticalAlignment="Center">
            <Ellipse Width="470" Height="26" VerticalAlignment="Top" Margin="0,282,0,0">
              <Ellipse.Fill>
                <RadialGradientBrush><GradientStop Color="#38000000" Offset="0"/><GradientStop Color="#00000000" Offset="1"/></RadialGradientBrush>
              </Ellipse.Fill>
            </Ellipse>
            <!-- lid -->
            <Border Width="340" Height="220" VerticalAlignment="Top" CornerRadius="12,12,3,3" Padding="9,9,9,22">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#3B4048" Offset="0"/><GradientStop Color="#1D2025" Offset="1"/></LinearGradientBrush>
              </Border.Background>
              <Border CornerRadius="4" ClipToBounds="True">
                <Grid>
                  <Grid.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                      <GradientStop Color="#082A66" Offset="0"/>
                      <GradientStop Color="#1154C2" Offset="0.55"/>
                      <GradientStop Color="#3C8DF0" Offset="1"/>
                    </LinearGradientBrush>
                  </Grid.Background>
                  <Ellipse Width="300" Height="170" Opacity="0.55" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="-80,-70,0,0">
                    <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#8CCBFF" Offset="0"/><GradientStop Color="#008CCBFF" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
                  </Ellipse>
                  <Ellipse Width="260" Height="160" Opacity="0.5" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,-70,-60">
                    <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#B49CFF" Offset="0"/><GradientStop Color="#00B49CFF" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
                  </Ellipse>
                  <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Margin="0,-12,0,0">
                    <Grid Width="46" Height="46" HorizontalAlignment="Center">
                      <Ellipse Stroke="White" StrokeThickness="2.2"/>
                      <TextBlock Text="hp" FontFamily="Segoe UI" FontStyle="Italic" FontWeight="Bold" FontSize="21"
                                 Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-4,0,0"/>
                    </Grid>
                    <TextBlock x:Name="txtHostName" Foreground="White" FontSize="15" FontWeight="SemiBold"
                               HorizontalAlignment="Center" Margin="0,9,0,0"/>
                    <Border Background="#33FFFFFF" CornerRadius="9" Padding="9,3" Margin="0,6,0,0" HorizontalAlignment="Center">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock x:Name="txtScreenGlyph" Style="{StaticResource Glyph}" FontSize="11" Foreground="White" Margin="0,0,6,0"/>
                        <TextBlock x:Name="txtOnline" Foreground="White" FontSize="11"/>
                      </StackPanel>
                    </Border>
                  </StackPanel>
                  <!-- mini taskbar -->
                  <Border VerticalAlignment="Bottom" Height="15" Background="#40FFFFFF">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                      <Border Width="8" Height="8" CornerRadius="1.5" Background="#E6FFFFFF" Margin="2,0"/>
                      <Border Width="8" Height="8" CornerRadius="1.5" Background="#99FFFFFF" Margin="2,0"/>
                      <Border Width="8" Height="8" CornerRadius="1.5" Background="#99FFFFFF" Margin="2,0"/>
                      <Border Width="8" Height="8" CornerRadius="1.5" Background="#FFFFD86B" Margin="2,0"/>
                      <Border Width="8" Height="8" CornerRadius="1.5" Background="#99FFFFFF" Margin="2,0"/>
                    </StackPanel>
                  </Border>
                </Grid>
              </Border>
            </Border>
            <Ellipse Width="4" Height="4" Fill="#0B0D10" Stroke="#4A505A" StrokeThickness="0.6" VerticalAlignment="Top" Margin="0,3,0,0"/>
            <!-- hp mark on the lower bezel -->
            <Grid Width="13" Height="13" VerticalAlignment="Top" Margin="0,203,0,0">
              <Ellipse Stroke="#A9B1BB" StrokeThickness="1"/>
              <TextBlock Text="hp" FontFamily="Segoe UI" FontStyle="Italic" FontWeight="Bold" FontSize="6.5" Foreground="#A9B1BB"
                         HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-1.5,0,0"/>
            </Grid>
            <!-- hinge -->
            <Border Width="300" Height="5" VerticalAlignment="Top" Margin="0,219,0,0" CornerRadius="0,0,3,3" Background="#15181C"/>
            <!-- keyboard deck (perspective) -->
            <Path StrokeThickness="1" Stroke="#A7AEB6" StrokeLineJoin="Round" Data="M 60,222 L 400,222 L 452,284 L 8,284 Z">
              <Path.Fill>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#E6E9ED" Offset="0"/><GradientStop Color="#C5CBD2" Offset="1"/></LinearGradientBrush>
              </Path.Fill>
            </Path>
            <Path Fill="{StaticResource Keys}" Stroke="#9AA1AA" StrokeThickness="0.6" StrokeLineJoin="Round" Data="M 88,228 L 372,228 L 404,258 L 56,258 Z"/>
            <Path Fill="#D8DCE1" Stroke="#B3BAC2" StrokeThickness="0.8" StrokeLineJoin="Round" Data="M 198,262 L 262,262 L 266,279 L 194,279 Z"/>
            <!-- side ports -->
            <Path Fill="#3E444D" Data="M 22,266 L 32,266 L 34,269 L 24,269 Z"/>
            <Path Fill="#3E444D" Data="M 16,273 L 30,273 L 32,278 L 18,278 Z"/>
            <Path Fill="#3E444D" Data="M 428,266 L 438,266 L 436,269 L 426,269 Z"/>
            <!-- front edge with thumb notch -->
            <Path Fill="#9EA5AE" Data="M 8,284 L 452,284 L 447,292 Q 446,294 443,294 L 17,294 Q 14,294 13,292 Z"/>
            <Border Width="56" Height="3" VerticalAlignment="Top" Margin="0,284,0,0" CornerRadius="0,0,3,3" Background="#858C95"/>
          </Grid>

          <StackPanel Grid.Column="2" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="0,0,0,40">
            <StackPanel Orientation="Horizontal" Margin="48,0,0,10">
              <TextBlock Text="&#xE701;" Style="{StaticResource Glyph}" FontSize="12" Foreground="#6E6E73" Margin="0,0,6,0"/>
              <TextBlock Text="WIRELESS" Style="{StaticResource Section}"/>
            </StackPanel>
            <ItemsControl x:Name="icWireless" ItemTemplate="{StaticResource TileRight}"/>
            <TextBlock x:Name="txtNoWireless" Text="No wireless adapters found" Style="{StaticResource Hint}" Margin="48,0,0,0"/>
          </StackPanel>
        </Grid>
      </Viewbox>

      <StackPanel x:Name="pnlVirtual" Grid.Row="2" Margin="0,0,0,2">
        <StackPanel Orientation="Horizontal" Margin="2,0,0,10">
          <TextBlock Text="&#xE968;" Style="{StaticResource Glyph}" FontSize="12" Foreground="#6E6E73" Margin="0,0,6,0"/>
          <TextBlock Text="VIRTUAL &amp; OTHER" Style="{StaticResource Section}"/>
        </StackPanel>
        <ItemsControl x:Name="icVirtual" ItemTemplate="{StaticResource TileSmall}">
          <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
        </ItemsControl>
      </StackPanel>

      <!-- Quick tools -->
      <Border x:Name="pnlHomeTools" Grid.Row="3" Style="{StaticResource Card}" Padding="16,12" Margin="0,4,0,0">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Border Style="{StaticResource CardIcon}" Background="#34C759">
              <TextBlock Text="&#xE9D9;" Style="{StaticResource Glyph}" Foreground="White" HorizontalAlignment="Center"/>
            </Border>
            <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
              <TextBlock Text="Ping" FontWeight="SemiBold"/>
              <TextBlock x:Name="txtPingHomeHint" Text="your default gateway" Style="{StaticResource Hint}" FontSize="11" Width="150" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <TextBox x:Name="txtPingHome" Width="170" FontFamily="Consolas" Tag="IP or hostname"
                     ToolTip="Pre-filled with your default gateway - type any IP or hostname to ping something else"/>
            <Button x:Name="btnPingHome" Style="{StaticResource BtnAccent}" Margin="8,0,0,0" Padding="16,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE768;" Style="{StaticResource Glyph}" FontSize="12"/>
                <TextBlock Text="Ping" Margin="7,0,0,0"/>
              </StackPanel>
            </Button>
          </StackPanel>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="btnFlushDns" Style="{StaticResource Btn}" Margin="0,0,8,0" ToolTip="Clear the DNS resolver cache (ipconfig /flushdns)">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE774;" Style="{StaticResource Glyph}" Foreground="#0071E3"/>
                <TextBlock Text="Flush DNS" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="btnClearArp" Style="{StaticResource Btn}" Margin="0,0,8,0" ToolTip="Clear the ARP cache - use after swapping devices that share an IP">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE895;" Style="{StaticResource Glyph}" Foreground="#0071E3"/>
                <TextBlock Text="Clear ARP" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="btnOpenData" Style="{StaticResource Btn}" ToolTip="Profiles and the change log live here">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE838;" Style="{StaticResource Glyph}" Foreground="#0071E3"/>
                <TextBlock Text="Log &amp; data" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>

    <!-- ============ NIC PAGE ============ -->
    <Grid x:Name="pnlConfig" Grid.Row="1" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Header -->
      <Grid Grid.Row="0" Margin="20,12,24,12">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <!-- Adapter actions: always visible, icon over label -->
        <StackPanel x:Name="pnlAdapterActions" Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
          <StackPanel.Resources>
            <Style TargetType="Button" BasedOn="{StaticResource ActionTile}">
              <Setter Property="Width" Value="78"/>
              <Setter Property="Height" Value="60"/>
              <Setter Property="Margin" Value="2,0,0,0"/>
            </Style>
          </StackPanel.Resources>
          <Button x:Name="btnDhcp" ToolTip="Switch to automatic addressing (DHCP) right away">
            <StackPanel>
              <TextBlock Text="&#xE8AB;" Style="{StaticResource ActionGlyph}" FontSize="18"/>
              <TextBlock Text="DHCP now" Style="{StaticResource ActionText}" Margin="0,4,0,0"/>
            </StackPanel>
          </Button>
          <Button x:Name="btnRenew" ToolTip="Ask the DHCP server for a new address (ipconfig /renew)">
            <StackPanel>
              <TextBlock Text="&#xE72C;" Style="{StaticResource ActionGlyph}" FontSize="18"/>
              <TextBlock Text="Renew" Style="{StaticResource ActionText}" Margin="0,4,0,0"/>
            </StackPanel>
          </Button>
          <Button x:Name="btnRestart" ToolTip="Disable and re-enable the adapter">
            <StackPanel>
              <TextBlock Text="&#xE777;" Style="{StaticResource ActionGlyph}" FontSize="18"/>
              <TextBlock Text="Restart" Style="{StaticResource ActionText}" Margin="0,4,0,0"/>
            </StackPanel>
          </Button>
          <Button x:Name="btnToggleEnable">
            <StackPanel>
              <TextBlock x:Name="txtToggleGlyph" Text="&#xE7E8;" Style="{StaticResource ActionGlyph}" FontSize="18" Foreground="#FF3B30"/>
              <TextBlock x:Name="txtToggleEnable" Text="Disable" Style="{StaticResource ActionText}" Margin="0,4,0,0"/>
            </StackPanel>
          </Button>
          <Button x:Name="btnCopy" ToolTip="Copy a text summary of this adapter (for tickets / reports)">
            <StackPanel>
              <TextBlock Text="&#xE8C8;" Style="{StaticResource ActionGlyph}" FontSize="18"/>
              <TextBlock Text="Copy info" Style="{StaticResource ActionText}" Margin="0,4,0,0"/>
            </StackPanel>
          </Button>
        </StackPanel>
        <Button x:Name="btnBack" Style="{StaticResource BtnGhost}" Height="34" Padding="6,0,10,0" VerticalAlignment="Center" ToolTip="Back to all connections (Esc)">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE76B;" Style="{StaticResource Glyph}" FontSize="13" Foreground="#0071E3"/>
            <TextBlock Text="Connections" Foreground="#0071E3" FontSize="13.5" Margin="5,0,0,0"/>
          </StackPanel>
        </Button>
        <Border x:Name="bdAdapterIcon" Grid.Column="1" Width="50" Height="50" CornerRadius="12" Margin="12,0,14,0" Background="#EAF2FD">
          <TextBlock x:Name="txtAdapterGlyph" Style="{StaticResource Glyph}" FontSize="24" Foreground="#0066CC" HorizontalAlignment="Center"/>
        </Border>
        <StackPanel Grid.Column="2" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="txtAdapterName" FontFamily="{StaticResource Display}" FontSize="26" FontWeight="SemiBold"/>
            <Border x:Name="bdStatusPill" CornerRadius="11" Padding="10,2" Margin="12,0,0,0" VerticalAlignment="Center">
              <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="elStatusDot" Width="8" Height="8" VerticalAlignment="Center"/>
                <TextBlock x:Name="txtStatusPill" FontSize="12" Margin="6,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
          </StackPanel>
          <TextBlock x:Name="txtDetail" Foreground="#6E6E73" FontSize="12.5" Margin="1,2,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1" Margin="24,0,24,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="16"/>
          <ColumnDefinition Width="330"/>
        </Grid.ColumnDefinitions>

        <!-- ===== Centre: profiles, IP settings, adapter actions, test ===== -->
        <ScrollViewer x:Name="svForm" VerticalScrollBarVisibility="Auto">
          <StackPanel>

            <!-- IP settings -->
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <Grid Margin="0,0,0,14">
                  <StackPanel Orientation="Horizontal">
                    <Border Style="{StaticResource CardIcon}" Background="#0A84FF"><TextBlock Text="&#xE968;" Style="{StaticResource Glyph}" Foreground="White" HorizontalAlignment="Center"/></Border>
                    <TextBlock Text="IP settings" Style="{StaticResource CardTitle}"/>
                  </StackPanel>
                  <Border HorizontalAlignment="Right" Background="#E3E3E8" CornerRadius="8" Padding="2">
                    <StackPanel Orientation="Horizontal">
                      <RadioButton x:Name="rbDhcp" Style="{StaticResource Seg}" GroupName="mode">
                        <StackPanel Orientation="Horizontal">
                          <TextBlock Text="&#xE895;" Style="{StaticResource Glyph}" FontSize="12" Margin="0,0,7,0"/>
                          <TextBlock Text="Automatic (DHCP)"/>
                        </StackPanel>
                      </RadioButton>
                      <RadioButton x:Name="rbStatic" Style="{StaticResource Seg}" GroupName="mode" IsChecked="True">
                        <StackPanel Orientation="Horizontal">
                          <TextBlock Text="&#xE70F;" Style="{StaticResource Glyph}" FontSize="12" Margin="0,0,7,0"/>
                          <TextBlock Text="Manual (static)"/>
                        </StackPanel>
                      </RadioButton>
                    </StackPanel>
                  </Border>
                </Grid>

                <!-- DHCP explanation -->
                <Border x:Name="pnlDhcpInfo" Background="#F2F2F7" CornerRadius="8" Padding="16,14" Visibility="Collapsed">
                  <StackPanel>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="&#xE946;" Style="{StaticResource Glyph}" Foreground="#0071E3" FontSize="16" VerticalAlignment="Top" Margin="0,1,10,0"/>
                      <TextBlock x:Name="txtDhcpInfo" Grid.Column="1" Style="{StaticResource Hint}" FontSize="13" Foreground="#3A3A3C"/>
                    </Grid>
                    <!-- What DHCP handed out, one value per line -->
                    <Grid x:Name="grdCurrent" Margin="26,12,0,0">
                      <Grid.Resources>
                        <Style x:Key="CurKey" TargetType="TextBlock">
                          <Setter Property="Foreground" Value="#6E6E73"/>
                          <Setter Property="Margin" Value="0,0,0,8"/>
                          <Setter Property="VerticalAlignment" Value="Top"/>
                        </Style>
                        <Style x:Key="CurVal" TargetType="TextBlock">
                          <Setter Property="FontFamily" Value="Consolas"/>
                          <Setter Property="FontSize" Value="14"/>
                          <Setter Property="Margin" Value="0,0,0,8"/>
                          <Setter Property="TextWrapping" Value="Wrap"/>
                        </Style>
                      </Grid.Resources>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="26"/>
                        <ColumnDefinition Width="130"/>
                        <ColumnDefinition Width="*"/>
                      </Grid.ColumnDefinitions>
                      <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                      </Grid.RowDefinitions>
                      <TextBlock Grid.Row="0" Text="&#xE7F8;" Style="{StaticResource LabelIcon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
                      <TextBlock Grid.Row="0" Grid.Column="1" Text="IP address" Style="{StaticResource CurKey}"/>
                      <TextBlock Grid.Row="0" Grid.Column="2" x:Name="txtCurIp" Style="{StaticResource CurVal}" FontWeight="SemiBold"/>
                      <TextBlock Grid.Row="1" Text="&#xF22C;" Style="{StaticResource LabelIcon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
                      <TextBlock Grid.Row="1" Grid.Column="1" Text="Subnet mask" Style="{StaticResource CurKey}"/>
                      <TextBlock Grid.Row="1" Grid.Column="2" x:Name="txtCurMask" Style="{StaticResource CurVal}"/>
                      <TextBlock Grid.Row="2" Text="&#xE8CE;" Style="{StaticResource LabelIcon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
                      <TextBlock Grid.Row="2" Grid.Column="1" Text="Gateway" Style="{StaticResource CurKey}"/>
                      <TextBlock Grid.Row="2" Grid.Column="2" x:Name="txtCurGw" Style="{StaticResource CurVal}"/>
                      <TextBlock Grid.Row="3" Text="&#xE774;" Style="{StaticResource LabelIcon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
                      <TextBlock Grid.Row="3" Grid.Column="1" Text="DNS servers" Style="{StaticResource CurKey}"/>
                      <TextBlock Grid.Row="3" Grid.Column="2" x:Name="txtCurDns" Style="{StaticResource CurVal}" Margin="0"/>
                    </Grid>
                  </StackPanel>
                </Border>

                <!-- Manual -->
                <StackPanel x:Name="pnlManual">
                  <Border Background="#EAF2FD" CornerRadius="10" Padding="14,12" Margin="0,0,0,18">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <Border Width="34" Height="34" CornerRadius="17" Background="White" Margin="0,0,12,0">
                        <TextBlock Text="&#xE945;" Style="{StaticResource Glyph}" Foreground="#0071E3" FontSize="16" HorizontalAlignment="Center"/>
                      </Border>
                      <StackPanel Grid.Column="1" VerticalAlignment="Center">
                        <TextBlock Text="Connecting to a device?" FontWeight="SemiBold" Foreground="#0A3A70"/>
                        <TextBlock Text="Type its IP (modem, router, switch...) - your IP, mask and gateway are filled in for you."
                                   Style="{StaticResource Hint}" Foreground="#3A5A80"/>
                      </StackPanel>
                      <TextBox x:Name="txtDeviceIp" Grid.Column="2" Width="150" Margin="12,0,8,0" FontFamily="Consolas" Background="White" BorderBrush="White"
                               Tag="device IP" ToolTip="Device IP, e.g. 192.168.1.1 - press Enter to fill in"/>
                      <Button x:Name="btnQuickFill" Grid.Column="3" Style="{StaticResource BtnAccent}">
                        <StackPanel Orientation="Horizontal">
                          <TextBlock Text="&#xE945;" Style="{StaticResource Glyph}" FontSize="12"/>
                          <TextBlock Text="Fill in" Margin="6,0,0,0"/>
                        </StackPanel>
                      </Button>
                    </Grid>
                  </Border>

                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="16"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <StackPanel Grid.Row="0" Grid.Column="0">
                      <StackPanel Style="{StaticResource FieldHead}">
                        <TextBlock Text="&#xE7F8;" Style="{StaticResource LabelIcon}"/>
                        <TextBlock Text="This laptop's IP address" Style="{StaticResource Label}"/>
                      </StackPanel>
                      <TextBox x:Name="txtIP" FontFamily="Consolas" FontSize="14" Tag="e.g. 192.168.1.10"/>
                    </StackPanel>
                    <StackPanel Grid.Row="0" Grid.Column="2">
                      <StackPanel Style="{StaticResource FieldHead}">
                        <TextBlock Text="&#xF22C;" Style="{StaticResource LabelIcon}"/>
                        <TextBlock Style="{StaticResource Label}"><Run Text="Subnet mask"/><Run Text="   pick, or type /24 or 255.255.255.0" Foreground="#8E8E93"/></TextBlock>
                      </StackPanel>
                      <ComboBox x:Name="cmbMask" FontFamily="Consolas" FontSize="14"/>
                    </StackPanel>

                    <Border Grid.Row="1" Grid.ColumnSpan="3" Padding="3,8,0,0" Margin="0,0,0,14">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xF22C;" Style="{StaticResource Glyph}" FontSize="12" Foreground="#6E6E73" Margin="0,0,8,0"/>
                        <TextBlock x:Name="txtSubnetInfo" Style="{StaticResource Hint}" FontFamily="Consolas"/>
                      </StackPanel>
                    </Border>

                    <StackPanel Grid.Row="2" Grid.Column="0">
                      <StackPanel Style="{StaticResource FieldHead}">
                        <TextBlock Text="&#xE8CE;" Style="{StaticResource LabelIcon}"/>
                        <TextBlock Style="{StaticResource Label}"><Run Text="Gateway"/><Run Text="   optional - router to other networks" Foreground="#8E8E93"/></TextBlock>
                      </StackPanel>
                      <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="txtGw" FontFamily="Consolas" FontSize="14" Tag="e.g. 192.168.1.1"/>
                        <Button x:Name="btnSuggestGw" Grid.Column="1" Style="{StaticResource BtnGhost}" Margin="4,0,0,0" Padding="8,0"
                                ToolTip="Use the first address of the subnet (usually the router)">
                          <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE945;" Style="{StaticResource Glyph}" FontSize="12" Foreground="#0071E3"/>
                            <TextBlock Text="Suggest" Foreground="#0071E3" Margin="5,0,0,0"/>
                          </StackPanel>
                        </Button>
                      </Grid>
                    </StackPanel>

                    <Grid Grid.Row="2" Grid.Column="2">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <StackPanel>
                        <StackPanel Style="{StaticResource FieldHead}">
                          <TextBlock Text="&#xE774;" Style="{StaticResource LabelIcon}"/>
                          <TextBlock Text="DNS server" Style="{StaticResource Label}"/>
                        </StackPanel>
                        <ComboBox x:Name="cmbDns1" FontFamily="Consolas" FontSize="14"/>
                      </StackPanel>
                      <StackPanel Grid.Column="2">
                        <StackPanel Style="{StaticResource FieldHead}">
                          <TextBlock Text="&#xE774;" Style="{StaticResource LabelIcon}" Opacity="0.6"/>
                          <TextBlock Text="Second DNS" Style="{StaticResource Label}"/>
                        </StackPanel>
                        <ComboBox x:Name="cmbDns2" FontFamily="Consolas" FontSize="14"/>
                      </StackPanel>
                    </Grid>
                  </Grid>
                </StackPanel>

                <Border x:Name="bdFormError" Background="#FDECEB" CornerRadius="6" Padding="10,8" Margin="0,14,0,0" Visibility="Collapsed">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <TextBlock Text="&#xE7BA;" Style="{StaticResource Glyph}" Foreground="#D70015" Margin="0,0,8,0" VerticalAlignment="Top"/>
                    <TextBlock x:Name="txtFormError" Grid.Column="1" Foreground="#9F1A10" TextWrapping="Wrap"/>
                  </Grid>
                </Border>
              </StackPanel>
            </Border>

            <!-- Profiles -->
            <Border Style="{StaticResource Card}" Padding="18,14,18,10">
              <StackPanel>
                <Grid Margin="0,0,0,10">
                  <StackPanel Orientation="Horizontal">
                    <Border Style="{StaticResource CardIcon}" Background="#FF9500"><TextBlock Text="&#xE734;" Style="{StaticResource Glyph}" Foreground="White" HorizontalAlignment="Center"/></Border>
                    <TextBlock Text="Profiles" Style="{StaticResource CardTitle}"/>
                    <TextBlock Text="click to fill the form" Style="{StaticResource Hint}" VerticalAlignment="Center" Margin="10,1,0,0"/>
                  </StackPanel>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                    <Button x:Name="btnShowSave" Style="{StaticResource BtnGhost}" Padding="8,0" Height="30" ToolTip="Save the form as a new profile">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xE710;" Style="{StaticResource Glyph}" FontSize="12" Foreground="#0071E3"/>
                        <TextBlock Text="Save current" Margin="6,0,0,0" FontSize="12" Foreground="#0071E3"/>
                      </StackPanel>
                    </Button>
                    <Button x:Name="btnImportProfiles" Style="{StaticResource BtnGhost}" Padding="8,0" Height="30" ToolTip="Import profiles from a JSON file (same name = replaced)">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xE8B5;" Style="{StaticResource Glyph}" FontSize="12"/>
                        <TextBlock Text="Import" Margin="6,0,0,0" FontSize="12"/>
                      </StackPanel>
                    </Button>
                    <Button x:Name="btnExportProfiles" Style="{StaticResource BtnGhost}" Padding="8,0" Height="30" ToolTip="Export all profiles to a JSON file to share with the team">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xEDE1;" Style="{StaticResource Glyph}" FontSize="12"/>
                        <TextBlock Text="Export" Margin="6,0,0,0" FontSize="12"/>
                      </StackPanel>
                    </Button>
                  </StackPanel>
                </Grid>
                <ItemsControl x:Name="icProfiles" ItemTemplate="{StaticResource Chip}">
                  <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                </ItemsControl>
                <TextBlock x:Name="txtNoProfiles" Text="No profiles yet - fill in the form, then 'Save current'." Style="{StaticResource Hint}" Visibility="Collapsed" Margin="0,0,0,8"/>
                <Grid x:Name="pnlSaveProfile" Margin="0,2,0,6" Visibility="Collapsed">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="txtProfileName" Tag="Profile name, e.g. Site A - modem" Height="32"/>
                  <Button x:Name="btnSaveProfile" Grid.Column="1" Style="{StaticResource BtnAccent}" Margin="8,0,0,0" Height="32" ToolTip="Save the form as a profile (Enter)">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="&#xE74E;" Style="{StaticResource Glyph}"/>
                      <TextBlock Text="Save" Margin="7,0,0,0"/>
                    </StackPanel>
                  </Button>
                  <Button x:Name="btnCancelSave" Grid.Column="2" Style="{StaticResource BtnGhost}" Margin="4,0,0,0" Height="32" Padding="10,0" ToolTip="Cancel">
                    <TextBlock Text="&#xE711;" Style="{StaticResource Glyph}" FontSize="11"/>
                  </Button>
                </Grid>
              </StackPanel>
            </Border>

            <!-- Test connection -->
            <Border Style="{StaticResource Card}" Padding="18,14">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <StackPanel Orientation="Horizontal" Margin="0,0,14,0">
                  <Border Style="{StaticResource CardIcon}" Background="#34C759"><TextBlock Text="&#xE9D9;" Style="{StaticResource Glyph}" Foreground="White" HorizontalAlignment="Center"/></Border>
                  <TextBlock Text="Test connection" Style="{StaticResource CardTitle}"/>
                </StackPanel>
                <TextBox x:Name="txtPingTarget" Grid.Column="1" FontFamily="Consolas" Tag="IP or hostname" MaxWidth="320" HorizontalAlignment="Stretch"
                         ToolTip="Pre-filled with the gateway - type any IP or hostname"/>
                <Button x:Name="btnPing" Grid.Column="2" Style="{StaticResource BtnAccent}" Margin="8,0,0,0" Padding="16,0">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE768;" Style="{StaticResource Glyph}" FontSize="12"/>
                    <TextBlock Text="Ping" Margin="6,0,0,0"/>
                  </StackPanel>
                </Button>
                <Border x:Name="bdPingResult" Grid.Row="1" Grid.ColumnSpan="3" Background="Transparent" CornerRadius="8" Padding="10,8" Margin="0,10,0,0">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <TextBlock x:Name="txtPingGlyph" Text="&#xE946;" Style="{StaticResource Glyph}" FontSize="13" Foreground="#6E6E73" VerticalAlignment="Top" Margin="0,1,8,0"/>
                    <TextBlock x:Name="txtPingResult" Grid.Column="1" Style="{StaticResource Hint}"/>
                  </Grid>
                </Border>
              </Grid>
            </Border>
          </StackPanel>
        </ScrollViewer>
        <!-- Scroll edges: a short fade into the page colour says "more above/below" (no divider lines) -->
        <Border x:Name="fdFormTop" Style="{StaticResource EdgeTop}"/>
        <Border x:Name="fdFormBottom" Style="{StaticResource EdgeBottom}"/>

        <!-- ===== Side: advanced settings + details (less used) ===== -->
        <ScrollViewer x:Name="svSide" Grid.Column="2" VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                  <Border Style="{StaticResource CardIcon}" Background="#8E8E93"><TextBlock Text="&#xE9E9;" Style="{StaticResource Glyph}" Foreground="White" HorizontalAlignment="Center"/></Border>
                  <TextBlock Text="Advanced" Style="{StaticResource CardTitle}"/>
                </StackPanel>
                <TextBlock Text="Rarely needed - leave as is unless you know you need it." Style="{StaticResource Hint}" Margin="0,0,0,14"/>

                <StackPanel Style="{StaticResource FieldHead}">
                  <TextBlock Text="&#xE9D2;" Style="{StaticResource LabelIcon}"/>
                  <TextBlock Style="{StaticResource Label}"><Run Text="MTU"/><Run Text="   bytes, 576-9216" Foreground="#8E8E93"/></TextBlock>
                </StackPanel>
                <ComboBox x:Name="cmbMtu" FontFamily="Consolas" FontSize="14"/>
                <TextBlock Text="Packet size. Applies in DHCP and manual mode." Style="{StaticResource Hint}" Margin="0,4,0,14"/>

                <StackPanel Style="{StaticResource FieldHead}">
                  <TextBlock Text="&#xE8EC;" Style="{StaticResource LabelIcon}"/>
                  <TextBlock Style="{StaticResource Label}"><Run Text="VLAN ID"/><Run Text="   0 = untagged" Foreground="#8E8E93"/></TextBlock>
                </StackPanel>
                <TextBox x:Name="txtVlan" FontFamily="Consolas" FontSize="14" Tag="0 - 4094"/>
                <TextBlock x:Name="lblVlanNote" Style="{StaticResource Hint}" Margin="0,4,0,14"/>

                <StackPanel Style="{StaticResource FieldHead}">
                  <TextBlock Text="&#xE710;" Style="{StaticResource LabelIcon}"/>
                  <TextBlock Text="Additional IP addresses" Style="{StaticResource Label}"/>
                </StackPanel>
                <TextBox x:Name="txtExtraIPs" Height="78" AcceptsReturn="True" TextWrapping="Wrap" FontFamily="Consolas"
                         VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top" Padding="8,6" Tag="one per line, e.g. 10.0.0.5/24"/>
                <TextBlock Text="To reach a second subnet at the same time. Manual mode only." Style="{StaticResource Hint}" Margin="0,4,0,0"/>
              </StackPanel>
            </Border>

            <!-- Internet sharing (Windows ICS) -->
            <Border x:Name="bdIcs" Style="{StaticResource Card}">
              <StackPanel>
                <Grid Margin="0,0,0,4">
                  <StackPanel Orientation="Horizontal">
                    <Border Style="{StaticResource CardIcon}" Background="#30B0C7"><TextBlock Text="&#xE704;" Style="{StaticResource Glyph}" Foreground="White" HorizontalAlignment="Center"/></Border>
                    <TextBlock Text="Internet sharing" Style="{StaticResource CardTitle}"/>
                  </StackPanel>
                  <Border x:Name="bdIcsPill" HorizontalAlignment="Right" VerticalAlignment="Center" CornerRadius="10" Padding="9,2" Background="#EFEFF4">
                    <StackPanel Orientation="Horizontal">
                      <Ellipse x:Name="elIcsDot" Width="7" Height="7" Fill="#8E8E93" VerticalAlignment="Center"/>
                      <TextBlock x:Name="txtIcsPill" Text="Off" FontSize="11.5" Margin="5,0,0,0"/>
                    </StackPanel>
                  </Border>
                </Grid>
                <TextBlock x:Name="txtIcsHint" Style="{StaticResource Hint}" Margin="0,0,0,12"
                           Text="Give devices plugged into one adapter internet from another. Windows then hands out their addresses (DHCP)."/>

                <!-- Choosing the pair (when not sharing) -->
                <StackPanel x:Name="pnlIcsSetup">
                  <StackPanel Style="{StaticResource FieldHead}">
                    <TextBlock Text="&#xE774;" Style="{StaticResource LabelIcon}"/>
                    <TextBlock Text="Internet comes from" Style="{StaticResource Label}"/>
                  </StackPanel>
                  <ComboBox x:Name="cmbIcsFrom" IsReadOnly="True" FontFamily="Segoe UI" FontSize="13" Margin="0,0,0,10"/>
                  <StackPanel Style="{StaticResource FieldHead}">
                    <TextBlock Text="&#xE839;" Style="{StaticResource LabelIcon}"/>
                    <TextBlock Text="Share it to (devices plug in here)" Style="{StaticResource Label}"/>
                  </StackPanel>
                  <ComboBox x:Name="cmbIcsTo" IsReadOnly="True" FontFamily="Segoe UI" FontSize="13" Margin="0,0,0,12"/>
                </StackPanel>

                <!-- The running pair -->
                <Border x:Name="pnlIcsActive" Background="#E3F5E8" CornerRadius="8" Padding="12,10" Margin="0,0,0,12" Visibility="Collapsed">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock x:Name="txtIcsFromGlyph" Style="{StaticResource Glyph}" Foreground="#248A3D" Margin="0,0,6,0"/>
                    <TextBlock x:Name="txtIcsFromName" FontWeight="SemiBold" Foreground="#1B6B30"/>
                    <TextBlock Text="&#xE72A;" Style="{StaticResource Glyph}" FontSize="12" Foreground="#248A3D" Margin="10,0"/>
                    <TextBlock x:Name="txtIcsToGlyph" Style="{StaticResource Glyph}" Foreground="#248A3D" Margin="0,0,6,0"/>
                    <TextBlock x:Name="txtIcsToName" FontWeight="SemiBold" Foreground="#1B6B30"/>
                  </StackPanel>
                </Border>

                <!-- DHCP server settings -->
                <StackPanel Style="{StaticResource FieldHead}">
                  <TextBlock Text="&#xE968;" Style="{StaticResource LabelIcon}"/>
                  <TextBlock Text="This PC's address on the shared port" Style="{StaticResource Label}"/>
                </StackPanel>
                <ComboBox x:Name="cmbIcsScope" FontFamily="Consolas" FontSize="14"/>
                <Border Padding="2,0,0,0" Margin="0,8,0,12">
                  <TextBlock x:Name="txtIcsDhcpInfo" Style="{StaticResource Hint}"/>
                </Border>
                <CheckBox x:Name="chkIcsPersist" Style="{StaticResource Switch}" Content="Keep sharing after a restart" Margin="0,0,0,12"
                          ToolTip="Windows normally stops sharing when the PC restarts"/>
                <Border x:Name="bdIcsError" Background="#FDECEB" CornerRadius="6" Padding="10,8" Margin="0,0,0,10" Visibility="Collapsed">
                  <TextBlock x:Name="txtIcsError" Foreground="#9F1A10" TextWrapping="Wrap" FontSize="12"/>
                </Border>
                <StackPanel Orientation="Horizontal">
                  <Button x:Name="btnIcsStart" Style="{StaticResource BtnAccent}" Padding="14,0">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock x:Name="txtIcsStartGlyph" Text="&#xE768;" Style="{StaticResource Glyph}" FontSize="12"/>
                      <TextBlock x:Name="txtIcsStart" Text="Start sharing" Margin="7,0,0,0"/>
                    </StackPanel>
                  </Button>
                  <Button x:Name="btnIcsStop" Style="{StaticResource Btn}" Margin="8,0,0,0" Padding="12,0" Visibility="Collapsed"
                          ToolTip="Stops sharing and puts the shared port back on automatic (DHCP)">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="&#xE71A;" Style="{StaticResource Glyph}" FontSize="12" Foreground="#FF3B30"/>
                      <TextBlock Text="Stop sharing" Margin="7,0,0,0"/>
                    </StackPanel>
                  </Button>
                </StackPanel>

                <!-- Devices on the shared port -->
                <StackPanel x:Name="pnlIcsClients" Margin="0,16,0,0" Visibility="Collapsed">
                  <Grid Margin="0,0,0,6">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="&#xE772;" Style="{StaticResource LabelIcon}"/>
                      <TextBlock Text="Devices on the shared port" Style="{StaticResource Label}"/>
                    </StackPanel>
                    <Button x:Name="btnIcsRefresh" Style="{StaticResource BtnGhost}" HorizontalAlignment="Right" Height="26" Padding="6,0" ToolTip="Check again">
                      <TextBlock Text="&#xE72C;" Style="{StaticResource Glyph}" FontSize="11"/>
                    </Button>
                  </Grid>
                  <ItemsControl x:Name="icIcsClients">
                    <ItemsControl.ItemTemplate>
                      <DataTemplate>
                        <Border Background="#F2F2F7" CornerRadius="6" Padding="10,6" Margin="0,0,0,4">
                          <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <TextBlock Text="&#xE839;" FontFamily="{StaticResource Icons}" FontSize="13" Foreground="#0071E3" VerticalAlignment="Center" Margin="0,0,10,0"/>
                            <StackPanel Grid.Column="1">
                              <TextBlock Text="{Binding Ip}" FontFamily="Consolas" FontSize="13" FontWeight="SemiBold"/>
                              <TextBlock FontSize="11" Foreground="#6E6E73">
                                <Run Text="{Binding Mac, Mode=OneWay}" FontFamily="Consolas"/><Run Text="  "/><Run Text="{Binding Seen, Mode=OneWay}"/>
                              </TextBlock>
                            </StackPanel>
                          </Grid>
                        </Border>
                      </DataTemplate>
                    </ItemsControl.ItemTemplate>
                  </ItemsControl>
                  <TextBlock x:Name="txtIcsNoClients" Style="{StaticResource Hint}" Text="No devices seen yet - plug one in and set it to automatic (DHCP)."/>
                </StackPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                  <Border Style="{StaticResource CardIcon}" Background="#636366"><TextBlock Text="&#xE946;" Style="{StaticResource Glyph}" Foreground="White" HorizontalAlignment="Center"/></Border>
                  <TextBlock Text="Details" Style="{StaticResource CardTitle}"/>
                </StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="24"/>
                    <ColumnDefinition Width="80"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="&#xE950;" Style="{StaticResource Glyph}" FontSize="13" Foreground="#6E6E73" VerticalAlignment="Top"/>
                  <TextBlock Grid.Row="0" Grid.Column="1" Text="Hardware" Style="{StaticResource InfoKey}"/>
                  <TextBlock Grid.Row="0" Grid.Column="2" x:Name="txtInfoHw" Style="{StaticResource InfoVal}"/>
                  <TextBlock Grid.Row="1" Text="&#xE8EC;" Style="{StaticResource Glyph}" FontSize="13" Foreground="#6E6E73" VerticalAlignment="Top"/>
                  <TextBlock Grid.Row="1" Grid.Column="1" Text="MAC" Style="{StaticResource InfoKey}"/>
                  <TextBlock Grid.Row="1" Grid.Column="2" x:Name="txtInfoMac" Style="{StaticResource InfoVal}" FontFamily="Consolas"/>
                  <TextBlock Grid.Row="2" Text="&#xEC3B;" Style="{StaticResource Glyph}" FontSize="13" Foreground="#6E6E73" VerticalAlignment="Top"/>
                  <TextBlock Grid.Row="2" Grid.Column="1" Text="Link speed" Style="{StaticResource InfoKey}"/>
                  <TextBlock Grid.Row="2" Grid.Column="2" x:Name="txtInfoSpeed" Style="{StaticResource InfoVal}"/>
                  <TextBlock Grid.Row="3" Text="&#xE968;" Style="{StaticResource Glyph}" FontSize="13" Foreground="#6E6E73" VerticalAlignment="Top"/>
                  <TextBlock Grid.Row="3" Grid.Column="1" Text="Type" Style="{StaticResource InfoKey}"/>
                  <TextBlock Grid.Row="3" Grid.Column="2" x:Name="txtInfoType" Style="{StaticResource InfoVal}"/>
                  <TextBlock Grid.Row="4" Text="&#xE8CB;" Style="{StaticResource Glyph}" FontSize="13" Foreground="#6E6E73" VerticalAlignment="Top"/>
                  <TextBlock Grid.Row="4" Grid.Column="1" Text="Interface #" Style="{StaticResource InfoKey}"/>
                  <TextBlock Grid.Row="4" Grid.Column="2" x:Name="txtInfoIndex" Style="{StaticResource InfoVal}"/>
                </Grid>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
        <Border x:Name="fdSideTop" Grid.Column="2" Style="{StaticResource EdgeTop}"/>
        <Border x:Name="fdSideBottom" Grid.Column="2" Style="{StaticResource EdgeBottom}"/>
      </Grid>

      <!-- Sticky action bar -->
      <Border Grid.Row="2" Background="#F2F2F7" Padding="24,6,24,12">
        <Grid>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="btnUndo" Style="{StaticResource Btn}" IsEnabled="False">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE7A7;" Style="{StaticResource Glyph}"/>
                <TextBlock Text="Undo last change" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Border x:Name="txtDirty" Background="#FFEBCC" CornerRadius="11" Padding="10,3" Margin="14,0,0,0" VerticalAlignment="Center" Visibility="Collapsed">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE70F;" Style="{StaticResource Glyph}" FontSize="11" Foreground="#B25000" Margin="0,0,6,0"/>
                <TextBlock Text="Edited - not applied yet" Foreground="#B25000" FontSize="12"/>
              </StackPanel>
            </Border>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnRevert" Style="{StaticResource BtnGhost}" Margin="0,0,8,0" ToolTip="Discard edits and show the adapter's current settings">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE711;" Style="{StaticResource Glyph}" FontSize="11"/>
                <TextBlock Text="Discard edits" Margin="7,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="btnApply" Style="{StaticResource BtnAccent}" MinWidth="160" Height="38">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE73E;" Style="{StaticResource Glyph}"/>
                <TextBlock Text="Apply changes" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>

    <!-- ============ Status bar ============ -->
    <Border x:Name="bdStatus" Grid.Row="2" Background="#EBEBF0">
      <Grid>
        <ProgressBar x:Name="pbBusy" Height="3" VerticalAlignment="Top" IsIndeterminate="True" Visibility="Collapsed"
                     BorderThickness="0" Background="Transparent" Foreground="#0071E3"/>
        <StackPanel Orientation="Horizontal" Margin="22,7">
          <TextBlock x:Name="txtStatusIcon" Text="&#xE946;" Style="{StaticResource Glyph}" FontSize="13" Foreground="#6E6E73" Margin="0,0,9,0"/>
          <TextBlock x:Name="txtStatusBar" Text="Ready." FontSize="12.5" TextWrapping="Wrap" VerticalAlignment="Center"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

try {
    [xml]$xamlDoc = $xaml
    $reader = New-Object System.Xml.XmlNodeReader $xamlDoc
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    # The elevated process runs with a hidden console, so a startup failure must be shown explicitly.
    [System.Windows.MessageBox]::Show("Network Control Center failed to start:`n`n$($_.Exception.Message)",
        'Network Control Center', 'OK', 'Error') | Out-Null
    exit 1
}

# Grab named controls
$controlNames = @(
    'txtVersion','pnlAppBar','txtScanGlyph','txtScanState','chkShowAll','btnRefresh',
    'fdFormTop','fdFormBottom','fdSideTop','fdSideBottom',
    'txtScreenGlyph','txtPingHomeHint','bdPingResult','txtPingGlyph','txtToggleGlyph',
    'txtInfoHw','txtInfoMac','txtInfoSpeed','txtInfoType','txtInfoIndex','btnShowSave','pnlSaveProfile','btnCancelSave',
    'grdCurrent','txtCurIp','txtCurMask','txtCurGw','txtCurDns',
    'bdIcs','bdIcsPill','elIcsDot','txtIcsPill','txtIcsHint','pnlIcsSetup','cmbIcsFrom','cmbIcsTo','pnlIcsActive',
    'txtIcsFromGlyph','txtIcsFromName','txtIcsToGlyph','txtIcsToName','cmbIcsScope','txtIcsDhcpInfo','chkIcsPersist',
    'bdIcsError','txtIcsError','btnIcsStart','txtIcsStartGlyph','txtIcsStart','btnIcsStop','pnlIcsClients',
    'btnIcsRefresh','icIcsClients','txtIcsNoClients','svSide','vbStage',
    'pnlHome','icWired','txtNoWired','icWireless','txtNoWireless','pnlVirtual','icVirtual',
    'txtHostName','txtOnline','pnlHomeTools','txtPingHome','btnPingHome','btnFlushDns','btnClearArp','btnOpenData',
    'pnlConfig','btnBack','bdAdapterIcon','txtAdapterGlyph','txtAdapterName','bdStatusPill','elStatusDot',
    'txtStatusPill','txtDetail','svForm','rbDhcp','rbStatic','pnlDhcpInfo','txtDhcpInfo','pnlManual',
    'txtDeviceIp','btnQuickFill','txtIP','cmbMask','txtSubnetInfo','txtGw','btnSuggestGw','cmbDns1','cmbDns2',
    'bdFormError','txtFormError','cmbMtu','txtVlan','lblVlanNote','txtExtraIPs',
    'icProfiles','txtNoProfiles','txtProfileName','btnSaveProfile','btnImportProfiles','btnExportProfiles',
    'txtPingTarget','btnPing','txtPingResult','pnlAdapterActions','btnDhcp','btnRenew','btnRestart',
    'btnToggleEnable','txtToggleEnable','btnCopy','btnUndo','txtDirty','btnRevert','btnApply',
    'bdStatus','pbBusy','txtStatusIcon','txtStatusBar'
)
$ctl = @{}
foreach ($n in $controlNames) { $ctl[$n] = $window.FindName($n) }

$window.Title        = "Network Control Center $script:AppVersion"
$ctl.txtVersion.Text = "v$script:AppVersion"
$icoPath = Join-Path $PSScriptRoot 'NetworkControlCenter.ico'
if (Test-Path $icoPath) {
    # Load into memory (OnLoad) so the file isn't kept locked - the installer must be able to replace it.
    try {
        $icoStream = New-Object System.IO.MemoryStream (, [System.IO.File]::ReadAllBytes($icoPath))
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($icoStream,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    } catch { }
}

# ---------------------------------------------------------------------
# 4. HELPERS
#    Every function named in $script:WorkerFunctions is copied into the
#    background runspaces, which can't see this script's state - keep those
#    free of $ctl / $window / $script:* references.
# ---------------------------------------------------------------------
$script:Dot = [string][char]0x00B7

function Set-Status([string]$msg, [string]$type = 'info') {
    # CIM/driver error messages often carry embedded/trailing newlines - keep the status bar to one line.
    $ctl.txtStatusBar.Text = ($msg -replace '\s*\r?\n\s*', ' ').Trim()
    $style = switch ($type) {
        'ok'    { @('#E3F5E8', '#248A3D', 0xE930) }
        'warn'  { @('#FFF4E0', '#B25000', 0xE7BA) }
        'err'   { @('#FDECEB', '#D70015', 0xEA39) }
        default { @('#EBEBF0', '#6E6E73', 0xE946) }
    }
    $ctl.bdStatus.Background      = $script:Converter.ConvertFromString($style[0])
    $ctl.txtStatusIcon.Foreground = $script:Converter.ConvertFromString($style[1])
    $ctl.txtStatusIcon.Text       = [string][char]$style[2]
}

# ---- validation & subnet math (pure) ---------------------------------

# Strict dotted-quad check. [IPAddress]::TryParse alone is too lenient for a config form: it
# accepts shorthand like "10" (-> 0.0.0.10) or "192.168.1" (-> 192.168.0.1).
function Test-IPv4([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    $s = $s.Trim()
    if ($s -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($o in $s.Split('.')) { if ([int]$o -gt 255) { return $false } }
    return $true
}

# Strips leading zeros ("192.168.001.010" -> "192.168.1.10") so nothing downstream can read them as octal.
function ConvertTo-NormalizedIPv4([string]$s) {
    return (($s.Trim().Split('.') | ForEach-Object { [int]$_ }) -join '.')
}

function ConvertTo-IPv4Int([string]$s) {
    $o = $s.Trim().Split('.') | ForEach-Object { [int64]$_ }
    return [int64]($o[0] * 16777216 + $o[1] * 65536 + $o[2] * 256 + $o[3])
}

function ConvertFrom-IPv4Int([int64]$n) {
    return (@(
        [math]::Floor($n / 16777216) % 256
        [math]::Floor($n / 65536) % 256
        [math]::Floor($n / 256) % 256
        $n % 256
    ) -join '.')
}

function Get-PrefixMaskInt([int]$p) {
    return [int64]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $p))
}

function Test-SameSubnet([string]$a, [string]$b, [int]$p) {
    $m = Get-PrefixMaskInt $p
    return ((ConvertTo-IPv4Int $a) -band $m) -eq ((ConvertTo-IPv4Int $b) -band $m)
}

# Rejects addresses Windows won't (or shouldn't) assign to an interface: 0.x, loopback, multicast/reserved.
function Test-UsableIPv4([string]$s) {
    $first = [int]$s.Trim().Split('.')[0]
    return -not ($first -eq 0 -or $first -eq 127 -or $first -ge 224)
}

# Accepts "255.255.255.0", "/24" or "24"; anything after the first space or "(" is ignored, so
# picker entries like "/24   255.255.255.0" parse too.
function Resolve-Prefix([string]$s) {
    $orig = "$s".Trim()
    $s = ($orig -split '[\s(]')[0].TrimStart('/')
    if ($s -match '\.') {
        if (-not (Test-IPv4 $s)) { throw "Subnet mask '$orig' is not valid - use e.g. 255.255.255.0 or /24." }
        $octets = $s.Split('.')
        $bin = ($octets | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8, '0') }) -join ''
        if ($bin -match '01') { throw "Subnet mask '$orig' is not valid - its bits are not contiguous." }
        return ($bin.ToCharArray() | Where-Object { $_ -eq '1' }).Count
    }
    $p = 0
    if (-not [int]::TryParse($s, [ref]$p)) { throw "Subnet mask '$orig' is not valid - use e.g. 255.255.255.0 or /24." }
    if ($p -lt 0 -or $p -gt 32) { throw "Prefix length must be 0-32." }
    return $p
}

function Get-MaskFromPrefix([int]$p) {
    if ($p -lt 0 -or $p -gt 32) { return '' }
    $bits = ('1' * $p).PadRight(32, '0')
    $bytes = for ($i = 0; $i -lt 32; $i += 8) { [Convert]::ToInt32($bits.Substring($i, 8), 2) }
    return ($bytes -join '.')
}

# Network / usable range / broadcast for an address - shown live under the IP fields.
function Get-SubnetSummary([string]$Ip, [int]$Prefix) {
    $net  = (ConvertTo-IPv4Int $Ip) -band (Get-PrefixMaskInt $Prefix)
    $size = [int64][math]::Pow(2, 32 - $Prefix)
    $last = $net + $size - 1
    if ($Prefix -ge 31) { $first = $net; $lastHost = $last; $hosts = $size; $bcast = $null }
    else { $first = $net + 1; $lastHost = $last - 1; $hosts = $size - 2; $bcast = ConvertFrom-IPv4Int $last }
    [PSCustomObject]@{
        Network   = ConvertFrom-IPv4Int $net
        Prefix    = $Prefix
        Mask      = Get-MaskFromPrefix $Prefix
        FirstHost = ConvertFrom-IPv4Int $first
        LastHost  = ConvertFrom-IPv4Int $lastHost
        Broadcast = $bcast
        Hosts     = $hosts
    }
}

# "Connecting to a device at X": picks a free host address for the laptop in the device's subnet
# (.10, .100, .200 ... never the device itself) and uses the device as the gateway.
function Get-QuickConfigForDevice([string]$DeviceIp, [int]$Prefix = 24) {
    if (-not (Test-IPv4 $DeviceIp)) { throw "Type the device's IP address first (e.g. 192.168.1.1)." }
    $dev = ConvertTo-NormalizedIPv4 $DeviceIp
    if (-not (Test-UsableIPv4 $dev)) { throw "$dev is a reserved address - check the device IP." }
    if ($Prefix -lt 8 -or $Prefix -gt 30) { $Prefix = 24 }
    $devInt = ConvertTo-IPv4Int $dev
    $net    = $devInt -band (Get-PrefixMaskInt $Prefix)
    $bcast  = $net + [int64][math]::Pow(2, 32 - $Prefix) - 1
    if ($devInt -eq $net -or $devInt -eq $bcast) {
        throw "$dev is the network or broadcast address of a /$Prefix - check the device IP or the mask."
    }
    foreach ($off in 10, 100, 200, 50, 20, 2, 3, 4, 5, 6) {
        $c = $net + $off
        if ($c -lt $bcast -and $c -ne $devInt) {
            return [PSCustomObject]@{ Ip = (ConvertFrom-IPv4Int $c); Prefix = $Prefix; Gateway = $dev }
        }
    }
    # Tiny subnets (/29, /30): take any host that isn't the device.
    for ($c = $net + 1; $c -lt $bcast; $c++) {
        if ($c -ne $devInt) { return [PSCustomObject]@{ Ip = (ConvertFrom-IPv4Int $c); Prefix = $Prefix; Gateway = $dev } }
    }
    throw "No free address left in that subnet."
}

function Resolve-VlanId([string]$s) {
    $s = "$s".Trim()
    if ($s -eq '') { return 0 }
    $v = 0
    if (-not [int]::TryParse($s, [ref]$v)) { throw "VLAN ID must be a number." }
    if ($v -lt 0 -or $v -gt 4094) { throw "VLAN ID must be between 0 and 4094." }
    return $v
}

# Validates the editor's raw text fields and returns a normalized config object. Throws a
# user-facing message on the first problem, so callers can validate EVERYTHING before touching
# the adapter - a half-applied config is the worst outcome in the field.
function Test-ConfigInput {
    param([string]$Mode, [string]$Ip, [string]$Mask, [string]$Gateway,
          [string]$Dns1, [string]$Dns2, [string]$Mtu, [string]$ExtraIPs)

    $cfg = [PSCustomObject]@{
        Mode = $(if ($Mode -eq 'DHCP') { 'DHCP' } else { 'Static' })
        Ip = ''; Prefix = $null; Gateway = ''; Dns = @(); Mtu = 0; Extra = @()
    }

    $mtuText = ("$Mtu".Trim() -split '\s')[0]
    if ($mtuText) {
        $m = 0
        if (-not [int]::TryParse($mtuText, [ref]$m)) { throw "MTU must be a number." }
        if ($m -lt 576 -or $m -gt 9216) { throw "MTU must be between 576 and 9216." }
        $cfg.Mtu = $m
    }
    if ($cfg.Mode -eq 'DHCP') { return $cfg }

    if ([string]::IsNullOrWhiteSpace($Ip)) { throw "Type your IP address (e.g. 192.168.1.10)." }
    if (-not (Test-IPv4 $Ip)) { throw "IP address is not a valid IPv4 address (e.g. 192.168.1.10)." }
    $ipN = ConvertTo-NormalizedIPv4 $Ip
    if (-not (Test-UsableIPv4 $ipN)) { throw "IP address $ipN is reserved (0.x / loopback / multicast) and can't be assigned." }

    if ([string]::IsNullOrWhiteSpace($Mask)) { throw "Subnet mask is required (e.g. 255.255.255.0 or /24)." }
    $prefix = Resolve-Prefix $Mask
    if ($prefix -lt 1) { throw "Prefix length must be 1-32 for a host address." }
    if ($prefix -le 30) {
        $maskInt = Get-PrefixMaskInt $prefix
        $ipInt   = ConvertTo-IPv4Int $ipN
        $net     = $ipInt -band $maskInt
        $bcast   = $net + ([math]::Pow(2, 32 - $prefix) - 1)
        if ($ipInt -eq $net)   { throw "$ipN is the network address of $(ConvertFrom-IPv4Int $net)/$prefix - pick a host address." }
        if ($ipInt -eq $bcast) { throw "$ipN is the broadcast address of $(ConvertFrom-IPv4Int $net)/$prefix - pick a host address." }
    }
    $cfg.Ip = $ipN; $cfg.Prefix = $prefix

    if ("$Gateway".Trim()) {
        if (-not (Test-IPv4 $Gateway)) { throw "Gateway is not a valid IPv4 address." }
        $gwN = ConvertTo-NormalizedIPv4 $Gateway
        if ($gwN -eq $ipN) { throw "Gateway can't be the same as the IP address." }
        if ($prefix -eq 32) { throw "A /32 address can't have a gateway - clear the gateway or use a shorter prefix." }
        if (-not (Test-SameSubnet $ipN $gwN $prefix)) {
            throw "Gateway $gwN is not inside $(ConvertFrom-IPv4Int ((ConvertTo-IPv4Int $ipN) -band (Get-PrefixMaskInt $prefix)))/$prefix - check the IP, mask and gateway."
        }
        $cfg.Gateway = $gwN
    }

    $dns = @()
    foreach ($pair in @(@('server', $Dns1), @('second server', $Dns2))) {
        $v = ("$($pair[1])".Trim() -split '\s')[0]
        if (-not $v) { continue }
        if (-not (Test-IPv4 $v)) { throw "DNS $($pair[0]) is not a valid IPv4 address." }
        $dns += (ConvertTo-NormalizedIPv4 $v)
    }
    $cfg.Dns = @($dns | Select-Object -Unique)

    $extra = @()
    $seen  = @{ $ipN = $true }
    foreach ($line in ("$ExtraIPs" -split "`r?`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        $parts = $line.Split('/')
        if ($parts.Count -gt 2 -or -not (Test-IPv4 $parts[0])) { throw "Additional IP '$line' is not valid (use ip or ip/prefix)." }
        $eip = ConvertTo-NormalizedIPv4 $parts[0]
        if (-not (Test-UsableIPv4 $eip)) { throw "Additional IP $eip is reserved and can't be assigned." }
        $ep = if ($parts.Count -eq 2) { Resolve-Prefix $parts[1] } else { $prefix }
        if ($ep -lt 1) { throw "Additional IP '$line' needs a prefix length of 1-32." }
        if ($seen.ContainsKey($eip)) { continue }
        $seen[$eip] = $true
        $extra += [PSCustomObject]@{ Ip = $eip; Prefix = [int]$ep }
    }
    $cfg.Extra = $extra
    return $cfg
}

# One-line description of an adapter (inventory object) for the change log and status messages.
function Format-AdapterConfig($a) {
    if (-not $a) { return '(none)' }
    $s = if ($a.Dhcp) { 'DHCP' }
         elseif ($a.IPv4) { "static $($a.IPv4)/$($a.PrefixLength)" }
         else { 'static (no address)' }
    if (-not $a.Dhcp -and $a.Gateway) { $s += " gw $($a.Gateway)" }
    if (@($a.Dns).Count) { $s += " dns $(@($a.Dns) -join ',')" }
    if ($a.Mtu) { $s += " mtu $($a.Mtu)" }
    return $s
}

function Format-ConfigSummary($cfg) {
    if ($cfg.Mode -eq 'DHCP') { $s = 'DHCP' }
    else {
        $s = "static $($cfg.Ip)/$($cfg.Prefix)"
        if ($cfg.Gateway) { $s += " gw $($cfg.Gateway)" }
        if (@($cfg.Dns).Count) { $s += " dns $(@($cfg.Dns) -join ',')" }
        if (@($cfg.Extra).Count) { $s += " +$(@($cfg.Extra).Count) extra IP(s)" }
    }
    if ($cfg.Mtu) { $s += " mtu $($cfg.Mtu)" }
    return $s
}

function Format-LinkSpeed($bps) {
    $b = 0.0
    if (-not [double]::TryParse("$bps", [ref]$b) -or $b -le 0) { return '' }
    if ($b -ge 1e9) { return "$([math]::Round($b / 1e9, 1)) Gbps" }
    if ($b -ge 1e6) { return "$([math]::Round($b / 1e6)) Mbps" }
    return "$([math]::Round($b / 1e3)) Kbps"
}

function Format-MacAddress([string]$s) {
    $h = ($s -replace '[^0-9A-Fa-f]', '').ToUpper()
    if ($h.Length -ne 12) { return $s }
    return (($h -split '(..)' | Where-Object { $_ }) -join '-')
}

# Where an adapter goes on the home screen. NdisPhysicalMedium: 9 = Wi-Fi, 8 = cellular (WWAN),
# 10 = Bluetooth, 14 = 802.3 Ethernet. Virtual is checked before Ethernet: VPN adapters claim 802.3.
# The medium decides first; name matching is only a fallback, with whole words ("Realtek" contains "lte").
function Get-AdapterKind([int]$Medium, [bool]$Virtual, [string]$Name, [string]$Description) {
    $text = "$Name $Description"
    if ($Medium -eq 10 -or $text -match '\bBluetooth\b') { return 'Bluetooth' }
    if ($Virtual) { return 'Virtual' }
    switch ($Medium) { 9 { return 'WiFi' } 8 { return 'Cellular' } 14 { return 'Ethernet' } }
    if ($text -match '\b(Wi-?Fi|Wireless|WLAN|802\.11)\b') { return 'WiFi' }
    if ($text -match '\b(Mobile Broadband|Cellular|WWAN|LTE|5G)\b') { return 'Cellular' }
    return 'Virtual'
}

# Classifies raw advanced driver properties (MSFT_NetAdapterAdvancedPropertySettingData) into
# Name -> {Supported, Keyword, Value}. Only a numeric VLAN *ID* property counts. In particular
# *PriorityVLANTag ("Packet Priority & VLAN") is an enable/disable enum present on most
# Intel/Realtek NICs - writing a VLAN ID into it would corrupt the driver setting.
function ConvertTo-VlanInfo($Properties, [string[]]$Names) {
    $byName = @{}
    foreach ($p in @($Properties)) {
        if (-not $p) { continue }
        if (-not $byName.ContainsKey($p.Name)) { $byName[$p.Name] = @() }
        $byName[$p.Name] += $p
    }
    if (-not $Names) { $Names = @($byName.Keys) }
    $result = @{}
    foreach ($n in $Names) {
        $vlanProp = @($byName[$n]) | Where-Object {
            $_ -and ($_.RegistryKeyword -match '^\*?VlanId$' -or $_.DisplayName -match '^VLAN\s*ID') -and
            $_.RegistryKeyword -notmatch 'Priority'
        } | Select-Object -First 1
        $result[$n] = if ($vlanProp) {
            $val = "$($vlanProp.DisplayValue)"
            if ($val -notmatch '^\d+$') { $val = "$(@($vlanProp.RegistryValue)[0])" }
            [PSCustomObject]@{ Supported = $true; Keyword = $vlanProp.RegistryKeyword; Value = $val }
        } else {
            [PSCustomObject]@{ Supported = $false; Keyword = $null; Value = $null }
        }
    }
    return $result
}

# ---- inventory (runs in background runspaces) -------------------------
# Raw CIM queries against root/StandardCimv2 instead of Get-NetAdapter & co: same data, but the
# cmdlets first import their CDXML modules, which costs ~6s on a cold start versus <1s here.
# Everything is fetched once for ALL adapters and joined by InterfaceIndex in memory - never
# query per adapter in a loop.
function Get-AdapterInventory([int]$InterfaceIndex = 0) {
    $ns = 'root/StandardCimv2'
    $f  = if ($InterfaceIndex) { " AND InterfaceIndex=$InterfaceIndex" } else { '' }
    $adapters = @(Get-CimInstance -Namespace $ns -ClassName MSFT_NetAdapter -ErrorAction SilentlyContinue |
                  Where-Object { -not $_.Hidden -and (-not $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex) })
    if (-not $adapters) { return @() }

    $ifaces  = Get-CimInstance -Namespace $ns -ClassName MSFT_NetIPInterface -Filter "AddressFamily=2$f" -ErrorAction SilentlyContinue
    $ipv4all = Get-CimInstance -Namespace $ns -ClassName MSFT_NetIPAddress -Filter "AddressFamily=2$f" -ErrorAction SilentlyContinue |
               Where-Object { $_.PrefixOrigin -ne 2 }    # 2 = WellKnown (APIPA / loopback)
    $routes  = Get-CimInstance -Namespace $ns -ClassName MSFT_NetRoute -Filter "DestinationPrefix='0.0.0.0/0'$f" -ErrorAction SilentlyContinue
    $dnsAll  = Get-CimInstance -Namespace $ns -ClassName MSFT_DNSClientServerAddress -Filter "AddressFamily=2$f" -ErrorAction SilentlyContinue

    $ifaceByIdx = @{}
    foreach ($i in $ifaces) { $ifaceByIdx[[int]$i.InterfaceIndex] = $i }
    $ipv4ByIdx = @{}
    foreach ($ip in $ipv4all) {
        $k = [int]$ip.InterfaceIndex
        if (-not $ipv4ByIdx.ContainsKey($k)) { $ipv4ByIdx[$k] = @() }
        if (-not @($ipv4ByIdx[$k] | Where-Object { $_.IPAddress -eq $ip.IPAddress }).Count) { $ipv4ByIdx[$k] += $ip }
    }
    $routeByIdx = @{}
    foreach ($r in @($routes | Sort-Object RouteMetric)) {
        $k = [int]$r.InterfaceIndex
        if (-not $routeByIdx.ContainsKey($k)) { $routeByIdx[$k] = $r }
    }
    $dnsByIdx = @{}
    foreach ($d in $dnsAll) { $dnsByIdx[[int]$d.InterfaceIndex] = @($d.ServerAddresses | Where-Object { $_ }) }

    $glyphs  = @{ WiFi = 0xE701; Ethernet = 0xE839; Cellular = 0xEC05; Bluetooth = 0xE702; Virtual = 0xE968; Vpn = 0xE705 }
    $kindTxt = @{ WiFi = 'Wi-Fi'; Ethernet = 'Ethernet'; Cellular = 'Cellular'; Bluetooth = 'Bluetooth'; Virtual = 'Virtual' }
    $dot = [string][char]0x00B7

    foreach ($a in $adapters) {
        $idx   = [int]$a.InterfaceIndex
        $iface = $ifaceByIdx[$idx]
        $ipv4  = @($ipv4ByIdx[$idx] | Where-Object { $_ })
        # Primary = the address Windows uses as source (secondary IPs we add are SkipAsSource).
        $primary = $ipv4 | Sort-Object -Property @{Expression = { [bool]$_.SkipAsSource } } | Select-Object -First 1
        $dhcp    = ($iface.Dhcp -eq 1)
        $route   = $routeByIdx[$idx]

        $status = if ($a.InterfaceAdminStatus -eq 2 -or $a.State -eq 3) { 'Disabled' }
                  elseif ($a.InterfaceOperationalStatus -eq 1 -or $a.MediaConnectState -eq 1) { 'Up' }
                  elseif ($a.MediaConnectState -eq 2) { 'Disconnected' }
                  else { 'Down' }
        $kind  = Get-AdapterKind ([int]$a.NdisPhysicalMedium) ([bool]$a.Virtual) $a.Name $a.InterfaceDescription
        $isVpn = $kind -eq 'Virtual' -and "$($a.InterfaceDescription)" -match 'VPN|Fortinet|AnyConnect|WireGuard|OpenVPN|TAP|GlobalProtect|Pulse'
        $up    = $status -eq 'Up'

        # Statically configured DNS shows up as a non-empty NameServer value in the TCP/IP registry key
        # (DHCP-learned servers live in DhcpNameServer instead). A registry read is cheap, unlike CIM.
        $dnsStatic = $false
        if ($a.InterfaceGuid) {
            $nsValue = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)" `
                                         -Name NameServer -ErrorAction SilentlyContinue).NameServer
            $dnsStatic = -not [string]::IsNullOrWhiteSpace($nsValue)
        }

        $speed   = Format-LinkSpeed $a.Speed
        $mac     = Format-MacAddress $(if ($a.PermanentAddress) { $a.PermanentAddress } else { "$(@($a.NetworkAddresses)[0])" })
        $allIPv4 = @($ipv4 | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })

        $statusText = switch ($status) {
            'Up'       { if ($speed) { "Connected $dot $speed" } else { 'Connected' } }
            'Disabled' { 'Disabled' }
            default    { if ($kind -eq 'Ethernet') { 'Cable unplugged' } else { 'Not connected' } }
        }
        $ipText = if ($primary) { "$($primary.IPAddress)/$($primary.PrefixLength) $(if ($dhcp) { 'DHCP' } else { 'static' })" }
                  elseif ($dhcp) { if ($up) { 'DHCP - no address yet' } else { 'DHCP' } }
                  else { 'No IP address' }

        [PSCustomObject]@{
            Name                 = [string]$a.Name
            InterfaceIndex       = $idx
            InterfaceGuid        = "$($a.InterfaceGuid)".ToUpper()
            InterfaceDescription = [string]$a.InterfaceDescription
            Status               = $status
            MacAddress           = $mac
            LinkSpeed            = $speed
            Kind                 = $kind
            Type                 = $(if ($isVpn) { 'VPN' } else { $kindTxt[$kind] })
            Dhcp                 = $dhcp
            IPv4                 = if ($primary) { [string]$primary.IPAddress } else { '' }
            PrefixLength         = if ($primary) { [int]$primary.PrefixLength } else { $null }
            Gateway              = if ($route) { [string]$route.NextHop } else { '' }
            DefaultRouteMetric   = if ($route -and $up) { [int]$route.RouteMetric + [int]$iface.InterfaceMetric } else { $null }
            Dns                  = @($dnsByIdx[$idx])
            DnsStatic            = $dnsStatic
            Mtu                  = if ($iface -and $iface.NlMtu -lt 65536) { [int]$iface.NlMtu } else { $null }
            VlanSupported        = $null
            VlanId               = $null
            VlanKeyword          = $null
            AllIPv4              = $allIPv4
            # Display-only fields for the tiles
            Glyph                = [string][char]$(if ($isVpn) { $glyphs.Vpn } else { $glyphs[$kind] })
            StatusText           = $statusText
            IPText               = $ipText
            StatusBrush          = switch ($status) { 'Up' { '#34C759' } 'Disabled' { '#FF3B30' } default { '#8E8E93' } }
            IconBg               = if ($up) { '#0A84FF' } else { '#E5E5EA' }
            IconFg               = if ($up) { '#FFFFFF' } else { '#8E8E93' }
            CableBrush           = if ($up) { '#34C759' } else { '#C7C7CC' }
            Tooltip              = "$($a.InterfaceDescription)`nMAC $mac"
            Cached               = $false   # $true = drawn from last session's cache, faded until the live scan lands
        }
    }
}

function Get-VlanInventory {
    $ns    = 'root/StandardCimv2'
    $props = Get-CimInstance -Namespace $ns -ClassName MSFT_NetAdapterAdvancedPropertySettingData -ErrorAction SilentlyContinue
    $names = @(Get-CimInstance -Namespace $ns -ClassName MSFT_NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
    return (ConvertTo-VlanInfo $props $names)
}

# ---- network mutations (run in the background "work" runspace) -------
# Clears default routes and IPv4 addresses from BOTH the active and persistent stores. Clearing only
# the active store (the cmdlets' default view) leaves stale persistent entries behind on unplugged
# NICs, which then makes New-NetIPAddress fail with "Instance DefaultGateway already exists".
function Clear-IPv4Config([int]$Idx, [string[]]$KeepOrigins = @('WellKnown')) {
    foreach ($store in 'ActiveStore', 'PersistentStore') {
        Get-NetRoute -InterfaceIndex $Idx -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -PolicyStore $store -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetIPAddress -InterfaceIndex $Idx -AddressFamily IPv4 -PolicyStore $store -ErrorAction SilentlyContinue |
            Where-Object { "$($_.PrefixOrigin)" -notin $KeepOrigins } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Set-StaticConfig {
    param([int]$Idx, [string]$Ip, [int]$Prefix, [string]$Gateway, [string[]]$Dns, $Extra)

    Set-NetIPInterface -InterfaceIndex $Idx -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
    Clear-IPv4Config $Idx

    if ($Gateway) {
        New-NetIPAddress -InterfaceIndex $Idx -IPAddress $Ip -PrefixLength $Prefix -DefaultGateway $Gateway -ErrorAction Stop | Out-Null
    } else {
        New-NetIPAddress -InterfaceIndex $Idx -IPAddress $Ip -PrefixLength $Prefix -ErrorAction Stop | Out-Null
    }

    # Secondary IPs are SkipAsSource so outbound traffic keeps using the primary address.
    foreach ($e in @($Extra)) {
        if (-not $e) { continue }
        New-NetIPAddress -InterfaceIndex $Idx -IPAddress $e.Ip -PrefixLength $e.Prefix -SkipAsSource $true -ErrorAction Stop | Out-Null
    }

    $Dns = @($Dns | Where-Object { $_ })
    if ($Dns.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceIndex $Idx -ServerAddresses $Dns -ErrorAction Stop
    } else {
        Set-DnsClientServerAddress -InterfaceIndex $Idx -ResetServerAddresses -ErrorAction SilentlyContinue
    }
}

function Set-InterfaceDhcp([int]$Idx) {
    Clear-IPv4Config $Idx @('WellKnown', 'Dhcp')
    Set-NetIPInterface -InterfaceIndex $Idx -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
    Set-DnsClientServerAddress -InterfaceIndex $Idx -ResetServerAddresses -ErrorAction SilentlyContinue
}

function Set-InterfaceMtu([int]$Idx, [int]$Mtu) {
    Set-NetIPInterface -InterfaceIndex $Idx -AddressFamily IPv4 -NlMtuBytes $Mtu -ErrorAction Stop
}

function Set-Vlan([string]$Name, [string]$Keyword, [int]$VlanId) {
    Set-NetAdapterAdvancedProperty -Name $Name -RegistryKeyword $Keyword -RegistryValue ([string]$VlanId) -ErrorAction Stop
}

# Puts an adapter back to a previously captured inventory object (IP config + MTU; VLAN is handled
# separately since it's a link-resetting driver property). Used for automatic rollback when an
# apply fails, and for "Undo last change".
function Restore-AdapterConfig($snap) {
    $idx = [int]$snap.InterfaceIndex
    if ($snap.Dhcp) {
        Set-InterfaceDhcp $idx
        if ($snap.DnsStatic -and @($snap.Dns).Count) {
            Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @($snap.Dns) -ErrorAction Stop
        }
    } elseif ($snap.IPv4) {
        $primaryCidr = "$($snap.IPv4)/$($snap.PrefixLength)"
        $extra = @($snap.AllIPv4 | Where-Object { $_ -and $_ -ne $primaryCidr } | ForEach-Object {
            $p = $_.Split('/'); [PSCustomObject]@{ Ip = $p[0]; Prefix = [int]$p[1] }
        })
        Set-StaticConfig -Idx $idx -Ip $snap.IPv4 -Prefix ([int]$snap.PrefixLength) -Gateway $snap.Gateway -Dns @($snap.Dns) -Extra $extra
    } else {
        Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
        Clear-IPv4Config $idx
    }
    if ($snap.Mtu) {
        $cur = (Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).NlMtu
        if ($cur -and $cur -ne $snap.Mtu) { Set-InterfaceMtu $idx ([int]$snap.Mtu) }
    }
}

# One complete, self-contained change: fresh "before" snapshot -> change -> automatic rollback on
# failure -> MTU/VLAN as separate best-effort steps -> fresh inventory. Runs in the work runspace
# and returns a plain result object; the UI thread does the logging/status/undo bookkeeping.
# Security: the adapter is identified only by its interface index. Its name and VLAN driver keyword
# are read live here, never taken from the caller - on the UI side they may come from the cache in
# %APPDATA%, which anything running as the user can edit, while this code runs as administrator.
function Invoke-ConfigTransaction {
    param([int]$Idx, [string]$Action, $Cfg, $Snapshot, $VlanTarget)
    $r = [PSCustomObject]@{
        Ok = $false; Error = $null; RolledBack = $false; RollbackError = $null
        Warnings = @(); Log = @(); VlanApplied = $null; VlanKeyword = $null; Before = $null; After = $null
    }
    $r.Before = @(Get-AdapterInventory -InterfaceIndex $Idx) | Select-Object -First 1
    if (-not $r.Before) {
        $r.Error = "The adapter (interface $Idx) is no longer present."
        $r.After = @(Get-AdapterInventory)
        return $r
    }
    $Name = $r.Before.Name
    try {
        switch ($Action) {
            'Static'  { Set-StaticConfig -Idx $Idx -Ip $Cfg.Ip -Prefix $Cfg.Prefix -Gateway $Cfg.Gateway -Dns $Cfg.Dns -Extra $Cfg.Extra }
            'Dhcp'    { Set-InterfaceDhcp $Idx }
            'Restore' {
                if ([int]$Snapshot.InterfaceIndex -ne $Idx) { throw 'The undo snapshot belongs to a different adapter.' }
                # Undoing "start sharing": stop sharing first, or Windows would keep forcing its address.
                if ($Snapshot.UndoIcs) { Disable-IcsAll }
                Restore-AdapterConfig $Snapshot
            }
            default   { throw "Unknown action '$Action'." }
        }
        $r.Ok = $true
    } catch {
        $r.Error = $_.Exception.Message
        try { Restore-AdapterConfig $r.Before; $r.RolledBack = $true }
        catch { $r.RollbackError = $_.Exception.Message }
    }
    if ($r.Ok) {
        if ($Cfg -and $Cfg.Mtu -gt 0 -and $Cfg.Mtu -ne [int]$r.Before.Mtu) {
            try { Set-InterfaceMtu $Idx $Cfg.Mtu; $r.Log += "MTU     ${Name}: $($r.Before.Mtu) -> $($Cfg.Mtu)" }
            catch { $r.Warnings += "MTU not applied ($($_.Exception.Message.Trim()))" }
        }
        if ($null -ne $VlanTarget -and "$VlanTarget" -ne '') {
            try {
                $live = (Get-VlanInventory)[$Name]
                if (-not $live -or -not $live.Supported) { throw "this adapter's driver has no VLAN ID setting" }
                Set-Vlan -Name $Name -Keyword $live.Keyword -VlanId ([int]$VlanTarget)
                $r.VlanApplied = [int]$VlanTarget; $r.VlanKeyword = $live.Keyword
                $r.Log += "VLAN    ${Name}: $($live.Value) -> $VlanTarget"
            } catch { $r.Warnings += "VLAN not applied ($("$($_.Exception.Message)".Trim()))" }
        }
    }
    $r.After = @(Get-AdapterInventory)
    return $r
}

# Adapter-level actions and tools. Throws on failure; returns the fresh inventory where relevant.
# Like Invoke-ConfigTransaction, the adapter name is resolved live from the interface index.
function Invoke-AdapterAction([string]$Action, [int]$Idx = 0) {
    # Re-throw plain messages: -ErrorAction Stop failures otherwise surface as the generic
    # "The running command stopped because the preference variable..." wrapper.
    $run = { param($sb) try { & $sb } catch { throw "$($_.Exception.Message)".Trim() } }
    if ($Action -in 'Enable', 'Disable', 'Restart', 'Renew') {
        $Name = (Get-CimInstance -Namespace 'root/StandardCimv2' -ClassName MSFT_NetAdapter `
                    -Filter "InterfaceIndex=$Idx" -ErrorAction SilentlyContinue | Select-Object -First 1).Name
        if (-not $Name) { throw "The adapter (interface $Idx) is no longer present." }
    }
    switch ($Action) {
        'Enable'  { & $run { Enable-NetAdapter  -Name $Name -Confirm:$false -ErrorAction Stop } }
        'Disable' { & $run { Disable-NetAdapter -Name $Name -Confirm:$false -ErrorAction Stop } }
        'Restart' { & $run { Restart-NetAdapter -Name $Name -Confirm:$false -ErrorAction Stop } }
        'Renew' {
            $out = & ipconfig.exe /renew "$Name" 2>&1
            if ($LASTEXITCODE -ne 0) { throw (@($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) | Select-Object -Last 1) }
        }
        'FlushDns' {
            $out = & ipconfig.exe /flushdns 2>&1
            if ($LASTEXITCODE -ne 0) { throw (@($out | Where-Object { "$_".Trim() }) -join ' ') }
            return [PSCustomObject]@{ After = $null }
        }
        'ClearArp' {
            $out = & netsh.exe interface ip delete arpcache 2>&1
            if ($LASTEXITCODE -ne 0) { throw (@($out | Where-Object { "$_".Trim() }) -join ' ') }
            return [PSCustomObject]@{ After = $null }
        }
        default { throw "Unknown action '$Action'." }
    }
    return [PSCustomObject]@{ After = @(Get-AdapterInventory) }
}

function Invoke-PingTest([string]$Target, [int]$Count = 4, [int]$TimeoutMs = 1000) {
    $ping = New-Object System.Net.NetworkInformation.Ping
    $rtts = @(); $lastStatus = $null
    try {
        for ($i = 0; $i -lt $Count; $i++) {
            $r = $ping.Send($Target, $TimeoutMs)
            if ($r.Status -eq 'Success') { $rtts += $r.RoundtripTime } else { $lastStatus = "$($r.Status)" }
        }
    } catch {
        # Base exception = the useful SocketException text (e.g. "No such host is known").
        throw $_.Exception.GetBaseException().Message
    } finally { $ping.Dispose() }
    [PSCustomObject]@{
        Target = $Target; Sent = $Count; Received = $rtts.Count; LastFailure = $lastStatus
        Min = if ($rtts) { ($rtts | Measure-Object -Minimum).Minimum } else { $null }
        Max = if ($rtts) { ($rtts | Measure-Object -Maximum).Maximum } else { $null }
        Avg = if ($rtts) { [math]::Round(($rtts | Measure-Object -Average).Average) } else { $null }
    }
}

# ---- internet connection sharing (ICS) --------------------------------
# Windows' own "share this connection" feature: one adapter (public) shares its internet with another
# (private); Windows then gives the private adapter a fixed address and runs a DHCP server + DNS proxy
# on it. What Windows lets you configure is limited and the UI says so: the pair, the address of the
# PC on the private side (ScopeAddress; always a /24, devices get the rest of it, with the PC as
# gateway and DNS), and whether sharing survives a reboot. Controlled through the HNetCfg COM API,
# which needs administrator rights.

# Address the PC takes on the shared port. Private ranges only, and not .0/.255 of its /24.
function Assert-IcsScopeAddress([string]$Address) {
    if (-not (Test-IPv4 $Address)) { throw 'Type the address this PC should have on the shared port, e.g. 192.168.137.1.' }
    $a = ConvertTo-NormalizedIPv4 $Address
    $o = @($a.Split('.') | ForEach-Object { [int]$_ })
    $isPrivate = $o[0] -eq 10 -or ($o[0] -eq 172 -and $o[1] -ge 16 -and $o[1] -le 31) -or ($o[0] -eq 192 -and $o[1] -eq 168)
    if (-not $isPrivate) { throw "$a is not a private address - use one like 192.168.137.1, 192.168.1.1 or 10.0.0.1." }
    if ($o[3] -eq 0 -or $o[3] -eq 255) { throw "$a can't be used - the last number must be between 1 and 254." }
    return $a
}

function Get-IcsConnections {
    $m = New-Object -ComObject HNetCfg.HNetShare
    if (-not $m.SharingInstalled) { throw 'Internet sharing is not available (it needs administrator rights and the Internet Connection Sharing service).' }
    foreach ($c in @($m.EnumEveryConnection)) {
        $p = $m.NetConnectionProps.Invoke($c)
        $cfg = $null
        try { $cfg = $m.INetSharingConfigurationForINetConnection.Invoke($c) } catch { }
        $enabled = [bool]($cfg -and $cfg.SharingEnabled)
        [PSCustomObject]@{
            Guid = "$($p.Guid)".ToUpper(); Name = "$($p.Name)"; Config = $cfg; Enabled = $enabled
            Role = if (-not $enabled) { $null } elseif ($cfg.SharingConnectionType -eq 0) { 'Public' } else { 'Private' }
        }
    }
}

# Devices recently seen on the shared port (neighbor cache), excluding the PC's own address.
function Get-IcsClients([int]$Idx, [string]$Exclude) {
    Get-CimInstance -Namespace 'root/StandardCimv2' -ClassName MSFT_NetNeighbor -Filter "InterfaceIndex=$Idx AND AddressFamily=2" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.State -in 2, 3, 4, 5 -and $_.IPAddress -ne $Exclude -and (Test-IPv4 $_.IPAddress) -and
            (Test-UsableIPv4 $_.IPAddress) -and $_.IPAddress -notmatch '\.255$' -and
            $_.LinkLayerAddress -and $_.LinkLayerAddress -notmatch '^(FF-?){5}FF$|^0+$'
        } |
        Sort-Object { ConvertTo-IPv4Int $_.IPAddress } |
        ForEach-Object {
            [PSCustomObject]@{ Ip = "$($_.IPAddress)"; Mac = (Format-MacAddress $_.LinkLayerAddress); Seen = $(if ($_.State -eq 5) { 'active now' } else { 'seen recently' }) }
        }
}

function Get-IcsState {
    $s = [PSCustomObject]@{ Available = $false; Error = $null; PublicIdx = 0; PrivateIdx = 0; ScopeAddress = '192.168.137.1'; Persist = $false; Clients = @() }
    $scope = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters' -Name ScopeAddress -ErrorAction SilentlyContinue).ScopeAddress
    if (Test-IPv4 $scope) { $s.ScopeAddress = "$scope" }
    $s.Persist = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedAccess' -Name EnableRebootPersistConnection -ErrorAction SilentlyContinue).EnableRebootPersistConnection -eq 1
    try {
        $idxByGuid = @{}
        foreach ($a in Get-CimInstance -Namespace 'root/StandardCimv2' -ClassName MSFT_NetAdapter -ErrorAction SilentlyContinue) {
            $idxByGuid["$($a.InterfaceGuid)".ToUpper()] = [int]$a.InterfaceIndex
        }
        foreach ($c in Get-IcsConnections) {
            if ($c.Role -eq 'Public')  { $s.PublicIdx  = [int]$idxByGuid[$c.Guid] }
            if ($c.Role -eq 'Private') { $s.PrivateIdx = [int]$idxByGuid[$c.Guid] }
        }
        $s.Available = $true
    } catch { $s.Error = "$($_.Exception.Message)".Trim() }
    if ($s.PrivateIdx) { $s.Clients = @(Get-IcsClients $s.PrivateIdx $s.ScopeAddress) }
    return $s
}

# Writes the shared-port address and the "survive reboot" flag. Returns $true if the address changed.
function Set-IcsSettings([string]$ScopeAddress, [bool]$Persist) {
    $params = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters'
    $old = (Get-ItemProperty $params -Name ScopeAddress -ErrorAction SilentlyContinue).ScopeAddress
    Set-ItemProperty $params -Name ScopeAddress -Value $ScopeAddress
    Set-ItemProperty $params -Name ScopeAddressBackup -Value $ScopeAddress
    $persistKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedAccess'
    if (-not (Test-Path $persistKey)) { New-Item $persistKey -Force | Out-Null }
    Set-ItemProperty $persistKey -Name EnableRebootPersistConnection -Value ([int]$Persist) -Type DWord
    return ("$old" -ne $ScopeAddress)
}

function Disable-IcsAll {
    foreach ($c in @(Get-IcsConnections | Where-Object { $_.Enabled })) { $c.Config.DisableSharing() }
}

# Windows allows one sharing pair at a time: stop any existing one, then share public -> private.
# A changed ScopeAddress only takes effect after the sharing service restarts.
function Enable-IcsPair([int]$PublicIdx, [int]$PrivateIdx, [bool]$RestartService) {
    $svc = Get-Service SharedAccess -ErrorAction Stop
    if ($svc.StartType -eq 'Disabled') { Set-Service SharedAccess -StartupType Manual -ErrorAction Stop }
    $guidByIdx = @{}
    foreach ($a in Get-CimInstance -Namespace 'root/StandardCimv2' -ClassName MSFT_NetAdapter -ErrorAction SilentlyContinue) {
        $guidByIdx[[int]$a.InterfaceIndex] = "$($a.InterfaceGuid)".ToUpper()
    }
    $pubGuid = $guidByIdx[$PublicIdx]; $privGuid = $guidByIdx[$PrivateIdx]
    if (-not $pubGuid -or -not $privGuid) { throw 'One of the adapters is no longer present.' }
    Disable-IcsAll
    if ($RestartService -and (Get-Service SharedAccess).Status -eq 'Running') { Restart-Service SharedAccess -Force -ErrorAction Stop }
    $conns = @(Get-IcsConnections)
    $pub  = $conns | Where-Object { $_.Guid -eq $pubGuid }  | Select-Object -First 1
    $priv = $conns | Where-Object { $_.Guid -eq $privGuid } | Select-Object -First 1
    if (-not $pub -or -not $pub.Config)   { throw "Windows can't share the internet connection of that adapter." }
    if (-not $priv -or -not $priv.Config) { throw "Windows can't share internet onto that adapter." }
    $pub.Config.EnableSharing(0)    # ICSSHARINGTYPE_PUBLIC
    $priv.Config.EnableSharing(1)   # ICSSHARINGTYPE_PRIVATE
}

# One sharing change in the work runspace. Like the other workers it takes interface indexes only.
#   Start  - share PublicIdx -> PrivateIdx with the given address; Before = the private adapter's
#            previous settings, so the UI can offer Undo.
#   Update - change address / reboot persistence of the running share.
#   Stop   - stop sharing and put the private adapter back on DHCP (Windows leaves it on its
#            static sharing address otherwise).
function Invoke-IcsChange {
    param([string]$Action, [int]$PublicIdx, [int]$PrivateIdx, [string]$ScopeAddress, [bool]$Persist)
    $r = [PSCustomObject]@{ Ok = $false; Error = $null; Before = $null; After = $null; State = $null }
    $run = { param($sb) try { & $sb } catch { throw "$($_.Exception.Message)".Trim() } }
    try {
        switch ($Action) {
            'Start' {
                if (-not $PublicIdx -or -not $PrivateIdx -or $PublicIdx -eq $PrivateIdx) { throw 'Pick two different adapters.' }
                $scope = Assert-IcsScopeAddress $ScopeAddress
                $r.Before = @(Get-AdapterInventory -InterfaceIndex $PrivateIdx) | Select-Object -First 1
                $changed = & $run { Set-IcsSettings $scope $Persist }
                & $run { Enable-IcsPair $PublicIdx $PrivateIdx $changed }
            }
            'Update' {
                $scope = Assert-IcsScopeAddress $ScopeAddress
                $cur = Get-IcsState
                if (-not $cur.PublicIdx -or -not $cur.PrivateIdx) { throw 'Sharing is not active.' }
                $changed = & $run { Set-IcsSettings $scope $Persist }
                if ($changed) { & $run { Enable-IcsPair $cur.PublicIdx $cur.PrivateIdx $true } }
            }
            'Stop' {
                $cur = Get-IcsState
                & $run { Disable-IcsAll }
                if ($cur.PrivateIdx) { & $run { Set-InterfaceDhcp $cur.PrivateIdx } }
            }
            default { throw "Unknown action '$Action'." }
        }
        $r.Ok = $true
    } catch { $r.Error = "$($_.Exception.Message)".Trim() }
    $r.State = Get-IcsState
    $r.After = @(Get-AdapterInventory)
    return $r
}

# Copied into the background runspaces (see New-WorkerPool).
$script:WorkerFunctions = @(
    'Test-IPv4', 'ConvertTo-NormalizedIPv4', 'ConvertTo-IPv4Int', 'ConvertFrom-IPv4Int', 'Get-PrefixMaskInt',
    'Test-UsableIPv4', 'Format-LinkSpeed', 'Format-MacAddress', 'Get-AdapterKind', 'ConvertTo-VlanInfo',
    'Get-AdapterInventory', 'Get-VlanInventory', 'Clear-IPv4Config', 'Set-StaticConfig', 'Set-InterfaceDhcp',
    'Set-InterfaceMtu', 'Set-Vlan', 'Restore-AdapterConfig', 'Invoke-ConfigTransaction',
    'Invoke-AdapterAction', 'Invoke-PingTest',
    'Assert-IcsScopeAddress', 'Get-IcsConnections', 'Get-IcsClients', 'Get-IcsState', 'Set-IcsSettings',
    'Disable-IcsAll', 'Enable-IcsPair', 'Invoke-IcsChange'
)

# ---- profiles, cache & change log (UI thread, local files) -----------
$script:DataDir     = Join-Path $env:APPDATA 'NetworkControlCenter'
$script:ProfilePath = Join-Path $script:DataDir 'profiles.json'
$script:CachePath   = Join-Path $script:DataDir 'adapter-cache.json'
$script:LogPath     = Join-Path $script:DataDir 'changes.log'
$script:ProfileLoadWarning = $null

function Get-DefaultProfiles {
    @(
        [PSCustomObject]@{ Name = 'DHCP (Auto)';               Mode = 'DHCP';   IP = '';             Prefix = $null; Gateway = '';            Dns1 = ''; Dns2 = ''; Mtu = ''; Vlan = '' }
        [PSCustomObject]@{ Name = 'Newtec MDM5000 - Mgmt';     Mode = 'Static'; IP = '192.168.1.10';  Prefix = 24;    Gateway = '192.168.1.1';  Dns1 = ''; Dns2 = ''; Mtu = ''; Vlan = '' }
        [PSCustomObject]@{ Name = 'Pepwave - Default Subnet';  Mode = 'Static'; IP = '192.168.50.10'; Prefix = 24;    Gateway = '192.168.50.1'; Dns1 = ''; Dns2 = ''; Mtu = ''; Vlan = '' }
        [PSCustomObject]@{ Name = 'Lab / Cisco Console LAN';   Mode = 'Static'; IP = '10.10.10.10';   Prefix = 24;    Gateway = '10.10.10.1';   Dns1 = ''; Dns2 = ''; Mtu = ''; Vlan = '' }
    )
}

# Coerces anything profile-shaped (from disk or an imported file) into the flat profile shape,
# or $null if it has no usable name. Keeps a hand-edited or foreign JSON file from breaking the UI.
function ConvertTo-NccProfile($o) {
    if (-not $o -or [string]::IsNullOrWhiteSpace([string]$o.Name)) { return $null }
    $prefix = $null
    if ("$($o.Prefix)".Trim()) { try { $prefix = [int](Resolve-Prefix "$($o.Prefix)") } catch { } }
    [PSCustomObject]@{
        Name    = ([string]$o.Name).Trim()
        Mode    = $(if ("$($o.Mode)" -eq 'DHCP') { 'DHCP' } else { 'Static' })
        IP      = ([string]$o.IP).Trim()
        Prefix  = $prefix
        Gateway = ([string]$o.Gateway).Trim()
        Dns1    = ([string]$o.Dns1).Trim()
        Dns2    = ([string]$o.Dns2).Trim()
        Mtu     = ([string]$o.Mtu).Trim()
        Vlan    = ([string]$o.Vlan).Trim()
    }
}

function Format-ProfileSummary($p) {
    if ($p.Mode -eq 'DHCP') { $s = 'Automatic (DHCP)' }
    else {
        $s = "$($p.IP)/$($p.Prefix)"
        if ($p.Gateway) { $s += "   gateway $($p.Gateway)" }
        if ($p.Dns1) { $s += "   dns $($p.Dns1)" }
    }
    if ($p.Mtu) { $s += "   mtu $($p.Mtu)" }
    if ($p.Vlan) { $s += "   vlan $($p.Vlan)" }
    return $s
}

function Read-ProfileFile([string]$Path) {
    # Materialize into a plain variable BEFORE wrapping with @() - ConvertFrom-Json emits a
    # multi-element JSON array as a SINGLE pipeline object (not one object per element), so
    # wrapping that live pipeline output directly in @() nests the whole array inside a
    # 1-element outer array instead of flattening it. Assigning to $loaded first sidesteps
    # that. Do not collapse this back to `@(Get-Content ... | ConvertFrom-Json)`.
    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $loaded = $raw | ConvertFrom-Json
    return @(@($loaded) | ForEach-Object { ConvertTo-NccProfile $_ } | Where-Object { $_ })
}

function Load-Profiles {
    if (Test-Path $script:ProfilePath) {
        try {
            return @(Read-ProfileFile $script:ProfilePath)
        } catch {
            # Never silently overwrite a file the user may have spent time on - keep a copy first.
            $backup = "$script:ProfilePath.corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
            try { Copy-Item -Path $script:ProfilePath -Destination $backup -Force } catch { }
            $script:ProfileLoadWarning = "profiles.json could not be read and was backed up to $(Split-Path $backup -Leaf); default profiles loaded."
        }
    }
    $defaults = Get-DefaultProfiles
    Save-Profiles $defaults
    return $defaults
}

# Writes JSON via temp file + move so a crash mid-write can't leave a truncated file. By default
# the data is written as an array (-InputObject keeps 0/1 items as a JSON array, unlike the pipeline).
function Write-JsonFileAtomic([string]$Path, $Data, [switch]$AsObject) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = if ($AsObject) { ConvertTo-Json -InputObject $Data -Depth 6 -Compress }
            else { ConvertTo-Json -InputObject @($Data) -Depth 5 }
    $tmp  = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Path $tmp -Destination $Path -Force
}

function Save-Profiles($profiles) {
    Write-JsonFileAtomic $script:ProfilePath @($profiles)
}

# The last known adapter list + VLAN support, so the next launch can draw the home screen
# instantly while the live scan runs. Purely an accelerator: any problem just means "no cache".
function Save-InventoryCache {
    try {
        $vlan = @{}
        foreach ($k in $script:VlanCache.Keys) { $vlan[$k] = $script:VlanCache[$k] }
        Write-JsonFileAtomic $script:CachePath ([PSCustomObject]@{
            Version = 4; Saved = (Get-Date).ToString('o'); Adapters = @($script:Adapters | Where-Object { -not $_.Cached }); Vlan = $vlan
        }) -AsObject
    } catch { }
}

# Cached adapters are shown greyed out ("last known") - the state may have changed since, e.g. a
# cable unplugged - until the live scan replaces them about a second later.
function Read-InventoryCache {
    try {
        if (-not (Test-Path $script:CachePath)) { return $null }
        $c = [System.IO.File]::ReadAllText($script:CachePath) | ConvertFrom-Json
        if ($c.Version -ne 4) { return $null }
        $vlan = @{}
        if ($c.Vlan) { foreach ($p in $c.Vlan.PSObject.Properties) { $vlan[$p.Name] = $p.Value } }
        $adapters = @(@($c.Adapters) | Where-Object { $_ -and $_.Name } | ForEach-Object {
            $_.Dns = @($_.Dns | Where-Object { $_ }); $_.AllIPv4 = @($_.AllIPv4 | Where-Object { $_ })
            $_.Cached      = $true
            $_.StatusText  = 'Last known - checking...'
            $_.StatusBrush = '#C7C7CC'; $_.IconBg = '#E5E5EA'; $_.IconFg = '#8E8E93'; $_.CableBrush = '#D1D1D6'
            $_.DefaultRouteMetric = $null
            $_
        })
        return [PSCustomObject]@{ Adapters = $adapters; Vlan = $vlan; Saved = $c.Saved }
    } catch { return $null }
}

# Append-only audit trail of every change made through the app - invaluable when reconstructing
# "what did I change on site?" afterwards. Logging must never block or fail a network change.
function Write-ChangeLog([string]$msg) {
    try {
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        if ((Test-Path $script:LogPath) -and (Get-Item $script:LogPath).Length -gt 1MB) {
            Move-Item -Path $script:LogPath -Destination "$script:LogPath.1" -Force
        }
        $line = ($msg -replace '\s*\r?\n\s*', ' ').Trim()
        Add-Content -Path $script:LogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $line" -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------
# 5. UI BINDING / STATE / BACKGROUND JOBS
# ---------------------------------------------------------------------
$script:Adapters      = @()     # all adapters (virtual included; the toggle only filters the view)
$script:VlanCache     = @{}     # Name -> {Supported, Keyword, Value}
$script:SelectedIdx   = 0       # InterfaceIndex of the adapter on the config page, 0 = home page
$script:Profiles      = @()
$script:UndoSnapshot  = $null   # inventory object captured before the last successful change
$script:FormBaseline  = ''      # form signature right after it was filled from the adapter
$script:BaselineMask  = ''
$script:PingHomeAuto  = ''      # gateway last auto-filled into the home ping box
$script:PingTargetAuto = ''     # same for the adapter page's ping box
$script:IcsState      = $null   # last Get-IcsState result (internet sharing)
$script:IcsRefreshing = $false
$script:IcsEdited     = $false  # user changed the sharing address / persistence - don't overwrite on refresh
$script:FormDirty     = $false
$script:Populating    = $false
$script:ScanRunning   = $false
$script:Busy          = $false
$script:Jobs          = New-Object System.Collections.ArrayList
$script:ScanPool      = $null   # light runspace: inventory, VLAN scan, ping, tools
$script:WorkPool      = $null   # runspace with the networking modules pre-loaded: adapter changes
$script:Converter     = New-Object System.Windows.Media.BrushConverter

# ---- background jobs --------------------------------------------------
# All network work runs in background runspaces so the window stays responsive. A job is plain
# script text + parameters; its OnDone scriptblock runs back on the UI thread (from the poll timer)
# as `& $OnDone $Result $ErrorMessage $Context`. Pass state via -Context rather than closures:
# GetNewClosure() would bind the block to a new module scope that can't see this script's functions.
function New-WorkerPool {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
    foreach ($n in $script:WorkerFunctions) {
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry(
            $n, (Get-Item "function:$n").Definition)))
    }
    $pool = [runspacefactory]::CreateRunspacePool(1, 1, $iss, $Host)
    $pool.ApartmentState = 'MTA'
    [void]$pool.BeginOpen($null, $null)
    $pool
}

function Start-WorkJob {
    param($Pool, [string]$Script, [hashtable]$Params = @{}, $Context, [scriptblock]$OnDone, [string]$BusyLabel)
    if (-not $Pool) { Set-Status 'Still starting up - try again in a second.' 'warn'; return }
    $job = [PSCustomObject]@{
        Pool = $Pool; Script = $Script; Params = $Params; Context = $Context; OnDone = $OnDone
        Foreground = [bool]$BusyLabel; PS = $null; Async = $null; Failed = $null
    }
    [void]$script:Jobs.Add($job)
    if ($BusyLabel) { Set-Busy $true $BusyLabel }
    Start-PendingJobs
}

function Start-PendingJobs {
    foreach ($job in @($script:Jobs)) {
        if ($job.PS -or $job.Failed) { continue }
        $state = $job.Pool.RunspacePoolStateInfo.State
        if ($state -in 'Broken', 'Closed', 'Closing') {
            $job.Failed = "The background worker failed to start: $($job.Pool.RunspacePoolStateInfo.Reason.Message)"
            continue
        }
        if ($state -ne 'Opened') { continue }
        $ps = [powershell]::Create()
        $ps.RunspacePool = $job.Pool
        [void]$ps.AddScript($job.Script)
        foreach ($k in $job.Params.Keys) { [void]$ps.AddParameter($k, $job.Params[$k]) }
        $job.PS = $ps
        $job.Async = $ps.BeginInvoke()
    }
}

function Complete-WorkJobs {
    Start-PendingJobs
    foreach ($job in @($script:Jobs)) {
        if (-not $job.Failed -and (-not $job.Async -or -not $job.Async.IsCompleted)) { continue }
        [void]$script:Jobs.Remove($job)
        $result = $null; $err = $job.Failed
        if (-not $err) {
            try {
                $out = $job.PS.EndInvoke($job.Async)
                if ($out.Count) { $result = $out[0] }
                if ($null -eq $result -and $job.PS.Streams.Error.Count) { $err = "$($job.PS.Streams.Error[0].Exception.Message)" }
            } catch {
                $err = $_.Exception.GetBaseException().Message
            } finally {
                $job.PS.Dispose()
            }
        }
        if ($job.Foreground -and -not @($script:Jobs | Where-Object { $_.Foreground }).Count) { Set-Busy $false }
        if ($job.OnDone) {
            try { & $job.OnDone $result $err $job.Context }
            catch { Set-Status "Error: $($_.Exception.Message)" 'err' }
        }
    }
}

# While a change runs, the controls are locked (so nothing can be changed twice) but the window
# keeps painting; the thin progress bar shows something is happening.
function Set-Busy([bool]$On, [string]$Label) {
    $script:Busy = $On
    foreach ($p in @($ctl.pnlConfig, $ctl.pnlHome, $ctl.pnlAppBar)) { $p.IsEnabled = -not $On }
    $ctl.pbBusy.Visibility = if ($On) { 'Visible' } else { 'Collapsed' }
    if ($On -and $Label) { Set-Status $Label }
}

function Confirm-Action([string]$Text, [string]$Title = 'Network Control Center') {
    $r = [System.Windows.MessageBox]::Show($window, $Text, $Title, 'YesNo', 'Warning')
    return ($r -eq [System.Windows.MessageBoxResult]::Yes)
}

# ---- smooth wheel scrolling ---------------------------------------------
# WPF's default wheel handling jumps 48 px per notch, and lets whatever is under the cursor take
# the wheel: a focused combo box then *changes its value* instead of the page scrolling. The page's
# ScrollViewers take the wheel first (PreviewMouseWheel) and ease toward a target offset instead.
# Only a nested scroll area that can still scroll in that direction (e.g. a long additional-IPs
# list) or an open drop-down keeps the wheel.
$script:SmoothTargets = @{}   # ScrollViewer -> target vertical offset
$script:SmoothTimer   = $null
$script:SmoothLastSet = @{}   # ScrollViewer -> offset the animation set last (to recognise its own ScrollChanged)

function Enable-SmoothScroll($Viewer) {
    if (-not $script:SmoothTimer) {
        $script:SmoothTimer = New-Object System.Windows.Threading.DispatcherTimer([System.Windows.Threading.DispatcherPriority]::Render)
        $script:SmoothTimer.Interval = [TimeSpan]::FromMilliseconds(10)
        $script:SmoothTimer.Add_Tick({ Step-SmoothScroll })
    }
    $Viewer.Add_PreviewMouseWheel({ param($sender, $e) Invoke-SmoothWheel $sender $e })
    # Dragging the scrollbar or paging must not be fought by a pending wheel animation. ScrollChanged
    # arrives after layout, so compare with the offset the animation itself last set: anything else
    # was moved by the user (or by code such as ScrollToTop) and cancels the animation.
    $Viewer.Add_ScrollChanged({ param($sender, $e)
        if ($e.VerticalChange -ne 0 -and $script:SmoothTargets.ContainsKey($sender) -and
            (-not $script:SmoothLastSet.ContainsKey($sender) -or [math]::Abs($e.VerticalOffset - $script:SmoothLastSet[$sender]) -gt 1)) {
            $script:SmoothTargets.Remove($sender)
            $script:SmoothLastSet.Remove($sender)
        }
    })
}

function Invoke-SmoothWheel($Viewer, $e) {
    $node = $e.OriginalSource
    while ($node -and $node -ne $Viewer) {
        if ($node -is [System.Windows.Controls.ComboBox] -and $node.IsDropDownOpen) { return }
        if ($node -is [System.Windows.Controls.ScrollViewer] -and $node.ScrollableHeight -gt 0 -and
            (($e.Delta -gt 0 -and $node.VerticalOffset -gt 0) -or ($e.Delta -lt 0 -and $node.VerticalOffset -lt $node.ScrollableHeight))) { return }
        $node = if ($node -is [System.Windows.Media.Visual]) { [System.Windows.Media.VisualTreeHelper]::GetParent($node) }
                else { [System.Windows.LogicalTreeHelper]::GetParent($node) }
    }
    $e.Handled = $true
    if ($Viewer.ScrollableHeight -le 0) { return }
    # Successive notches add up to the pending target, so fast spins don't stutter.
    $from = if ($script:SmoothTargets.ContainsKey($Viewer)) { $script:SmoothTargets[$Viewer] } else { $Viewer.VerticalOffset }
    $script:SmoothTargets[$Viewer] = [math]::Max(0, [math]::Min($Viewer.ScrollableHeight, $from - $e.Delta * 0.9))
    if (-not $script:SmoothTimer.IsEnabled) { $script:SmoothTimer.Start() }
}

function Step-SmoothScroll {
    foreach ($v in @($script:SmoothTargets.Keys)) {
        $target = [math]::Min($script:SmoothTargets[$v], $v.ScrollableHeight)
        $diff = $target - $v.VerticalOffset
        $next = if ([math]::Abs($diff) -lt 0.5) { $target } else { $v.VerticalOffset + $diff * 0.22 }   # ease-out
        $script:SmoothLastSet[$v] = $next
        $v.ScrollToVerticalOffset($next)
        if ($next -eq $target) { $script:SmoothTargets.Remove($v); $script:SmoothLastSet.Remove($v) }
    }
    if ($script:SmoothTargets.Count -eq 0) { $script:SmoothTimer.Stop() }
}

# Scroll edge effect: a short fade into the page colour where content continues, instead of a
# hard divider line.
function Update-ScrollEdges($Viewer, $Top, $Bottom) {
    $Top.Visibility    = if ($Viewer.VerticalOffset -gt 1) { 'Visible' } else { 'Collapsed' }
    $Bottom.Visibility = if ($Viewer.VerticalOffset -lt $Viewer.ScrollableHeight - 1) { 'Visible' } else { 'Collapsed' }
}

# Page navigation keeps a sense of place: the adapter page slides in from the right, home comes
# back from the left (320 ms, ease-out, no overshoot). The opacity animation is dropped when it
# ends (FillBehavior Stop) so text gets ClearType back. With Windows animation effects off
# (reduced motion) pages simply switch.
function Start-PageTransition($Page, [int]$Direction) {
    if (-not [System.Windows.SystemParameters]::ClientAreaAnimation) { return }
    $ease = New-Object System.Windows.Media.Animation.ExponentialEase
    $ease.EasingMode = 'EaseOut'; $ease.Exponent = 5
    $dur = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(320))
    $move = New-Object System.Windows.Media.TranslateTransform
    $Page.RenderTransform = $move
    $slide = New-Object System.Windows.Media.Animation.DoubleAnimation([double](40 * $Direction), [double]0, $dur)
    $slide.EasingFunction = $ease
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation([double]0, [double]1, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(220))))
    $fade.FillBehavior = 'Stop'
    $move.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $slide)
    $Page.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
}

function Invoke-ButtonClick($b) {
    $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}

# ---- inventory -> screen ---------------------------------------------
function Get-SelectedAdapter {
    if (-not $script:SelectedIdx) { return $null }
    return ($script:Adapters | Where-Object { $_.InterfaceIndex -eq $script:SelectedIdx } | Select-Object -First 1)
}

function Set-ScanState([string]$Text, [switch]$Busy) {
    $ctl.txtScanState.Text = $Text
    $ctl.txtScanGlyph.Foreground = $script:Converter.ConvertFromString($(if ($Busy) { '#0071E3' } else { '#8E8E93' }))
}

function Start-InventoryRefresh([switch]$Quiet) {
    if ($script:ScanRunning -or -not $script:ScanPool) { return }
    $script:ScanRunning = $true
    Set-ScanState 'Refreshing...' -Busy
    if ($script:SelectedIdx) { Start-IcsRefresh }
    Start-WorkJob -Pool $script:ScanPool -Context @{ Quiet = [bool]$Quiet } `
        -Script '[PSCustomObject]@{ Adapters = @(Get-AdapterInventory); Vlan = (Get-VlanInventory) }' `
        -OnDone {
            param($r, $err, $ctx)
            $script:ScanRunning = $false
            if ($err -or -not $r) {
                Set-ScanState 'Refresh failed'
                Set-Status "Couldn't read the adapters: $err" 'err'
                return
            }
            Update-Inventory $r.Adapters $r.Vlan
            Set-ScanState "Updated $(Get-Date -Format 'HH:mm')"
            Save-InventoryCache
            if (-not $ctx.Quiet) { Set-Status 'Adapter list refreshed.' }
            elseif ($ctl.txtStatusBar.Text -like 'Scanning adapters*' -or $ctl.txtStatusBar.Text -like 'Showing the last known*') {
                if ($script:LocationWarning) { Set-Status $script:LocationWarning 'warn' }
                else { Set-Status 'Ready - adapters are up to date.' }
            }
        }
}

# Takes a fresh adapter list (+ optional VLAN scan results), merges in VLAN info, and redraws
# whatever is on screen. The config form is only re-filled if the user hasn't started editing it.
function Update-Inventory($Adapters, $Vlan) {
    if ($Vlan) { foreach ($k in @($Vlan.Keys)) { $script:VlanCache[$k] = $Vlan[$k] } }
    $script:Adapters = @($Adapters | Where-Object { $_ })
    foreach ($a in $script:Adapters) {
        $c = $script:VlanCache[$a.Name]
        if ($c) { $a.VlanSupported = $c.Supported; $a.VlanKeyword = $c.Keyword; $a.VlanId = $c.Value }
    }
    Render-Home
    if ($script:SelectedIdx) {
        $a = Get-SelectedAdapter
        if (-not $a) { Show-Home -Force; Set-Status 'That adapter is no longer present.' 'warn'; return }
        Update-AdapterHeader $a
        if (-not $script:FormDirty) { Show-Adapter $a } else { Update-VlanFields $a -KeepText }
        if ($ctl.pnlIcsSetup.Visibility -eq 'Visible') { Initialize-IcsChoices $a }
        Update-IcsCard
    }
}

function Render-Home {
    $showAll  = $ctl.chkShowAll.IsChecked -eq $true
    $order    = @{ e = { $_.Status -ne 'Up' } }, 'Name'
    $wired    = @($script:Adapters | Where-Object { $_.Kind -eq 'Ethernet' } | Sort-Object $order)
    $wireless = @($script:Adapters | Where-Object { $_.Kind -in 'WiFi', 'Cellular' } | Sort-Object $order)
    $virtual  = @($script:Adapters | Where-Object { $_.Kind -in 'Virtual', 'Bluetooth' } | Sort-Object $order)
    $ctl.icWired.ItemsSource    = $wired
    $ctl.icWireless.ItemsSource = $wireless
    $ctl.icVirtual.ItemsSource  = $virtual
    $ctl.txtNoWired.Visibility    = if ($wired.Count) { 'Collapsed' } else { 'Visible' }
    $ctl.txtNoWireless.Visibility = if ($wireless.Count) { 'Collapsed' } else { 'Visible' }
    $ctl.pnlVirtual.Visibility    = if ($showAll -and $virtual.Count) { 'Visible' } else { 'Collapsed' }

    $ctl.txtHostName.Text = $env:COMPUTERNAME
    $online = Get-InternetAdapter
    if (@($script:Adapters | Where-Object { $_.Cached }).Count) {
        $ctl.txtScreenGlyph.Text = [string][char]0xE895
        $ctl.txtOnline.Text      = 'Checking connections...'
    } elseif ($online) {
        $ctl.txtScreenGlyph.Text = $online.Glyph
        $ctl.txtOnline.Text      = "Online via $($online.Name)  $script:Dot  $($online.IPv4)"
    } elseif (@($script:Adapters | Where-Object { $_.Status -eq 'Up' }).Count) {
        $ctl.txtScreenGlyph.Text = [string][char]0xE7BA
        $ctl.txtOnline.Text      = 'Connected - no default gateway'
    } else {
        $ctl.txtScreenGlyph.Text = [string][char]0xE7BA
        $ctl.txtOnline.Text      = 'No active connection'
    }

    # The home ping box follows the default gateway until the user types something else.
    $gw = if ($online) { "$($online.Gateway)" } else { '' }
    $cur = $ctl.txtPingHome.Text.Trim()
    if ($cur -eq '' -or $cur -eq $script:PingHomeAuto) {
        $script:PingHomeAuto = $gw
        $ctl.txtPingHome.Text = $gw
    }
    Update-PingHomeHint
}

function Update-PingHomeHint {
    $cur = $ctl.txtPingHome.Text.Trim()
    $ctl.txtPingHomeHint.Text = if (-not $cur -and @($script:Adapters | Where-Object { $_.Cached }).Count) { 'finding your gateway...' }
                                elseif ($cur -and $cur -eq $script:PingHomeAuto) { 'your default gateway' }
                                elseif ($cur) { 'custom target' }
                                else { 'no default gateway - type a target' }
}

function Get-InternetAdapter {
    $script:Adapters | Where-Object { $null -ne $_.DefaultRouteMetric } | Sort-Object DefaultRouteMetric | Select-Object -First 1
}

function Show-Home([switch]$Force) {
    if (-not $Force -and $script:FormDirty -and -not (Confirm-Action 'Discard the changes you made in the form?')) { return }
    $script:SelectedIdx = 0
    $script:FormDirty = $false
    $wasPage = $ctl.pnlConfig.Visibility -eq 'Visible'
    $ctl.pnlConfig.Visibility = 'Collapsed'
    $ctl.pnlHome.Visibility   = 'Visible'
    if ($wasPage) { Start-PageTransition $ctl.pnlHome -1 }
}

function Open-AdapterPage($a) {
    if (-not $a) { return }
    $script:SelectedIdx = [int]$a.InterfaceIndex
    $ctl.txtDeviceIp.Text   = ''
    $ctl.pnlSaveProfile.Visibility = 'Collapsed'
    $script:PingTargetAuto  = "$($a.Gateway)"
    $ctl.txtPingTarget.Text = $script:PingTargetAuto
    Set-PingResult 'Sends 4 pings and shows the response time. Pre-filled with the gateway - type any target.' 'info'
    Update-AdapterHeader $a
    $script:IcsEdited = $false
    Initialize-IcsChoices $a
    Update-IcsCard
    Start-IcsRefresh
    Show-Adapter $a
    $wasHome = $ctl.pnlHome.Visibility -eq 'Visible'
    $ctl.pnlHome.Visibility   = 'Collapsed'
    $ctl.pnlConfig.Visibility = 'Visible'
    $ctl.svForm.ScrollToTop()
    if ($wasHome) { Start-PageTransition $ctl.pnlConfig 1 }
}

function Update-AdapterHeader($a) {
    $ctl.txtAdapterName.Text        = $a.Name
    $ctl.txtAdapterGlyph.Text       = $a.Glyph
    $ctl.bdAdapterIcon.Background   = $script:Converter.ConvertFromString($a.IconBg)
    $ctl.txtAdapterGlyph.Foreground = $script:Converter.ConvertFromString($a.IconFg)
    $ctl.elStatusDot.Fill           = $script:Converter.ConvertFromString($a.StatusBrush)
    $ctl.txtStatusPill.Text         = $a.StatusText
    $ctl.bdStatusPill.Background    = $script:Converter.ConvertFromString($(if ($a.Status -eq 'Up') { '#E3F5E8' } else { '#EFEFF4' }))
    $mode = if ($a.Dhcp) { 'automatic address (DHCP)' } else { 'manual address' }
    $ip   = if ($a.IPv4) { "$($a.IPv4)/$($a.PrefixLength)" } else { 'no IPv4 address' }
    $ctl.txtDetail.Text = "$($a.Type)  $script:Dot  $mode  $script:Dot  $ip"

    $ctl.txtInfoHw.Text    = $a.InterfaceDescription
    $ctl.txtInfoMac.Text   = $a.MacAddress
    $ctl.txtInfoSpeed.Text = if ($a.LinkSpeed -and $a.Status -eq 'Up') { $a.LinkSpeed } else { '-' }
    $ctl.txtInfoType.Text  = $a.Type
    $ctl.txtInfoIndex.Text = "$($a.InterfaceIndex)"

    if ($a.Status -eq 'Disabled') {
        $ctl.txtToggleEnable.Text = 'Enable'
        $ctl.txtToggleGlyph.Foreground = $script:Converter.ConvertFromString('#248A3D')
        $ctl.btnToggleEnable.ToolTip = 'Turn the adapter back on'
    } else {
        $ctl.txtToggleEnable.Text = 'Disable'
        $ctl.txtToggleGlyph.Foreground = $script:Converter.ConvertFromString('#FF3B30')
        $ctl.btnToggleEnable.ToolTip = 'Turn the adapter off (asks first)'
    }
    $ctl.btnRenew.IsEnabled = $a.Dhcp -and $a.Status -eq 'Up'
}

function Set-PingResult([string]$Text, [string]$Type = 'info') {
    $style = switch ($Type) {
        'ok'   { @('#E3F5E8', '#248A3D', 0xE930) }
        'warn' { @('#FFF4E0', '#B25000', 0xE7BA) }
        'err'  { @('#FDECEB', '#D70015', 0xEA39) }
        'busy' { @('#EAF2FD', '#0071E3', 0xE895) }
        default { @('Transparent', '#8E8E93', 0xE946) }
    }
    $ctl.bdPingResult.Background = $script:Converter.ConvertFromString($style[0])
    $ctl.txtPingGlyph.Foreground = $script:Converter.ConvertFromString($style[1])
    $ctl.txtPingGlyph.Text       = [string][char]$style[2]
    $ctl.txtPingResult.Text      = $Text
}

function Update-VlanFields($a, [switch]$KeepText) {
    $script:Populating = $true
    try {
        if ($null -eq $a.VlanSupported) {
            $ctl.txtVlan.IsEnabled = $false
            $ctl.txtVlan.Text      = ''
            $ctl.lblVlanNote.Text  = 'Checking VLAN support for this adapter...'
        } elseif ($a.VlanSupported) {
            $wasEnabled = $ctl.txtVlan.IsEnabled
            $ctl.txtVlan.IsEnabled = $true
            if (-not $KeepText -or -not $wasEnabled) { $ctl.txtVlan.Text = "$($a.VlanId)" }
            $ctl.lblVlanNote.Text  = "This adapter supports 802.1Q tagging (driver setting '$($a.VlanKeyword)'). Changing it briefly resets the link."
        } else {
            $ctl.txtVlan.IsEnabled = $false
            $ctl.txtVlan.Text      = ''
            $ctl.lblVlanNote.Text  = "This adapter's driver has no VLAN ID setting. For tagged VLANs use a Hyper-V external switch, the vendor utility (e.g. Intel PROSet), or a switch access port."
        }
    } finally { $script:Populating = $false }
}

function Update-ModeUI {
    $dhcp = $ctl.rbDhcp.IsChecked -eq $true
    $ctl.pnlManual.Visibility   = if ($dhcp) { 'Collapsed' } else { 'Visible' }
    $ctl.pnlDhcpInfo.Visibility = if ($dhcp) { 'Visible' } else { 'Collapsed' }
    $ctl.txtExtraIPs.IsEnabled  = -not $dhcp
    $a = Get-SelectedAdapter
    if ($dhcp -and $a) {
        $ctl.txtDhcpInfo.Text = if ($a.Status -eq 'Disabled') {
            'The adapter is disabled. Enable it first; then it gets its address automatically from the router / modem.'
        } elseif ($a.Status -ne 'Up') {
            "No link right now ($($a.StatusText.ToLower())). As soon as it's connected, the router / modem hands out the address automatically."
        } elseif ($a.Dhcp -and $a.IPv4) {
            'Settings received automatically from the router / modem:'
        } elseif ($a.Dhcp) {
            'No address received yet. Is the cable plugged into a router or modem that hands out addresses?'
        } elseif ($a.IPv4) {
            'Click Apply changes to switch to automatic. Until then the adapter keeps its manual settings:'
        } else {
            'The adapter will ask the router / modem for an address automatically. Click Apply changes to switch.'
        }
        # The current values as a readable list (one per line) whenever there is an address to show.
        $show = $a.IPv4 -and $a.Status -eq 'Up'
        $ctl.grdCurrent.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
        if ($show) {
            $ctl.txtCurIp.Text   = "$($a.IPv4)"
            $ctl.txtCurMask.Text = "$(Get-MaskFromPrefix ([int]$a.PrefixLength))   (/$($a.PrefixLength))"
            $ctl.txtCurGw.Text   = if ($a.Gateway) { "$($a.Gateway)" } else { 'none' }
            $ctl.txtCurDns.Text  = if (@($a.Dns).Count) { @($a.Dns) -join "`n" } else { 'none' }
        }
    }
}

function Get-FormInput {
    @{
        Mode = $(if ($ctl.rbDhcp.IsChecked -eq $true) { 'DHCP' } else { 'Static' })
        Ip = "$($ctl.txtIP.Text)"; Mask = "$($ctl.cmbMask.Text)"; Gateway = "$($ctl.txtGw.Text)"
        Dns1 = "$($ctl.cmbDns1.Text)"; Dns2 = "$($ctl.cmbDns2.Text)"; Mtu = "$($ctl.cmbMtu.Text)"
        ExtraIPs = "$($ctl.txtExtraIPs.Text)"
    }
}

# Compact fingerprint of the form, compared against the one taken when the form was filled. This
# (rather than a "something was typed" flag) means undoing an edit by hand clears "Not applied yet".
function Get-FormSignature {
    $in = Get-FormInput
    (@($in.Mode, $in.Ip, $in.Mask, $in.Gateway, $in.Dns1, $in.Dns2, $in.Mtu, ($in.ExtraIPs -replace '\s+', ' ')) |
        ForEach-Object { "$_".Trim() }) -join '|'
}

function Show-Adapter($a) {
    if (-not $a) { return }
    $script:Populating = $true
    try {
        if ($a.Dhcp) { $ctl.rbDhcp.IsChecked = $true } else { $ctl.rbStatic.IsChecked = $true }
        $ctl.txtIP.Text   = $a.IPv4
        $ctl.cmbMask.Text = if ($null -ne $a.PrefixLength -and "$($a.PrefixLength)" -ne '') { "/$($a.PrefixLength)" } else { '' }
        $ctl.txtGw.Text   = $a.Gateway
        $dns = @($a.Dns)
        $ctl.cmbDns1.Text = if ($dns.Count -ge 1) { $dns[0] } else { '' }
        $ctl.cmbDns2.Text = if ($dns.Count -ge 2) { $dns[1] } else { '' }
        $ctl.cmbMtu.Text  = if ($a.Mtu) { "$($a.Mtu)" } else { '' }
        $primaryCidr = "$($a.IPv4)/$($a.PrefixLength)"
        $ctl.txtExtraIPs.Text = (@($a.AllIPv4) | Where-Object { $_ -ne $primaryCidr }) -join "`r`n"
        Update-ModeUI
    } finally { $script:Populating = $false }
    Update-VlanFields $a
    $script:FormBaseline = Get-FormSignature
    $script:BaselineMask = $ctl.cmbMask.Text.Trim()
    $script:FormDirty = $false
    Update-FormFeedback
}

# Live feedback while typing: subnet details under the fields, the first validation problem in a
# red box, and Apply only enabled when the form is valid.
function Update-FormFeedback {
    $in = Get-FormInput
    $info = 'Type an IP address and pick a subnet mask to see the network details.'
    if ((Test-IPv4 $in.Ip) -and $in.Mask.Trim()) {
        try {
            $p = Resolve-Prefix $in.Mask
            if ($p -ge 1) {
                $s = Get-SubnetSummary (ConvertTo-NormalizedIPv4 $in.Ip) $p
                $info = "Network $($s.Network)/$($s.Prefix)  $script:Dot  mask $($s.Mask)  $script:Dot  usable $($s.FirstHost) - $($s.LastHost)  ($($s.Hosts) hosts)"
            }
        } catch { }
    }
    $ctl.txtSubnetInfo.Text = $info

    $problem = $null
    try {
        [void](Test-ConfigInput @in)
        if ($ctl.txtVlan.IsEnabled) { [void](Resolve-VlanId $ctl.txtVlan.Text) }
    } catch { $problem = $_.Exception.Message }
    $ctl.txtFormError.Text      = "$problem"
    $ctl.bdFormError.Visibility = if ($problem -and $script:FormDirty) { 'Visible' } else { 'Collapsed' }
    $ctl.btnApply.IsEnabled     = -not $problem
    $ctl.btnApply.ToolTip       = if ($problem) { $problem } else { 'Validate and apply these settings' }
    $ctl.txtDirty.Visibility    = if ($script:FormDirty) { 'Visible' } else { 'Collapsed' }
}

function On-FormEdited {
    if ($script:Populating) { return }
    $a = Get-SelectedAdapter
    $vlanChanged = $a -and $ctl.txtVlan.IsEnabled -and $ctl.txtVlan.Text.Trim() -ne "$($a.VlanId)"
    $script:FormDirty = ((Get-FormSignature) -ne $script:FormBaseline) -or [bool]$vlanChanged
    Update-FormFeedback
}

function Update-UndoButton {
    $s = $script:UndoSnapshot
    $ctl.btnUndo.IsEnabled = [bool]$s
    $ctl.btnUndo.ToolTip   = if ($s) { "Restore $($s.Name) to: $(Format-AdapterConfig $s)" }
                             else { 'Restores the adapter configuration from before the last change' }
}

function Render-Profiles {
    $items = @($script:Profiles | Sort-Object Name | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name; Summary = (Format-ProfileSummary $_); Profile = $_
            Glyph = [string][char]$(if ($_.Mode -eq 'DHCP') { 0xE701 } else { 0xE839 })
        }
    })
    $ctl.icProfiles.ItemsSource   = $items
    $ctl.txtNoProfiles.Visibility = if ($items.Count) { 'Collapsed' } else { 'Visible' }
}

function Apply-ProfileToForm($p) {
    if (-not $p) { return }
    $script:Populating = $true
    try {
        if ($p.Mode -eq 'DHCP') { $ctl.rbDhcp.IsChecked = $true } else { $ctl.rbStatic.IsChecked = $true }
        $ctl.txtIP.Text   = [string]$p.IP
        $ctl.cmbMask.Text = if ($null -ne $p.Prefix -and "$($p.Prefix)" -ne '') { "/$($p.Prefix)" } else { '' }
        $ctl.txtGw.Text   = [string]$p.Gateway
        $ctl.cmbDns1.Text = [string]$p.Dns1
        $ctl.cmbDns2.Text = [string]$p.Dns2
        $ctl.cmbMtu.Text  = [string]$p.Mtu
        $ctl.txtExtraIPs.Text = ''
        if ($ctl.txtVlan.IsEnabled) { $ctl.txtVlan.Text = [string]$p.Vlan }
        Update-ModeUI
    } finally { $script:Populating = $false }
    On-FormEdited
    $vlanNote = if ("$($p.Vlan)" -and -not $ctl.txtVlan.IsEnabled) { " (its VLAN $($p.Vlan) can't be used on this adapter)" } else { '' }
    Set-Status "Loaded profile '$($p.Name)'$vlanNote - review, then click Apply changes."
}

# Runs an IP change (Static / Dhcp / Restore) through Invoke-ConfigTransaction in the work runspace,
# then does the bookkeeping on the UI thread: change log, status, undo point, redraw.
function Start-ConfigChange {
    param($Adapter, [string]$Action, $Cfg, $Snapshot, $VlanTarget, [string]$Description, [string]$Verb = 'APPLY')
    # Only the interface index identifies the adapter; the worker resolves name/VLAN keyword live.
    $params = @{
        Idx = [int]$Adapter.InterfaceIndex; Action = $Action; Cfg = $Cfg
        Snapshot = $Snapshot; VlanTarget = $VlanTarget
    }
    $busy = if ($Verb -eq 'UNDO') { "Restoring $($Adapter.Name)..." } else { "Applying to $($Adapter.Name): $Description ..." }
    Start-WorkJob -Pool $script:WorkPool -Params @{ p = $params } -Script 'param($p) Invoke-ConfigTransaction @p' `
        -BusyLabel $busy -Context @{ Adapter = $Adapter; Description = $Description; Verb = $Verb } -OnDone {
            param($r, $err, $ctx)
            $a = $ctx.Adapter
            if ($err -or -not $r) {
                Write-ChangeLog "FAILED  $($a.Name): $($ctx.Description) - $err"
                Set-Status "Error: $err" 'err'
                Start-InventoryRefresh -Quiet
                return
            }
            if (-not $r.Ok) {
                Write-ChangeLog "FAILED  $($a.Name): $($ctx.Description) - $($r.Error)"
                if ($r.RolledBack) {
                    Write-ChangeLog "ROLLBACK $($a.Name): restored $(Format-AdapterConfig $r.Before)"
                    Set-Status "Not applied: $($r.Error)  The previous settings were restored." 'err'
                } elseif ($r.Before) {
                    Write-ChangeLog "ROLLBACK FAILED $($a.Name): $($r.RollbackError)"
                    Set-Status "Error: $($r.Error)  Restoring the previous settings ALSO failed: $($r.RollbackError)" 'err'
                } else {
                    Set-Status "Error: $($r.Error)" 'err'
                }
            } else {
                Write-ChangeLog "$($ctx.Verb.PadRight(7)) $($a.Name): $($ctx.Description) (was: $(Format-AdapterConfig $r.Before))"
                foreach ($l in @($r.Log)) { Write-ChangeLog $l }
                if ($null -ne $r.VlanApplied) {
                    # Keep the cache in sync immediately - otherwise the next refresh would show the
                    # stale pre-change value until a fresh VLAN scan picks it up.
                    $script:VlanCache[$a.Name] = [PSCustomObject]@{ Supported = $true; Keyword = $r.VlanKeyword; Value = "$($r.VlanApplied)" }
                }
                if ($ctx.Verb -eq 'UNDO') {
                    $script:UndoSnapshot = $null
                } else {
                    $before = $r.Before
                    $before.VlanSupported = $a.VlanSupported; $before.VlanKeyword = $a.VlanKeyword; $before.VlanId = $a.VlanId
                    $script:UndoSnapshot = $before
                }
                $script:FormDirty = $false
                if (@($r.Warnings).Count) { Set-Status "Applied to $($a.Name), but: $(@($r.Warnings) -join '; ')" 'warn' }
                elseif ($ctx.Verb -eq 'UNDO') { Set-Status "Restored $($a.Name) to: $($ctx.Description)." 'ok' }
                else { Set-Status "Done - $($a.Name) is now $($ctx.Description)." 'ok' }
            }
            Update-UndoButton
            if ($r.After) { Update-Inventory $r.After $null; Save-InventoryCache }
            Start-IcsRefresh   # an undo may have stopped sharing; any change can affect the shared port
        }
}

function Start-AdapterAction([string]$Action, $Adapter, [string]$BusyLabel, [string]$OkMessage, [string]$LogVerb) {
    Start-WorkJob -Pool $script:WorkPool -Params @{ A = $Action; I = [int]$Adapter.InterfaceIndex } `
        -Script 'param($A, $I) Invoke-AdapterAction $A $I' -BusyLabel $BusyLabel `
        -Context @{ Adapter = $Adapter; Action = $Action; Ok = $OkMessage; Verb = $LogVerb } -OnDone {
            param($r, $err, $ctx)
            $a = $ctx.Adapter
            if ($err) {
                if ($ctx.Action -eq 'Renew') { Set-Status "DHCP renew failed on $($a.Name): $err" 'err' }
                else { Set-Status "Error: $err" 'err' }
                Start-InventoryRefresh -Quiet
                return
            }
            if ($ctx.Verb) { Write-ChangeLog "$($ctx.Verb.PadRight(7)) $($a.Name)" }
            if ($r -and $r.After) { Update-Inventory $r.After $null; Save-InventoryCache }
            if ($ctx.Action -eq 'Renew') {
                $now = $script:Adapters | Where-Object { $_.InterfaceIndex -eq $a.InterfaceIndex } | Select-Object -First 1
                if (-not $now -or -not $now.IPv4) {
                    # APIPA (169.254.x.x) addresses are filtered out of the inventory, so "no IPv4" = no lease.
                    Set-Status "No DHCP server answered on $($a.Name) - nothing hands out addresses on that network." 'warn'
                } else {
                    Set-Status "New lease on $($a.Name): $($now.IPv4)/$($now.PrefixLength), gateway $($now.Gateway)." 'ok'
                }
            } else {
                Set-Status $ctx.Ok 'ok'
            }
        }
}

# -OnPage: also show the result in the adapter page's "Test connection" box.
function Start-Ping([string]$Target, [switch]$OnPage) {
    if (-not $Target) { Set-Status 'Nothing to ping - type an IP address or hostname.' 'err'; return }
    if ($OnPage) { Set-PingResult "Pinging $Target ..." 'busy' }
    Set-Status "Pinging $Target ..."
    Start-WorkJob -Pool $script:ScanPool -Params @{ T = $Target } -Script 'param($T) Invoke-PingTest $T' `
        -Context @{ Target = $Target; OnPage = [bool]$OnPage } -OnDone {
            param($r, $err, $ctx)
            $t = $ctx.Target
            if ($err) { $msg = "Ping $t failed: $err"; $type = 'err' }
            elseif ($r.Received -eq $r.Sent) { $msg = "$t answers: $($r.Received)/$($r.Sent) replies, average $($r.Avg) ms (min $($r.Min) / max $($r.Max))."; $type = 'ok' }
            elseif ($r.Received -gt 0) { $msg = "$t answers with packet loss: $($r.Received)/$($r.Sent) replies, average $($r.Avg) ms."; $type = 'warn' }
            else { $msg = "$t does not answer ($($r.LastFailure))."; $type = 'err' }
            if ($ctx.OnPage) { Set-PingResult $msg $type }
            Set-Status $msg $type
        }
}

# ---- internet sharing card ---------------------------------------------
# The shared port's /24 must not overlap a network the PC is already on (e.g. the Wi-Fi it shares),
# or traffic would go to the wrong place. Returns the clashing adapter, or $null.
function Get-IcsConflict([string]$Address, $Adapters, [int]$PrivateIdx) {
    foreach ($a in @($Adapters)) {
        if (-not $a -or $a.InterfaceIndex -eq $PrivateIdx -or -not $a.IPv4 -or $null -eq $a.PrefixLength -or "$($a.PrefixLength)" -eq '') { continue }
        $p = [math]::Min(24, [int]$a.PrefixLength)
        if ($p -ge 1 -and (Test-SameSubnet $Address $a.IPv4 $p)) { return $a }
    }
    return $null
}

function Get-AdapterByIdx([int]$Idx) {
    if (-not $Idx) { return $null }
    $script:Adapters | Where-Object { $_.InterfaceIndex -eq $Idx } | Select-Object -First 1
}

function Start-IcsRefresh {
    if ($script:IcsRefreshing -or -not $script:WorkPool) { return }
    $script:IcsRefreshing = $true
    Start-WorkJob -Pool $script:WorkPool -Script 'Get-IcsState' -OnDone {
        param($r, $err)
        $script:IcsRefreshing = $false
        $script:IcsState = if ($r) { $r } else { [PSCustomObject]@{ Available = $false; Error = "$err"; PublicIdx = 0; PrivateIdx = 0; ScopeAddress = '192.168.137.1'; Persist = $false; Clients = @() } }
        Update-IcsCard
    }
}

# Fills the two adapter pickers. Keeps the user's choice; otherwise defaults from the page's adapter:
# an Ethernet port is the natural "share to", the adapter with internet the natural "from".
function Initialize-IcsChoices($Sel) {
    $script:Populating = $true
    try {
        $online = Get-InternetAdapter
        $from = @($script:Adapters | Where-Object { $_.Kind -in 'WiFi', 'Ethernet', 'Cellular', 'Virtual' -and $_.Status -eq 'Up' } | Sort-Object Name)
        $to   = @($script:Adapters | Where-Object { $_.Kind -eq 'Ethernet' } | Sort-Object Name)
        $prevFrom = if ($ctl.cmbIcsFrom.SelectedItem) { [int]$ctl.cmbIcsFrom.SelectedItem.Tag } else { 0 }
        $prevTo   = if ($ctl.cmbIcsTo.SelectedItem)   { [int]$ctl.cmbIcsTo.SelectedItem.Tag }   else { 0 }

        $toIdx = if ($prevTo -and ($to | Where-Object { $_.InterfaceIndex -eq $prevTo })) { $prevTo }
                 elseif ($Sel -and $Sel.Kind -eq 'Ethernet' -and (-not $online -or $Sel.InterfaceIndex -ne $online.InterfaceIndex)) { $Sel.InterfaceIndex }
                 else { [int]($to | Where-Object { -not $online -or $_.InterfaceIndex -ne $online.InterfaceIndex } | Select-Object -First 1).InterfaceIndex }
        $fromIdx = if ($prevFrom -and ($from | Where-Object { $_.InterfaceIndex -eq $prevFrom })) { $prevFrom }
                   elseif ($Sel -and $null -ne $Sel.DefaultRouteMetric -and $Sel.InterfaceIndex -ne $toIdx) { $Sel.InterfaceIndex }
                   elseif ($online -and $online.InterfaceIndex -ne $toIdx) { $online.InterfaceIndex }
                   else { [int]($from | Where-Object { $_.InterfaceIndex -ne $toIdx } | Select-Object -First 1).InterfaceIndex }

        foreach ($pair in @(@($ctl.cmbIcsFrom, $from, $fromIdx), @($ctl.cmbIcsTo, $to, $toIdx))) {
            $combo = $pair[0]
            $combo.Items.Clear()
            foreach ($a in $pair[1]) {
                $it = New-Object System.Windows.Controls.ComboBoxItem
                $extra = if ($null -ne $a.DefaultRouteMetric) { 'has internet' } else { $a.StatusText.ToLower() }
                $it.Content = "$($a.Name)   $script:Dot $extra"
                $it.Tag = [int]$a.InterfaceIndex
                [System.Windows.Controls.TextSearch]::SetText($it, $a.Name)
                [void]$combo.Items.Add($it)
                if ($a.InterfaceIndex -eq $pair[2]) { $combo.SelectedItem = $it }
            }
        }
    } finally { $script:Populating = $false }
}

function Get-IcsPrivateIdx {
    $s = $script:IcsState
    if ($s -and $s.PrivateIdx) { return [int]$s.PrivateIdx }
    if ($ctl.cmbIcsTo.SelectedItem) { return [int]$ctl.cmbIcsTo.SelectedItem.Tag }
    return 0
}

# Validates the address field and explains what Windows will hand out. Returns the address or $null.
function Update-IcsDhcpInfo {
    $problem = $null; $addr = $null
    try {
        $addr = Assert-IcsScopeAddress $ctl.cmbIcsScope.Text.Trim()
        $clash = Get-IcsConflict $addr $script:Adapters (Get-IcsPrivateIdx)
        if ($clash) { $problem = "That network clashes with $($clash.Name) ($($clash.IPv4)/$($clash.PrefixLength)). Pick another address, e.g. 192.168.137.1."; $addr = $null }
    } catch { $problem = $_.Exception.Message }
    if ($addr) {
        $s = Get-SubnetSummary $addr 24
        $first = if ($s.FirstHost -eq $addr) { ConvertFrom-IPv4Int ((ConvertTo-IPv4Int $addr) + 1) } else { $s.FirstHost }
        $last  = if ($s.LastHost -eq $addr)  { ConvertFrom-IPv4Int ((ConvertTo-IPv4Int $addr) - 1) } else { $s.LastHost }
        $ctl.txtIcsDhcpInfo.Text = "Devices get $first - $last, mask 255.255.255.0, with $addr as gateway and DNS. Windows fixes the mask, range and DNS; only this address can be changed."
    } else {
        $ctl.txtIcsDhcpInfo.Text = 'Devices get the other addresses of this /24 network, with this PC as gateway and DNS.'
    }
    $ctl.txtIcsError.Text = "$problem"
    $ctl.bdIcsError.Visibility = if ($problem) { 'Visible' } else { 'Collapsed' }
    return $addr
}

function Update-IcsCard {
    $s = $script:IcsState
    $conv = $script:Converter
    if (-not $s) {
        $ctl.txtIcsPill.Text = 'Checking...'; $ctl.elIcsDot.Fill = $conv.ConvertFromString('#8E8E93')
        $ctl.btnIcsStart.IsEnabled = $false
        return
    }
    $active = $s.Available -and $s.PublicIdx -and $s.PrivateIdx
    $pub = Get-AdapterByIdx $s.PublicIdx; $priv = Get-AdapterByIdx $s.PrivateIdx

    $pill = if (-not $s.Available) { @('Unavailable', '#EFEFF4', '#8E8E93') } elseif ($active) { @('On', '#E3F5E8', '#34C759') } else { @('Off', '#EFEFF4', '#8E8E93') }
    $ctl.txtIcsPill.Text = $pill[0]
    $ctl.bdIcsPill.Background = $conv.ConvertFromString($pill[1])
    $ctl.elIcsDot.Fill = $conv.ConvertFromString($pill[2])

    $ctl.pnlIcsSetup.Visibility   = if ($active) { 'Collapsed' } else { 'Visible' }
    $ctl.pnlIcsActive.Visibility  = if ($active) { 'Visible' } else { 'Collapsed' }
    $ctl.pnlIcsClients.Visibility = if ($active) { 'Visible' } else { 'Collapsed' }
    $ctl.btnIcsStop.Visibility    = if ($active) { 'Visible' } else { 'Collapsed' }
    if ($active) {
        $ctl.txtIcsFromName.Text  = if ($pub)  { $pub.Name }  else { "interface $($s.PublicIdx)" }
        $ctl.txtIcsToName.Text    = if ($priv) { $priv.Name } else { "interface $($s.PrivateIdx)" }
        $ctl.txtIcsFromGlyph.Text = if ($pub)  { $pub.Glyph }  else { [string][char]0xE774 }
        $ctl.txtIcsToGlyph.Text   = if ($priv) { $priv.Glyph } else { [string][char]0xE839 }
        $ctl.txtIcsHint.Text = "Windows hands out addresses on $($ctl.txtIcsToName.Text) and sends those devices to the internet through $($ctl.txtIcsFromName.Text)."
        $ctl.icIcsClients.ItemsSource = @($s.Clients)
        $ctl.txtIcsNoClients.Visibility = if (@($s.Clients).Count) { 'Collapsed' } else { 'Visible' }
        $ctl.txtIcsStart.Text = 'Update sharing'; $ctl.txtIcsStartGlyph.Text = [string][char]0xE73E
    } elseif ($s.Available) {
        $ctl.txtIcsHint.Text = 'Give devices plugged into one adapter internet from another. Windows then hands out their addresses (DHCP).'
        $ctl.txtIcsStart.Text = 'Start sharing'; $ctl.txtIcsStartGlyph.Text = [string][char]0xE768
    } else {
        $ctl.txtIcsHint.Text = "Not available: $($s.Error)"
    }

    if (-not $script:IcsEdited) {
        $script:Populating = $true
        try { $ctl.cmbIcsScope.Text = $s.ScopeAddress; $ctl.chkIcsPersist.IsChecked = [bool]$s.Persist } finally { $script:Populating = $false }
    }
    $addr = Update-IcsDhcpInfo
    $changed = $addr -and ($addr -ne $s.ScopeAddress -or ($ctl.chkIcsPersist.IsChecked -eq $true) -ne [bool]$s.Persist)
    $ctl.btnIcsStart.IsEnabled = $s.Available -and [bool]$addr -and ($changed -or -not $active) -and
                                 ($active -or ($ctl.cmbIcsFrom.SelectedItem -and $ctl.cmbIcsTo.SelectedItem))
}

function Start-IcsChange([string]$Action, [int]$PublicIdx, [int]$PrivateIdx, [string]$Scope, [bool]$Persist, [string]$Description) {
    $p = @{ Action = $Action; PublicIdx = $PublicIdx; PrivateIdx = $PrivateIdx; ScopeAddress = $Scope; Persist = $Persist }
    Start-WorkJob -Pool $script:WorkPool -Params @{ p = $p } -Script 'param($p) Invoke-IcsChange @p' `
        -BusyLabel "Internet sharing: $Description..." -Context @{ Action = $Action; Description = $Description } -OnDone {
            param($r, $err, $ctx)
            if ($err -or -not $r) {
                Set-Status "Internet sharing: $err" 'err'
                Start-IcsRefresh
                return
            }
            $script:IcsState = $r.State
            $script:IcsEdited = $false
            if (-not $r.Ok) {
                Write-ChangeLog "FAILED  ICS $($ctx.Description) - $($r.Error)"
                Set-Status "Internet sharing not changed: $($r.Error)" 'err'
            } else {
                Write-ChangeLog "ICS     $($ctx.Description)"
                if ($ctx.Action -eq 'Start' -and $r.Before) {
                    # Undo = stop sharing and put the port back exactly as it was.
                    $before = $r.Before
                    $before | Add-Member -NotePropertyName UndoIcs -NotePropertyValue $true -Force
                    $script:UndoSnapshot = $before
                } elseif ($ctx.Action -eq 'Stop') {
                    $script:UndoSnapshot = $null
                }
                Update-UndoButton
                $msg = switch ($ctx.Action) {
                    'Start'  { "Sharing started: $($ctx.Description). Plug the device into the shared port and set it to automatic (DHCP)." }
                    'Update' { "Sharing updated: $($ctx.Description)." }
                    default  { 'Sharing stopped. The shared port is back on automatic (DHCP).' }
                }
                Set-Status $msg 'ok'
            }
            if ($r.After) { Update-Inventory $r.After $null; Save-InventoryCache }
            Update-IcsCard
        }
}

# Pick-or-type lists. Each entry shows a description in the dropdown but puts only the value
# into the box (TextSearch.Text), so what lands in the field always parses.
function Initialize-Pickers {
    $add = {
        param($combo, [string]$value, [string]$label)
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = $label
        [System.Windows.Controls.TextSearch]::SetText($it, $value)
        [void]$combo.Items.Add($it)
    }
    foreach ($p in @(8, 16, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32)) {
        $hosts = if ($p -eq 32) { 1 } elseif ($p -eq 31) { 2 } else { [math]::Pow(2, 32 - $p) - 2 }
        & $add $ctl.cmbMask "/$p" ('/{0,-3} {1,-16} {2:N0} hosts' -f $p, (Get-MaskFromPrefix $p), $hosts)
    }
    foreach ($combo in @($ctl.cmbDns1, $ctl.cmbDns2)) {
        & $add $combo '8.8.8.8' '8.8.8.8   Google'
        & $add $combo '8.8.4.4' '8.8.4.4   Google (2nd)'
        & $add $combo '1.1.1.1' '1.1.1.1   Cloudflare'
        & $add $combo '1.0.0.1' '1.0.0.1   Cloudflare (2nd)'
        & $add $combo '9.9.9.9' '9.9.9.9   Quad9'
    }
    & $add $ctl.cmbMtu '1500' '1500   Ethernet default'
    & $add $ctl.cmbMtu '1492' '1492   PPPoE'
    & $add $ctl.cmbMtu '1400' '1400   VPN / tunnels'
    & $add $ctl.cmbMtu '1280' '1280   minimum safe'
    & $add $ctl.cmbMtu '9000' '9000   jumbo frames'
    & $add $ctl.cmbIcsScope '192.168.137.1' '192.168.137.1   Windows default'
    & $add $ctl.cmbIcsScope '192.168.0.1'   '192.168.0.1'
    & $add $ctl.cmbIcsScope '192.168.1.1'   '192.168.1.1'
    & $add $ctl.cmbIcsScope '192.168.2.1'   '192.168.2.1'
    & $add $ctl.cmbIcsScope '10.0.0.1'      '10.0.0.1'
    & $add $ctl.cmbIcsScope '172.16.0.1'    '172.16.0.1'
}

# ---------------------------------------------------------------------
# 6. EVENT HANDLERS
# ---------------------------------------------------------------------
# Tiles: one handler per list; the clicked tile's adapter is its DataContext.
foreach ($ic in @($ctl.icWired, $ctl.icWireless, $ctl.icVirtual)) {
    $ic.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        $a = $e.OriginalSource.DataContext
        if ($a -and $a.InterfaceIndex) { Open-AdapterPage $a }
    })
}

$ctl.icProfiles.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    $item = $e.OriginalSource.DataContext
    if (-not $item) { return }
    if ($e.OriginalSource.CommandParameter -eq 'delete') {
        if (-not (Confirm-Action "Delete profile '$($item.Name)'?")) { return }
        try {
            $script:Profiles = @($script:Profiles | Where-Object { $_.Name -ne $item.Name })
            Save-Profiles $script:Profiles
            Render-Profiles
            Set-Status "Deleted profile '$($item.Name)'." 'ok'
        } catch { Set-Status "Error saving profiles: $($_.Exception.Message)" 'err' }
    } else {
        Apply-ProfileToForm $item.Profile
        $ctl.txtProfileName.Text = $item.Name
    }
})

$ctl.chkShowAll.Add_Click({ Render-Home })
$ctl.btnRefresh.Add_Click({ Start-InventoryRefresh })
$ctl.btnBack.Add_Click({ Show-Home })

$ctl.rbStatic.Add_Checked({
    Update-ModeUI; On-FormEdited
    # Switching to manual by hand: bring the whole form into view.
    if (-not $script:Populating) { $ctl.svForm.ScrollToTop() }
})
$ctl.rbDhcp.Add_Checked({ Update-ModeUI; On-FormEdited })
foreach ($tb in @($ctl.txtIP, $ctl.txtGw, $ctl.txtVlan, $ctl.txtExtraIPs)) { $tb.Add_TextChanged({ On-FormEdited }) }
foreach ($cb in @($ctl.cmbMask, $ctl.cmbDns1, $ctl.cmbDns2, $ctl.cmbMtu)) {
    $cb.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
        [System.Windows.Controls.TextChangedEventHandler]{ On-FormEdited })
}

$ctl.btnQuickFill.Add_Click({
    # /24 unless the user deliberately picked another mask: the mask still showing from the
    # adapter's current network says nothing about the device being connected.
    $prefix = 24
    if ($ctl.cmbMask.Text.Trim() -and $ctl.cmbMask.Text.Trim() -ne $script:BaselineMask) {
        try { $prefix = Resolve-Prefix $ctl.cmbMask.Text } catch { }
    }
    try {
        $q = Get-QuickConfigForDevice $ctl.txtDeviceIp.Text $prefix
        $script:Populating = $true
        try {
            $ctl.rbStatic.IsChecked = $true
            $ctl.txtIP.Text   = $q.Ip
            $ctl.cmbMask.Text = "/$($q.Prefix)"
            $ctl.txtGw.Text   = $q.Gateway
            Update-ModeUI
        } finally { $script:Populating = $false }
        On-FormEdited
        # The device is what you'll want to ping next - unless a custom target was typed.
        $curTarget = $ctl.txtPingTarget.Text.Trim()
        if (-not $curTarget -or $curTarget -eq $script:PingTargetAuto) {
            $script:PingTargetAuto = $q.Gateway
            $ctl.txtPingTarget.Text = $q.Gateway
        }
        Set-Status "Filled in: this laptop becomes $($q.Ip)/$($q.Prefix), with the device ($($q.Gateway)) as gateway. Adjust if needed, then Apply." 'ok'
    } catch { Set-Status $_.Exception.Message 'err' }
})
$ctl.txtDeviceIp.Add_KeyDown({ if ($_.Key -eq 'Return') { Invoke-ButtonClick $ctl.btnQuickFill } })

$ctl.btnSuggestGw.Add_Click({
    try {
        if (-not (Test-IPv4 $ctl.txtIP.Text)) { throw 'Type your IP address first.' }
        $p = Resolve-Prefix $ctl.cmbMask.Text
        if ($p -lt 1 -or $p -gt 30) { throw 'Pick a subnet mask between /1 and /30 first.' }
        $ip = ConvertTo-NormalizedIPv4 $ctl.txtIP.Text
        $s = Get-SubnetSummary $ip $p
        $ctl.txtGw.Text = if ($s.FirstHost -ne $ip) { $s.FirstHost } else { $s.LastHost }
    } catch { Set-Status $_.Exception.Message 'err' }
})

# ---- internet sharing ----
$ctl.cmbIcsScope.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
    [System.Windows.Controls.TextChangedEventHandler]{ if (-not $script:Populating) { $script:IcsEdited = $true; Update-IcsCard } })
$ctl.chkIcsPersist.Add_Click({ $script:IcsEdited = $true; Update-IcsCard })
foreach ($cb in @($ctl.cmbIcsFrom, $ctl.cmbIcsTo)) { $cb.Add_SelectionChanged({ if (-not $script:Populating) { Update-IcsCard } }) }
$ctl.btnIcsRefresh.Add_Click({ Start-IcsRefresh })

$ctl.btnIcsStart.Add_Click({
    $s = $script:IcsState
    if (-not $s -or -not $s.Available) { return }
    $addr = Update-IcsDhcpInfo
    if (-not $addr) { Set-Status "Internet sharing: $($ctl.txtIcsError.Text)" 'err'; return }
    $persist = $ctl.chkIcsPersist.IsChecked -eq $true
    $keep = if ($persist) { ', kept after restart' } else { '' }
    if ($s.PublicIdx -and $s.PrivateIdx) {
        $priv = Get-AdapterByIdx $s.PrivateIdx
        Start-IcsChange 'Update' 0 0 $addr $persist "address $addr on $($priv.Name)$keep"
        return
    }
    $fromIdx = [int]$ctl.cmbIcsFrom.SelectedItem.Tag; $toIdx = [int]$ctl.cmbIcsTo.SelectedItem.Tag
    if ($fromIdx -eq $toIdx) { Set-Status 'Internet sharing: pick two different adapters.' 'err'; return }
    $from = Get-AdapterByIdx $fromIdx; $to = Get-AdapterByIdx $toIdx
    $noNet = if ($null -eq $from.DefaultRouteMetric) { "`n`nNote: $($from.Name) has no internet connection right now." } else { '' }
    $text = "Share $($from.Name)'s internet with devices on $($to.Name)?`n`n$($to.Name) will get the address $addr and hand out addresses to devices plugged into it. Its current settings are replaced (Undo puts them back).$noNet"
    if (-not (Confirm-Action $text 'Start internet sharing')) { return }
    Start-IcsChange 'Start' $fromIdx $toIdx $addr $persist "$($from.Name) -> $($to.Name), address $addr$keep"
})

$ctl.btnIcsStop.Add_Click({
    $s = $script:IcsState
    $priv = Get-AdapterByIdx $s.PrivateIdx
    $name = if ($priv) { $priv.Name } else { 'the shared port' }
    if (-not (Confirm-Action "Stop internet sharing?`n`nDevices on $name lose internet, and $name goes back to automatic (DHCP)." 'Stop internet sharing')) { return }
    Start-IcsChange 'Stop' 0 0 '' $false "stop (was $($ctl.txtIcsFromName.Text) -> $($ctl.txtIcsToName.Text))"
})

$ctl.btnRevert.Add_Click({
    $a = Get-SelectedAdapter
    if ($a) { Show-Adapter $a; Set-Status "Form reset to the current settings of $($a.Name)." }
})

$ctl.btnApply.Add_Click({
    $a = Get-SelectedAdapter
    if (-not $a) { return }
    # Validate everything up front - nothing is changed unless every field is valid.
    try {
        $in  = Get-FormInput
        $cfg = Test-ConfigInput @in
        $vlanTarget = $null
        if ($a.VlanSupported -and $ctl.txtVlan.IsEnabled -and $ctl.txtVlan.Text.Trim() -ne "$($a.VlanId)") {
            $vi = Resolve-VlanId $ctl.txtVlan.Text
            $curV = 0; [void][int]::TryParse("$($a.VlanId)", [ref]$curV)
            if ($vi -ne $curV) { $vlanTarget = $vi }
        }
        if ($cfg.Mode -eq 'Static') {
            foreach ($ipToCheck in @($cfg.Ip) + @($cfg.Extra | ForEach-Object { $_.Ip })) {
                $clash = $script:Adapters | Where-Object {
                    $_.InterfaceIndex -ne $a.InterfaceIndex -and (@($_.AllIPv4) | ForEach-Object { $_.Split('/')[0] }) -contains $ipToCheck
                } | Select-Object -First 1
                if ($clash) { throw "$ipToCheck is already set on '$($clash.Name)'. Remove it there first." }
            }
        }
    } catch {
        $script:FormDirty = $true; Update-FormFeedback
        Set-Status "Not applied: $($_.Exception.Message)" 'err'
        return
    }
    $desc = Format-ConfigSummary $cfg
    if ($null -ne $vlanTarget) { $desc += " vlan $vlanTarget" }
    Start-ConfigChange -Adapter $a -Action $(if ($cfg.Mode -eq 'DHCP') { 'Dhcp' } else { 'Static' }) `
        -Cfg $cfg -VlanTarget $vlanTarget -Description $desc
})

$ctl.btnDhcp.Add_Click({
    $a = Get-SelectedAdapter
    if ($a) { Start-ConfigChange -Adapter $a -Action 'Dhcp' -Description 'DHCP' }
})

$ctl.btnUndo.Add_Click({
    $snap = $script:UndoSnapshot
    if (-not $snap) { return }
    $cur = $script:Adapters | Where-Object { $_.InterfaceIndex -eq $snap.InterfaceIndex } | Select-Object -First 1
    if (-not $cur) { Set-Status "Can't undo: adapter '$($snap.Name)' is no longer present." 'err'; return }
    $vlanTarget = $null
    if ($snap.VlanSupported -and $cur.VlanSupported -and "$($snap.VlanId)" -ne "$($cur.VlanId)") {
        $v = 0; [void][int]::TryParse("$($snap.VlanId)", [ref]$v); $vlanTarget = $v
    }
    Start-ConfigChange -Adapter $cur -Action 'Restore' -Snapshot $snap -VlanTarget $vlanTarget `
        -Description (Format-AdapterConfig $snap) -Verb 'UNDO'
})

$ctl.btnToggleEnable.Add_Click({
    $a = Get-SelectedAdapter
    if (-not $a) { return }
    if ($a.Status -eq 'Disabled') {
        Start-AdapterAction 'Enable' $a "Enabling $($a.Name)..." "$($a.Name) enabled." 'ENABLE'
    } else {
        if (-not (Confirm-Action "Disable '$($a.Name)'?`n`nAny connection over this adapter will drop until it is enabled again.")) { return }
        Start-AdapterAction 'Disable' $a "Disabling $($a.Name)..." "$($a.Name) disabled." 'DISABLE'
    }
})

$ctl.btnRestart.Add_Click({
    $a = Get-SelectedAdapter
    if ($a) { Start-AdapterAction 'Restart' $a "Restarting $($a.Name)..." "$($a.Name) restarted." 'RESTART' }
})

$ctl.btnRenew.Add_Click({
    $a = Get-SelectedAdapter
    if (-not $a) { return }
    if (-not $a.Dhcp) { Set-Status "$($a.Name) uses a static IP - switch it to DHCP first." 'err'; return }
    if ($a.Status -ne 'Up') { Set-Status "$($a.Name) has no link ($($a.StatusText)) - connect the cable first." 'err'; return }
    Start-AdapterAction 'Renew' $a "Renewing DHCP lease on $($a.Name) (can take up to a minute with no DHCP server)..." '' ''
})

$ctl.btnPing.Add_Click({
    $t = $ctl.txtPingTarget.Text.Trim()
    if (-not $t) { $t = $ctl.txtGw.Text.Trim() }
    if (-not $t) { $a = Get-SelectedAdapter; if ($a) { $t = $a.Gateway } }
    if (-not $t) { Set-PingResult 'Nothing to ping - type an IP address or hostname.' 'err'; return }
    Start-Ping $t -OnPage
})
$ctl.txtPingTarget.Add_KeyDown({ if ($_.Key -eq 'Return') { Invoke-ButtonClick $ctl.btnPing } })

$ctl.btnPingHome.Add_Click({
    $t = $ctl.txtPingHome.Text.Trim()
    if (-not $t) { $online = Get-InternetAdapter; if ($online) { $t = "$($online.Gateway)" } }
    Start-Ping $t
})
$ctl.txtPingHome.Add_KeyDown({ if ($_.Key -eq 'Return') { Invoke-ButtonClick $ctl.btnPingHome } })
$ctl.txtPingHome.Add_TextChanged({ Update-PingHomeHint })

$ctl.btnFlushDns.Add_Click({
    Start-WorkJob -Pool $script:ScanPool -Script "Invoke-AdapterAction 'FlushDns'" -OnDone {
        param($r, $err)
        if ($err) { Set-Status "Flush DNS failed: $err" 'err' } else { Set-Status 'DNS resolver cache flushed.' 'ok' }
    }
})

$ctl.btnClearArp.Add_Click({
    Start-WorkJob -Pool $script:ScanPool -Script "Invoke-AdapterAction 'ClearArp'" -OnDone {
        param($r, $err)
        if ($err) { Set-Status "Clearing the ARP cache failed: $err" 'err' } else { Set-Status 'ARP cache cleared.' 'ok' }
    }
})

$ctl.btnCopy.Add_Click({
    $s = Get-SelectedAdapter
    if (-not $s) { return }
    $mask = if ($null -ne $s.PrefixLength) { Get-MaskFromPrefix $s.PrefixLength } else { '' }
    $primaryCidr = "$($s.IPv4)/$($s.PrefixLength)"
    $extra = @($s.AllIPv4 | Where-Object { $_ -ne $primaryCidr })
    $summary = @"
Adapter : $($s.Name)
Desc    : $($s.InterfaceDescription)
Status  : $($s.StatusText)   ($($s.Type))
MAC     : $($s.MacAddress)
Mode    : $(if ($s.Dhcp) { 'DHCP' } else { 'Static' })
IPv4    : $($s.IPv4)/$($s.PrefixLength)   ($mask)
Extra   : $(if ($extra) { $extra -join ', ' } else { '-' })
Gateway : $($s.Gateway)
DNS     : $(@($s.Dns) -join ', ')
MTU     : $($s.Mtu)
VLAN    : $(if ($null -eq $s.VlanSupported) { 'checking...' } elseif ($s.VlanSupported) { $s.VlanId } else { 'n/a' })
Host    : $env:COMPUTERNAME   ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))
"@
    # Clipboard managers / remote-desktop clients often hold the clipboard for a few ms - retry briefly.
    for ($try = 1; $try -le 6; $try++) {
        try {
            [System.Windows.Clipboard]::SetText($summary)
            Set-Status 'Configuration copied to the clipboard.' 'ok'
            return
        } catch { Start-Sleep -Milliseconds 60 }
    }
    Set-Status "Couldn't access the clipboard (another app is holding it) - try again." 'err'
})

$ctl.btnOpenData.Add_Click({
    try {
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$script:DataDir`""
    } catch { Set-Status "Error: $($_.Exception.Message)" 'err' }
})

$ctl.btnSaveProfile.Add_Click({
    $name = $ctl.txtProfileName.Text.Trim()
    if (-not $name) { Set-Status 'Type a name for the profile first (in the box next to Save).' 'err'; [void]$ctl.txtProfileName.Focus(); return }
    $in = Get-FormInput
    try {
        # Same validation as Apply, so a saved profile is always one that can actually be applied.
        $cfg = Test-ConfigInput -Mode $in.Mode -Ip $in.Ip -Mask $in.Mask -Gateway $in.Gateway `
            -Dns1 $in.Dns1 -Dns2 $in.Dns2 -Mtu $in.Mtu -ExtraIPs ''
        $vlan = if ($ctl.txtVlan.Text.Trim()) { "$(Resolve-VlanId $ctl.txtVlan.Text)" } else { '' }
    } catch {
        Set-Status "Profile not saved: $($_.Exception.Message)" 'err'
        return
    }
    if (($script:Profiles | Where-Object { $_.Name -eq $name }) -and -not (Confirm-Action "A profile named '$name' already exists. Replace it?")) {
        Set-Status "Profile '$name' was not changed."
        return
    }
    $p = [PSCustomObject]@{
        Name = $name; Mode = $cfg.Mode
        IP = $cfg.Ip; Prefix = $cfg.Prefix; Gateway = $cfg.Gateway
        Dns1 = $(if (@($cfg.Dns).Count -ge 1) { $cfg.Dns[0] } else { '' })
        Dns2 = $(if (@($cfg.Dns).Count -ge 2) { $cfg.Dns[1] } else { '' })
        Mtu = $(if ($cfg.Mtu) { "$($cfg.Mtu)" } else { '' }); Vlan = $vlan
    }
    try {
        $script:Profiles = @(@($script:Profiles | Where-Object { $_.Name -ne $name }) + $p)
        Save-Profiles $script:Profiles
        Render-Profiles
        $ctl.pnlSaveProfile.Visibility = 'Collapsed'
        Set-Status "Saved profile '$name'." 'ok'
    } catch { Set-Status "Error saving profiles: $($_.Exception.Message)" 'err' }
})
$ctl.txtProfileName.Add_KeyDown({
    if ($_.Key -eq 'Return') { Invoke-ButtonClick $ctl.btnSaveProfile }
    elseif ($_.Key -eq 'Escape') { $_.Handled = $true; $ctl.pnlSaveProfile.Visibility = 'Collapsed' }
})
$ctl.btnShowSave.Add_Click({
    $ctl.pnlSaveProfile.Visibility = 'Visible'
    $ctl.txtProfileName.SelectAll()
    [void]$ctl.txtProfileName.Focus()
})
$ctl.btnCancelSave.Add_Click({ $ctl.pnlSaveProfile.Visibility = 'Collapsed' })

$ctl.btnImportProfiles.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title  = 'Import profiles'
    $dlg.Filter = 'Profile files (*.json)|*.json|All files (*.*)|*.*'
    if (-not $dlg.ShowDialog($window)) { return }
    try {
        $imported = @(Read-ProfileFile $dlg.FileName)
        if (-not $imported) { Set-Status "No valid profiles found in $(Split-Path $dlg.FileName -Leaf)." 'err'; return }
        $names    = @($imported | ForEach-Object { $_.Name })
        $replaced = @($script:Profiles | Where-Object { $names -contains $_.Name }).Count
        $script:Profiles = @(@($script:Profiles | Where-Object { $names -notcontains $_.Name }) + $imported)
        Save-Profiles $script:Profiles
        Render-Profiles
        Set-Status "Imported $($imported.Count) profile(s) from $(Split-Path $dlg.FileName -Leaf) ($replaced replaced)." 'ok'
    } catch {
        Set-Status "Import failed: $($_.Exception.Message)" 'err'
    }
})

$ctl.btnExportProfiles.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title    = 'Export profiles'
    $dlg.Filter   = 'Profile files (*.json)|*.json'
    $dlg.FileName = 'network-profiles.json'
    if (-not $dlg.ShowDialog($window)) { return }
    try {
        Write-JsonFileAtomic $dlg.FileName @($script:Profiles)
        Set-Status "Exported $(@($script:Profiles).Count) profile(s) to $($dlg.FileName)." 'ok'
    } catch {
        Set-Status "Export failed: $($_.Exception.Message)" 'err'
    }
})

$window.Add_PreviewKeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::F5) {
        $_.Handled = $true
        if (-not $script:Busy) { Start-InventoryRefresh }
    } elseif ($_.Key -eq [System.Windows.Input.Key]::Escape -and $script:SelectedIdx -and -not $script:Busy) {
        # Esc closes the innermost thing first: an open dropdown, then the profile-name box, then the page.
        $openDrop = @($ctl.cmbMask, $ctl.cmbDns1, $ctl.cmbDns2, $ctl.cmbMtu) | Where-Object { $_.IsDropDownOpen }
        if ($openDrop) { return }
        $_.Handled = $true
        if ($ctl.pnlSaveProfile.Visibility -eq 'Visible') { $ctl.pnlSaveProfile.Visibility = 'Collapsed' }
        else { Show-Home }
    }
})

# Last line of defence: anything that escapes a handler goes to the status bar instead of
# tearing down the whole app (and the elevated session with it).
$window.Dispatcher.Add_UnhandledException({
    $e = $_
    $e.Handled = $true
    try { Set-Status "Unexpected error: $($e.Exception.Message)" 'err' } catch { }
})

$window.Add_Closing({
    if (@($script:Jobs | Where-Object { $_.Foreground }).Count -and
        -not (Confirm-Action 'A change is still being applied. Close anyway?')) { $_.Cancel = $true }
})

# ---------------------------------------------------------------------
# 7. STARTUP
# ---------------------------------------------------------------------
# Order matters for perceived speed: draw from the cache first, show the window, and only then
# create the background runspaces and start the live scan.
Initialize-Pickers
Update-UndoButton
Enable-SmoothScroll $ctl.svForm
Enable-SmoothScroll $ctl.svSide
$ctl.svForm.Add_ScrollChanged({ Update-ScrollEdges $ctl.svForm $ctl.fdFormTop $ctl.fdFormBottom })
$ctl.svSide.Add_ScrollChanged({ Update-ScrollEdges $ctl.svSide $ctl.fdSideTop $ctl.fdSideBottom })

# "Display" text (set on the window) is the sharpest at 1:1, but turns blurry when scaled. The home
# stage shrinks on small windows, so it switches to "Ideal" text only while it is actually scaled.
$ctl.vbStage.Add_SizeChanged({
    $child = $ctl.vbStage.Child
    if (-not $child -or $child.ActualWidth -le 0) { return }
    $scaled = ($ctl.vbStage.ActualWidth / $child.ActualWidth) -lt 0.995
    $mode = if ($scaled) { [System.Windows.Media.TextFormattingMode]::Ideal } else { [System.Windows.Media.TextFormattingMode]::Display }
    [System.Windows.Media.TextOptions]::SetTextFormattingMode($child, $mode)
})

# Fit the window into the screen's work area (excludes the taskbar). Laptop screens at 125-175%
# scaling are often well under 760 px tall, which would otherwise cut the window off.
$wa = [System.Windows.SystemParameters]::WorkArea
$window.Width     = [math]::Min($window.Width,  $wa.Width  - 24)
$window.Height    = [math]::Min($window.Height, $wa.Height - 24)
$window.MinWidth  = [math]::Min($window.MinWidth,  $window.Width)
$window.MinHeight = [math]::Min($window.MinHeight, $window.Height)
$window.Left      = $wa.Left + ($wa.Width  - $window.Width)  / 2
$window.Top       = $wa.Top  + ($wa.Height - $window.Height) / 2

# This script runs as administrator. Started from a folder that a normal user can write to (the repo,
# Downloads, an old per-user install), anything running as that user could change it before the next
# elevated start. Install.cmd puts it in Program Files, which only administrators can modify.
$script:LocationWarning = $null
$protected = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' }
if (-not ($protected | Where-Object { $PSCommandPath -like "$_*" })) {
    $script:LocationWarning = "Running from $(Split-Path $PSCommandPath -Parent) - fine for testing, but for daily use run Install.cmd: it installs to Program Files, where other programs can't tamper with this elevated app."
}

$cache = Read-InventoryCache
if ($cache -and @($cache.Adapters).Count) {
    Update-Inventory $cache.Adapters $cache.Vlan
    Set-ScanState 'Checking adapters...' -Busy
    Set-Status 'Showing the last known state (greyed) - checking the adapters...'
} else {
    $ctl.txtHostName.Text = $env:COMPUTERNAME
    $ctl.txtScreenGlyph.Text = [string][char]0xE895
    $ctl.txtOnline.Text   = 'Scanning adapters...'
    $ctl.txtNoWired.Text  = 'Scanning...'
    $ctl.txtNoWireless.Text = 'Scanning...'
    Set-Status 'Scanning adapters (first start)...'
}

$script:PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PollTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:PollTimer.Add_Tick({ Complete-WorkJobs })
$script:PollTimer.Start()

$window.Add_Closed({
    $script:PollTimer.Stop()
    foreach ($p in @($script:ScanPool, $script:WorkPool)) { if ($p) { try { $p.Dispose() } catch { } } }
})

$window.Add_Loaded({
    $window.Dispatcher.BeginInvoke([Action]{
        $script:ScanPool = New-WorkerPool
        $script:WorkPool = New-WorkerPool
        Start-InventoryRefresh -Quiet
        # Pre-load the networking modules in the work runspace now, so the first Apply doesn't pay
        # the multi-second module import.
        Start-WorkJob -Pool $script:WorkPool -Script 'Import-Module NetTCPIP, DnsClient, NetAdapter -ErrorAction SilentlyContinue; 1'
        try {
            $script:Profiles = @(Load-Profiles)
        } catch {
            $script:Profiles = @(Get-DefaultProfiles)
            $script:ProfileLoadWarning = "Profiles couldn't be loaded or saved ($($_.Exception.Message)); using defaults for this session."
        }
        Render-Profiles
        $ctl.txtNoWired.Text    = 'No wired adapters found'
        $ctl.txtNoWireless.Text = 'No wireless adapters found'
        if ($script:ProfileLoadWarning) { Set-Status $script:ProfileLoadWarning 'warn' }
    }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
})

$window.ShowDialog() | Out-Null
