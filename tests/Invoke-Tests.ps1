<#
 Offline tests for NetworkControlCenter.ps1 - no admin rights, no network changes, no GUI shown.

 The app is a single self-elevating script, so it can't simply be dot-sourced. Instead this
 runner parses it with the PowerShell AST and loads only the pure helper functions listed in
 $HelperFunctions, then checks:
   - input validation / subnet math / profile normalization helpers
   - profile JSON round-trips (incl. the 0- and 1-profile array-shape edge cases)
   - the XAML parses and every x:Name the script looks up actually exists
   - every $ctl.<name> used anywhere in the script is registered in $controlNames

 Run (Windows PowerShell 5.1, STA is required for the XAML check):
   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
 Exit code = number of failed tests.
#>

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\NetworkControlCenter.ps1' | Resolve-Path

$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

$script:Passed = 0
$script:Failed = 0

function Pass([string]$name) { $script:Passed++; Write-Host "  ok    $name" -ForegroundColor DarkGreen }
function Fail([string]$name, [string]$why) { $script:Failed++; Write-Host "  FAIL  $name - $why" -ForegroundColor Red }

function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ("$Expected" -ceq "$Actual") { Pass $Name } else { Fail $Name "expected '$Expected', got '$Actual'" }
}

function Assert-Throws([scriptblock]$Code, [string]$Pattern, [string]$Name) {
    try { & $Code | Out-Null; Fail $Name 'did not throw' }
    catch {
        if ($_.Exception.Message -match $Pattern) { Pass $Name }
        else { Fail $Name "threw '$($_.Exception.Message)' (expected match: $Pattern)" }
    }
}

# ---------------------------------------------------------------------
Write-Host "Parse"
if ($parseErrors.Count -eq 0) { Pass 'script has no syntax errors' }
else { $parseErrors | ForEach-Object { Fail 'syntax' "$($_.Message) (line $($_.Extent.StartLineNumber))" }; exit $script:Failed }

$HelperFunctions = @(
    'Test-IPv4', 'ConvertTo-NormalizedIPv4', 'ConvertTo-IPv4Int', 'ConvertFrom-IPv4Int', 'Get-PrefixMaskInt',
    'Test-SameSubnet', 'Test-UsableIPv4', 'Resolve-Prefix', 'Get-MaskFromPrefix', 'Resolve-VlanId',
    'Test-ConfigInput', 'Format-AdapterConfig', 'Format-ConfigSummary', 'Get-DefaultProfiles',
    'ConvertTo-NccProfile', 'Read-ProfileFile', 'Write-JsonFileAtomic',
    'Get-SubnetSummary', 'Get-QuickConfigForDevice', 'Format-LinkSpeed', 'Format-MacAddress',
    'Get-AdapterKind', 'ConvertTo-VlanInfo', 'Format-ProfileSummary',
    'Get-AdapterInventory', 'Get-VlanInventory', 'New-WorkerPool'
)
$fnAsts = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($name in $HelperFunctions) {
    $fn = $fnAsts | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fn) { Fail "load $name" 'function not found in script'; continue }
    . ([scriptblock]::Create($fn.Extent.Text))
}

# ---------------------------------------------------------------------
Write-Host "IPv4 parsing"
Assert-Equal $true  (Test-IPv4 '192.168.1.1')     'valid dotted quad'
Assert-Equal $true  (Test-IPv4 ' 10.0.0.1 ')      'surrounding whitespace allowed'
Assert-Equal $false (Test-IPv4 '10')              'shorthand "10" rejected'
Assert-Equal $false (Test-IPv4 '192.168.1')       'three octets rejected'
Assert-Equal $false (Test-IPv4 '256.1.1.1')       'octet > 255 rejected'
Assert-Equal $false (Test-IPv4 'a.b.c.d')         'letters rejected'
Assert-Equal $false (Test-IPv4 '')                'empty rejected'
Assert-Equal $false (Test-IPv4 '1.2.3.4.5')       'five octets rejected'
Assert-Equal '192.168.1.10' (ConvertTo-NormalizedIPv4 '192.168.001.010') 'leading zeros stripped'
Assert-Equal '10.20.30.40'  (ConvertFrom-IPv4Int (ConvertTo-IPv4Int '10.20.30.40')) 'int round-trip'
Assert-Equal '255.255.255.255' (ConvertFrom-IPv4Int (ConvertTo-IPv4Int '255.255.255.255')) 'int round-trip max'
Assert-Equal $false (Test-UsableIPv4 '127.0.0.1') 'loopback unusable'
Assert-Equal $false (Test-UsableIPv4 '224.0.0.5') 'multicast unusable'
Assert-Equal $false (Test-UsableIPv4 '0.1.2.3')   '0.x unusable'
Assert-Equal $true  (Test-UsableIPv4 '169.254.1.1') 'link-local usable'

Write-Host "Prefix / mask"
Assert-Equal 24 (Resolve-Prefix '255.255.255.0') 'dotted mask'
Assert-Equal 24 (Resolve-Prefix '/24')           'slash CIDR'
Assert-Equal 24 (Resolve-Prefix ' 24 ')          'bare CIDR'
Assert-Equal 32 (Resolve-Prefix '255.255.255.255') '/32 mask'
Assert-Equal 0  (Resolve-Prefix '0.0.0.0')       '/0 mask'
Assert-Throws { Resolve-Prefix '255.0.255.0' } 'contiguous' 'non-contiguous mask rejected'
Assert-Throws { Resolve-Prefix '33' }          '0-32'       'prefix 33 rejected'
Assert-Throws { Resolve-Prefix 'abc' }         'not valid'  'garbage mask rejected'
Assert-Equal '255.255.255.252' (Get-MaskFromPrefix 30) 'mask from /30'
$roundTripOk = $true
foreach ($p in 0..32) { if ((Resolve-Prefix (Get-MaskFromPrefix $p)) -ne $p) { $roundTripOk = $false } }
Assert-Equal $true $roundTripOk 'mask <-> prefix round-trip for /0../32'
Assert-Equal $true  (Test-SameSubnet '192.168.1.10' '192.168.1.1' 24) 'same /24'
Assert-Equal $false (Test-SameSubnet '192.168.1.10' '192.168.2.1' 24) 'different /24'
Assert-Equal $true  (Test-SameSubnet '192.168.0.10' '192.168.1.1' 23) 'same /23'

Write-Host "VLAN"
Assert-Equal 0   (Resolve-VlanId '')    'empty = untagged'
Assert-Equal 100 (Resolve-VlanId '100') 'numeric'
Assert-Throws { Resolve-VlanId '4095' } '0 and 4094' 'out of range rejected'
Assert-Throws { Resolve-VlanId 'x' }    'number'     'non-numeric rejected'

Write-Host "Config validation"
$c = Test-ConfigInput -Mode Static -Ip '192.168.1.10' -Mask '/24' -Gateway '192.168.1.1' -Dns1 '8.8.8.8' -Dns2 '8.8.8.8'
Assert-Equal 'Static|192.168.1.10|24|192.168.1.1|8.8.8.8|0' "$($c.Mode)|$($c.Ip)|$($c.Prefix)|$($c.Gateway)|$($c.Dns -join ',')|$($c.Mtu)" 'valid static (duplicate DNS collapsed)'
$c = Test-ConfigInput -Mode Static -Ip '010.000.000.005' -Mask '255.0.0.0' -Gateway '10.0.0.1'
Assert-Equal '10.0.0.5/8' "$($c.Ip)/$($c.Prefix)" 'leading zeros normalized'
$c = Test-ConfigInput -Mode DHCP -Ip 'garbage' -Mask 'junk' -Mtu '1400'
Assert-Equal 'DHCP|1400' "$($c.Mode)|$($c.Mtu)" 'DHCP mode ignores IP fields but validates MTU'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '192.168.1.10' -Mask '/24' -Gateway '192.168.2.1' } 'not inside 192\.168\.1\.0/24' 'off-subnet gateway rejected'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '192.168.1.0'  -Mask '/24' } 'network address'   'network address rejected'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '192.168.1.255' -Mask '/24' } 'broadcast address' 'broadcast address rejected'
$c = Test-ConfigInput -Mode Static -Ip '192.168.1.0' -Mask '/31' -Gateway '192.168.1.1'
Assert-Equal '192.168.1.0/31' "$($c.Ip)/$($c.Prefix)" '/31 point-to-point allows .0'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '10.0.0.1' -Mask '/32' -Gateway '10.0.0.2' } '/32' '/32 with gateway rejected'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '10.0.0.1' -Mask '/24' -Gateway '10.0.0.1' } 'same as the IP' 'gateway = IP rejected'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '127.0.0.1' -Mask '/8' } 'reserved' 'loopback rejected'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '10.0.0.1' -Mask '' } 'required' 'missing mask rejected'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '10.0.0.1' -Mask '/0' } '1-32' '/0 host rejected'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '10' -Mask '/8' } 'valid IPv4' 'shorthand IP rejected'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '10.0.0.1' -Mask '/8' -Dns1 '8.8.8' } 'DNS server' 'bad DNS rejected'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '10.0.0.1' -Mask '/8' -Mtu '500' } '576 and 9216' 'MTU too small rejected'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '10.0.0.1' -Mask '/8' -Mtu 'abc' } 'number' 'MTU non-numeric rejected'
$c = Test-ConfigInput -Mode Static -Ip '192.168.1.10' -Mask '/24' -ExtraIPs "10.0.0.5`r`n10.0.0.6/16`r`n`r`n192.168.1.10`n10.0.0.5"
Assert-Equal '10.0.0.5/24,10.0.0.6/16' (($c.Extra | ForEach-Object { "$($_.Ip)/$($_.Prefix)" }) -join ',') 'extra IPs parsed, prefix inherited, duplicates dropped'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '192.168.1.10' -Mask '/24' -ExtraIPs '10.0.0' } "Additional IP '10.0.0'" 'bad extra IP rejected'
Assert-Throws { Test-ConfigInput -Mode Static -Ip '192.168.1.10' -Mask '/24' -ExtraIPs '10.0.0.5/40' } '0-32' 'bad extra prefix rejected'
Assert-Equal 'static 192.168.1.10/24 gw 192.168.1.1 mtu 1400' (Format-ConfigSummary (Test-ConfigInput -Mode Static -Ip '192.168.1.10' -Mask '/24' -Gateway '192.168.1.1' -Mtu 1400)) 'config summary'
Assert-Equal 'DHCP dns 1.1.1.1' (Format-AdapterConfig ([PSCustomObject]@{ Dhcp = $true; Dns = @('1.1.1.1'); Mtu = $null })) 'adapter summary'

Write-Host "Profiles"
Assert-Equal $true ($null -eq (ConvertTo-NccProfile ([PSCustomObject]@{ Name = '  ' }))) 'nameless profile dropped'
$p = ConvertTo-NccProfile ([PSCustomObject]@{ Name = ' Site A '; Mode = 'dhcp'; Prefix = '255.255.255.0' })
Assert-Equal 'Site A|DHCP|24||' "$($p.Name)|$($p.Mode)|$($p.Prefix)|$($p.IP)|$($p.Vlan)" 'profile normalized'
$p = ConvertTo-NccProfile ([PSCustomObject]@{ Name = 'x'; Mode = 'weird'; Prefix = 'bogus' })
Assert-Equal 'Static|' "$($p.Mode)|$($p.Prefix)" 'unknown mode -> Static, bad prefix -> empty'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "ncc-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $f = Join-Path $tmp 'profiles.json'
    foreach ($n in 0, 1, 4) {
        $set = @(Get-DefaultProfiles | Select-Object -First $n)
        Write-JsonFileAtomic $f $set
        $back = @(Read-ProfileFile $f)
        Assert-Equal $n $back.Count "round-trip of $n profile(s) keeps count"
    }
    $back = @(Read-ProfileFile $f)
    Assert-Equal 'Newtec MDM5000 - Mgmt|24' "$($back[1].Name)|$($back[1].Prefix)" 'round-trip keeps fields'
    Assert-Equal $false (Test-Path "$f.tmp") 'atomic write leaves no temp file'
    Set-Content -Path $f -Value '' -NoNewline
    Assert-Equal 0 @(Read-ProfileFile $f).Count 'empty file = no profiles'
    Set-Content -Path $f -Value '{ not json'
    Assert-Throws { Read-ProfileFile $f } '.' 'corrupt file throws (so Load-Profiles can back it up)'
    Set-Content -Path $f -Value '{"Name":"Solo","Mode":"Static","IP":"10.1.1.1","Prefix":24}'
    Assert-Equal 'Solo' (@(Read-ProfileFile $f)[0].Name) 'single-object JSON accepted'
} finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------
Write-Host "VLAN classification"
$props = @(
    [PSCustomObject]@{ Name = 'Intel'; DisplayName = 'Packet Priority & VLAN'; DisplayValue = 'Packet Priority & VLAN Enabled'; RegistryKeyword = '*PriorityVLANTag'; RegistryValue = @('3') }
    [PSCustomObject]@{ Name = 'Realtek'; DisplayName = 'Priority & VLAN'; DisplayValue = 'Priority & VLAN Enabled'; RegistryKeyword = '*PriorityVLANTag'; RegistryValue = @('3') }
    [PSCustomObject]@{ Name = 'Realtek'; DisplayName = 'VLAN ID'; DisplayValue = '120'; RegistryKeyword = 'VlanID'; RegistryValue = @('120') }
    [PSCustomObject]@{ Name = 'Odd'; DisplayName = 'VLAN Identifier'; DisplayValue = 'Not present'; RegistryKeyword = '*VlanId'; RegistryValue = @('0') }
)
$scan = ConvertTo-VlanInfo $props @('Intel', 'Realtek', 'Odd', 'Missing')
Assert-Equal $false $scan['Intel'].Supported '*PriorityVLANTag alone is NOT a VLAN ID'
Assert-Equal 'True|VlanID|120' "$($scan['Realtek'].Supported)|$($scan['Realtek'].Keyword)|$($scan['Realtek'].Value)" 'VlanID property detected'
Assert-Equal 'True|0' "$($scan['Odd'].Supported)|$($scan['Odd'].Value)" 'non-numeric display value falls back to registry value'
Assert-Equal $false $scan['Missing'].Supported 'adapter without properties = unsupported'

# ---------------------------------------------------------------------
Write-Host "Subnet summary / quick fill"
$s = Get-SubnetSummary '192.168.1.50' 24
Assert-Equal '192.168.1.0|255.255.255.0|192.168.1.1|192.168.1.254|192.168.1.255|254' "$($s.Network)|$($s.Mask)|$($s.FirstHost)|$($s.LastHost)|$($s.Broadcast)|$($s.Hosts)" '/24 summary'
$s = Get-SubnetSummary '10.0.0.7' 30
Assert-Equal '10.0.0.4|10.0.0.5|10.0.0.6|2' "$($s.Network)|$($s.FirstHost)|$($s.LastHost)|$($s.Hosts)" '/30 summary'
$s = Get-SubnetSummary '10.0.0.0' 31
Assert-Equal '10.0.0.0|10.0.0.1|2|' "$($s.FirstHost)|$($s.LastHost)|$($s.Hosts)|$($s.Broadcast)" '/31 has no broadcast'
$q = Get-QuickConfigForDevice '192.168.1.1'
Assert-Equal '192.168.1.10/24 gw 192.168.1.1' "$($q.Ip)/$($q.Prefix) gw $($q.Gateway)" 'device .1 -> laptop .10'
$q = Get-QuickConfigForDevice '192.168.1.10'
Assert-Equal '192.168.1.100' $q.Ip 'device at .10 -> laptop .100 (never the device itself)'
$q = Get-QuickConfigForDevice '10.0.0.1' 30
Assert-Equal '10.0.0.2/30' "$($q.Ip)/$($q.Prefix)" 'tiny subnet falls back to any free host'
$sw = [Diagnostics.Stopwatch]::StartNew()
$q = Get-QuickConfigForDevice '10.20.30.40' 8
Assert-Equal '10.0.0.10' $q.Ip '/8 device works'
Assert-Equal $true ($sw.ElapsedMilliseconds -lt 500) "/8 quick fill is instant ($($sw.ElapsedMilliseconds) ms)"
Assert-Equal '192.168.1.10' (Get-QuickConfigForDevice '192.168.1.1' 0).Ip 'silly prefix falls back to /24'
Assert-Throws { Get-QuickConfigForDevice '192.168.1.0' } 'network or broadcast' 'device = network address rejected'
Assert-Throws { Get-QuickConfigForDevice '192.168.1' } 'IP address first' 'bad device IP rejected'
Assert-Equal 24 (Resolve-Prefix '/24   255.255.255.0   254 hosts') 'picker text with description parses'
$c = Test-ConfigInput -Mode Static -Ip '10.1.1.5' -Mask '/24' -Dns1 '8.8.8.8   Google' -Mtu '1492   PPPoE'
Assert-Equal '8.8.8.8|1492' "$($c.Dns -join ',')|$($c.Mtu)" 'DNS / MTU picker text with description parses'

Write-Host "Adapter classification / formatting"
Assert-Equal 'WiFi'      (Get-AdapterKind 9 $false 'Wi-Fi' 'Intel(R) Wi-Fi 6E AX211') 'Wi-Fi'
Assert-Equal 'Ethernet'  (Get-AdapterKind 14 $false 'Ethernet' 'Intel(R) Ethernet I219-LM') 'built-in Ethernet'
Assert-Equal 'Ethernet'  (Get-AdapterKind 14 $false 'Ethernet 3' 'Realtek USB GbE Family Controller') 'USB / dock Ethernet'
Assert-Equal 'Virtual'   (Get-AdapterKind 14 $true 'Ethernet 4' 'Fortinet SSL VPN Virtual Ethernet Adapter') 'VPN claiming 802.3 is virtual'
Assert-Equal 'Bluetooth' (Get-AdapterKind 10 $true 'Bluetooth Network Connection' 'Bluetooth Device (PAN)') 'Bluetooth PAN'
Assert-Equal 'Cellular'  (Get-AdapterKind 8 $false 'Cellular' 'Intel XMM 7360 LTE-A') 'cellular'
Assert-Equal 'Virtual'   (Get-AdapterKind 0 $true 'vEthernet (Default Switch)' 'Hyper-V Virtual Ethernet Adapter') 'Hyper-V switch'
Assert-Equal '00-1A-2B-3C-4D-5E' (Format-MacAddress '001a2b3c4d5e') 'MAC formatting'
Assert-Equal '287 Mbps' (Format-LinkSpeed 287000000) 'speed Mbps'
Assert-Equal '2.5 Gbps' (Format-LinkSpeed 2500000000) 'speed Gbps'
Assert-Equal '' (Format-LinkSpeed $null) 'no speed'
Assert-Equal '192.168.1.10/24   gateway 192.168.1.1   mtu 1400' (Format-ProfileSummary ([PSCustomObject]@{ Mode = 'Static'; IP = '192.168.1.10'; Prefix = 24; Gateway = '192.168.1.1'; Mtu = '1400' })) 'profile tooltip'

# ---------------------------------------------------------------------
Write-Host "Background runspaces (read-only, live)"
$assignAll = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
$wfAst = $assignAll | Where-Object { $_.Left.Extent.Text -eq '$script:WorkerFunctions' } | Select-Object -First 1
$script:WorkerFunctions = @($wfAst.Right.Expression.SafeGetValue())
$missingWorker = @($script:WorkerFunctions | Where-Object { -not ($fnAsts | Where-Object Name -eq $_) })
if ($missingWorker) { Fail 'every $WorkerFunctions entry is defined' ($missingWorker -join ', ') }
else { Pass "every `$WorkerFunctions entry is defined ($($script:WorkerFunctions.Count))" }
# Worker functions run in runspaces that can't see the UI - they must not touch it.
$leaky = @($fnAsts | Where-Object { $script:WorkerFunctions -contains $_.Name -and $_.Extent.Text -match '\$ctl\b|\$window\b|\$script:' } | ForEach-Object Name)
if ($leaky) { Fail 'worker functions are UI-free' ($leaky -join ', ') } else { Pass 'worker functions are UI-free' }
foreach ($name in $script:WorkerFunctions) {
    if (-not (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) {
        $fn = $fnAsts | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($fn) { . ([scriptblock]::Create($fn.Extent.Text)) }
    }
}

# Security: elevated workers identify the adapter by interface index only and look up its name and
# VLAN keyword live - those values on the UI side can come from the user-writable cache file.
$txParams = @((Get-Command Invoke-ConfigTransaction).Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
Assert-Equal 'Idx,Action,Cfg,Snapshot,VlanTarget' ($txParams -join ',') 'config transaction takes no adapter name / VLAN keyword from the caller'
$actParams = @((Get-Command Invoke-AdapterAction).Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
Assert-Equal 'Action,Idx' ($actParams -join ',') 'adapter actions take an interface index, not a name'
Assert-Throws { Invoke-AdapterAction 'Restart' 999999 } 'no longer present' 'unknown interface index is refused before anything runs'

$sw = [Diagnostics.Stopwatch]::StartNew()
$inv = @(Get-AdapterInventory)
$invMs = $sw.ElapsedMilliseconds
Assert-Equal $true ($inv.Count -ge 1) "inventory finds adapters ($($inv.Count) in $invMs ms)"
$needed = 'Name', 'InterfaceIndex', 'Status', 'Kind', 'Dhcp', 'IPv4', 'Glyph', 'StatusText', 'IPText', 'StatusBrush', 'IconBg', 'CableBrush'
$incomplete = @($inv | Where-Object { $o = $_; @($needed | Where-Object { $null -eq $o.$_ }).Count })
Assert-Equal 0 $incomplete.Count 'every adapter has the fields the tiles bind to'
Assert-Equal $true (@($inv | Where-Object { $_.Status -notin 'Up', 'Disconnected', 'Disabled', 'Down' }).Count -eq 0) 'status is always one of Up/Disconnected/Disabled/Down'
$one = @(Get-AdapterInventory -InterfaceIndex $inv[0].InterfaceIndex)
Assert-Equal "1|$($inv[0].Name)" "$($one.Count)|$($one[0].Name)" 'single-adapter snapshot'
$vl = Get-VlanInventory
Assert-Equal $true ($vl -is [hashtable] -and $vl.Count -ge 1) 'VLAN scan returns one entry per adapter'

# The same mechanism the app uses: worker functions copied into a pool, job runs there.
$pool = New-WorkerPool
$deadline = (Get-Date).AddSeconds(15)
while ($pool.RunspacePoolStateInfo.State -ne 'Opened' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
Assert-Equal 'Opened' "$($pool.RunspacePoolStateInfo.State)" 'worker pool opens'
$ps = [powershell]::Create(); $ps.RunspacePool = $pool
[void]$ps.AddScript('param($p) [PSCustomObject]@{ N = @(Get-AdapterInventory).Count }').AddParameter('p', 1)
$res = $ps.Invoke()
$poolErr = if ($ps.Streams.Error.Count) { "$($ps.Streams.Error[0])" } else { '' }
Assert-Equal $inv.Count $res[0].N "inventory runs inside the worker pool $poolErr"
$ps.Dispose(); $pool.Dispose()

# ---------------------------------------------------------------------
Write-Host "XAML / control wiring"
$assignments = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $false)
$xamlAst  = $assignments | Where-Object { $_.Left.Extent.Text -eq '$xaml' } | Select-Object -First 1
$namesAst = $assignments | Where-Object { $_.Left.Extent.Text -eq '$controlNames' } | Select-Object -First 1
$controlNames = @($namesAst.Right.Expression.SafeGetValue())

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Fail 'XAML load' 'runner must be started with -STA'
} else {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    try {
        [xml]$doc = $xamlAst.Right.Expression.Value
        $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))
        Pass 'XAML loads'
        $missing = @($controlNames | Where-Object { -not $win.FindName($_) })
        if ($missing) { Fail 'every $controlNames entry exists in XAML' ($missing -join ', ') }
        else { Pass "every `$controlNames entry exists in XAML ($($controlNames.Count))" }
        $win.Close()
    } catch {
        Fail 'XAML loads' $_.Exception.Message
    }
}

$used = [regex]::Matches((Get-Content $scriptPath -Raw), '\$ctl\.(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$unregistered = @($used | Where-Object { $controlNames -notcontains $_ })
if ($unregistered) { Fail 'every $ctl.<name> used is registered' ($unregistered -join ', ') }
else { Pass "every `$ctl.<name> used is registered ($($used.Count))" }

# ---------------------------------------------------------------------
Write-Host ""
$color = if ($script:Failed) { 'Red' } else { 'Green' }
Write-Host "$($script:Passed) passed, $($script:Failed) failed" -ForegroundColor $color
exit $script:Failed
