<#
 Installs Network Control Center:
   - copies the app to %ProgramFiles%\NetworkControlCenter (re-run to update)
   - creates a Start menu shortcut for all users (and optionally a public desktop one) that
       * starts the app elevated directly - one click, one UAC prompt, no extra relaunch
       * runs it through "conhost --headless", so no console window ever appears
       * carries the same AppUserModelID as the app window, so the pinned taskbar
         button and the running window are one and the same icon

 Why Program Files: the app always runs as administrator. Installed in a folder a normal user can
 write to, any program running as that user could replace the script and get it executed with admin
 rights at the next start. Program Files and the all-users Start menu can only be changed by
 administrators, so installing asks for UAC once.

 Also migrates older per-user installs (%LOCALAPPDATA%\Programs\NetworkControlCenter): they are
 removed, and an existing pinned taskbar icon is pointed at the new location.

 Windows does not let programs pin themselves to the taskbar. After installing, the app starts:
 right-click its taskbar icon -> "Pin to taskbar". Done once, it stays.

 Usage:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Shortcut.ps1 [-Desktop] [-NoLaunch]
         powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Shortcut.ps1 -Uninstall
#>
param([switch]$Desktop, [switch]$NoLaunch, [switch]$Uninstall, [string]$LogPath)

$ErrorActionPreference = 'Stop'
$appName    = 'Network Control Center'
$appId      = 'FieldTools.NetworkControlCenter'      # must match $script:AppId in NetworkControlCenter.ps1
$installDir = Join-Path $env:ProgramFiles 'NetworkControlCenter'
$startLnk   = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$appName.lnk"
$deskLnk    = Join-Path $env:PUBLIC "Desktop\$appName.lnk"
$psExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script     = Join-Path $installDir 'NetworkControlCenter.ps1'
$icon       = Join-Path $installDir 'NetworkControlCenter.ico'

# Older versions installed per user; these are cleaned up / migrated by the non-elevated part.
$legacyDir    = Join-Path $env:LOCALAPPDATA 'Programs\NetworkControlCenter'
$legacyLnks   = @((Join-Path ([Environment]::GetFolderPath('Programs')) "$appName.lnk"),
                  (Join-Path ([Environment]::GetFolderPath('Desktop')) "$appName.lnk"))
$pinnedLnk    = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\$appName.lnk"

function Say([string]$msg, [string]$color = 'Gray') {
    Write-Host $msg -ForegroundColor $color
    if ($LogPath) { Add-Content -Path $LogPath -Value $msg -Encoding UTF8 }
}

# --- shortcut property store (AppUserModelID) - needs a little COM interop ------------------
function Initialize-ShortcutInterop {
    if ('NccShortcut' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NccShortcut
{
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey { public Guid FormatId; public uint PropertyId; }

    [StructLayout(LayoutKind.Explicit)]
    private struct PropVariant
    {
        [FieldOffset(0)] public ushort VarType;
        [FieldOffset(8)] public IntPtr Pointer;
        [FieldOffset(16)] public IntPtr Padding;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHGetPropertyStoreFromParsingName(string path, IntPtr bindContext, int flags,
        ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

    [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant pv);

    private static readonly Guid StoreIid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    private static PropertyKey AppIdKey()
    {
        return new PropertyKey { FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), PropertyId = 5 };
    }

    public static void SetAppId(string path, string appId)
    {
        Guid iid = StoreIid; IPropertyStore store;
        SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 2 /* GPS_READWRITE */, ref iid, out store);
        PropertyKey key = AppIdKey();
        PropVariant value = new PropVariant { VarType = 31 /* VT_LPWSTR */, Pointer = Marshal.StringToCoTaskMemUni(appId) };
        try
        {
            Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value));
            Marshal.ThrowExceptionForHR(store.Commit());
        }
        finally { Marshal.FreeCoTaskMem(value.Pointer); Marshal.ReleaseComObject(store); }
    }

    public static string GetAppId(string path)
    {
        Guid iid = StoreIid; IPropertyStore store;
        SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 0 /* GPS_DEFAULT */, ref iid, out store);
        PropertyKey key = AppIdKey(); PropVariant value;
        try
        {
            Marshal.ThrowExceptionForHR(store.GetValue(ref key, out value));
            string s = value.VarType == 31 ? Marshal.PtrToStringUni(value.Pointer) : null;
            PropVariantClear(ref value);
            return s;
        }
        finally { Marshal.ReleaseComObject(store); }
    }
}
'@
}

# Writes (or rewrites) a shortcut that starts the installed app elevated and window-less.
function Set-NccShortcut([string]$Path) {
    Initialize-ShortcutInterop
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath       = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $lnk.Arguments        = "--headless `"$psExe`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$script`""
    $lnk.WorkingDirectory = $installDir
    $lnk.IconLocation     = "$icon,0"
    $lnk.Description      = 'Change IP, gateway, DNS, MTU and VLAN settings and apply network profiles'
    $lnk.Save()
    # The shell link object keeps the file open until released; antivirus/indexer may also hold it
    # for a moment right after creation - so release, then retry briefly.
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($lnk)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    for ($try = 1; ; $try++) {
        try { [NccShortcut]::SetAppId($Path, $appId); break }
        catch { if ($try -ge 20) { throw }; Start-Sleep -Milliseconds 150 }
    }
    # "Run as administrator": bit 0x20 of the byte at offset 0x15 (LinkFlags.RunAsUser) of the .lnk.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes($Path, $bytes)
    if ([NccShortcut]::GetAppId($Path) -ne $appId) { throw "Could not set the taskbar identity on $Path." }
}

# Per-user part, always run as the user who installs.
function Update-UserProfile {
    # Old per-user install: remove it so nothing runs elevated from a user-writable folder any more.
    foreach ($l in $legacyLnks) { if (Test-Path $l) { Remove-Item $l -Force; Say "Removed old shortcut $l" } }
    if (Test-Path $legacyDir) {
        try { Remove-Item $legacyDir -Recurse -Force; Say "Removed old per-user install $legacyDir" }
        catch { Say "Could not remove $legacyDir (is the old version still open?) - delete it later." 'Yellow' }
    }
    # A pinned taskbar icon is a copy of the shortcut: point it at the new location instead of
    # leaving it broken (or still aimed at the old, user-writable copy).
    if (-not $Uninstall -and (Test-Path $pinnedLnk)) {
        try { Set-NccShortcut $pinnedLnk; Say 'Updated your pinned taskbar icon to the new location.' }
        catch { Say 'Could not update the pinned taskbar icon - unpin it and pin the app again.' 'Yellow' }
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# =============================================================================================
# Normal user: run the machine-wide part elevated (one UAC prompt), then tidy up this user's
# profile - which must happen as the user, because with a separate admin account the elevated
# part would see that account's profile instead.
# =============================================================================================
if (-not $isAdmin) {
    $log = Join-Path $env:TEMP "ncc-install-$PID.log"
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-LogPath', "`"$log`"")
    if ($Desktop)   { $childArgs += '-Desktop' }
    if ($NoLaunch)  { $childArgs += '-NoLaunch' }
    if ($Uninstall) { $childArgs += '-Uninstall' }
    Write-Host 'Asking for administrator rights (installing to Program Files)...'
    try {
        $p = Start-Process -FilePath $psExe -ArgumentList $childArgs -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    } catch {
        Write-Host 'Cancelled - nothing was changed.' -ForegroundColor Yellow
        exit 1
    }
    if (Test-Path $log) { Get-Content $log | ForEach-Object { Write-Host $_ }; Remove-Item $log -ErrorAction SilentlyContinue }
    if ($p.ExitCode -ne 0) { Write-Host 'Installation failed - see above.' -ForegroundColor Red; exit 1 }
    Update-UserProfile
    exit 0
}

# =============================================================================================
# Administrator: machine-wide install / uninstall.
# =============================================================================================
try {
    # Started from an already elevated prompt (no -LogPath): this process is also the user's own.
    $runDirectly = -not $LogPath
    if ($Uninstall) {
        foreach ($p in $startLnk, $deskLnk) { if (Test-Path $p) { Remove-Item $p -Force; Say "Removed $p" } }
        if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force; Say "Removed $installDir" }
        if ($runDirectly) { Update-UserProfile }
        Say 'If it is pinned, right-click the taskbar icon -> Unpin from taskbar.'
        Say 'Your profiles and change log in %APPDATA%\NetworkControlCenter were kept.'
        exit 0
    }

    $src = $PSScriptRoot
    foreach ($f in 'NetworkControlCenter.ps1', 'NetworkControlCenter.ico') {
        if (-not (Test-Path (Join-Path $src $f))) { throw "$f not found next to this installer." }
    }
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    foreach ($f in 'NetworkControlCenter.ps1', 'NetworkControlCenter.ico') {
        $from = Join-Path $src $f; $to = Join-Path $installDir $f
        # Unchanged files are skipped, so a running copy of the app doesn't block an update.
        if ((Test-Path $to) -and (Get-FileHash $from).Hash -eq (Get-FileHash $to).Hash) { continue }
        try { Copy-Item $from $to -Force }
        catch { throw "Could not update $f - close Network Control Center and run the installer again. ($($_.Exception.Message))" }
    }
    Get-ChildItem $installDir | Unblock-File -ErrorAction SilentlyContinue

    # The folder inherits Program Files permissions (users: read/execute only). Check rather than assume.
    # Rights are compared as bits: ACEs may hold generic rights that only show up as a raw number.
    # WriteData, AppendData, WriteEA, DeleteChild, WriteAttributes, Delete, WriteDAC, WriteOwner,
    # GENERIC_ALL, GENERIC_WRITE.
    $writeMask = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
    $writable = (Get-Acl $installDir).Access | Where-Object {
        $_.AccessControlType -eq 'Allow' -and
        $_.IdentityReference -match '\\(Users|Authenticated Users|INTERACTIVE|Everyone)$|^Everyone$' -and
        (([int64]$_.FileSystemRights -band 0xFFFFFFFFL) -band $writeMask) -ne 0
    }
    if ($writable) { throw "$installDir is writable by normal users - fix its permissions before using the app." }

    Set-NccShortcut $startLnk; Say "Created $startLnk"
    if ($Desktop) { Set-NccShortcut $deskLnk; Say "Created $deskLnk" }
    if ($runDirectly) { Update-UserProfile }

    Say ''
    Say "Installed to $installDir" 'Green'
    Say 'To pin it: when the app is open, right-click its taskbar icon -> Pin to taskbar.'
    Say "(Or: Start menu -> type '$appName' -> right-click -> Pin to taskbar.)"
    Say 'Re-run this installer after updating the files to refresh the installed copy.'

    # Already elevated here, so this starts the app without a second UAC prompt.
    if (-not $NoLaunch) { Start-Process -FilePath $startLnk }
    exit 0
} catch {
    Say "ERROR: $($_.Exception.Message)" 'Red'
    exit 1
}
