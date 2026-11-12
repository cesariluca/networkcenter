# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file Windows PowerShell + WPF (XAML) desktop app for field engineers: a home screen showing
the laptop with its adapters (wired left, wireless right, virtual below), and a per-adapter page to
change IP/mask/gateway/DNS/MTU/VLAN/secondary IPs, apply one-click profiles, and run tools.

- `NetworkControlCenter.ps1` — the entire application (~2500 lines, about a third of it XAML).
- `Install-Shortcut.ps1` / `Install.cmd` — installs to `%ProgramFiles%\NetworkControlCenter` with an
  all-users Start menu shortcut (run-as-admin, `conhost --headless`, AppUserModelID) that the user
  pins to the taskbar. Non-elevated it re-runs itself elevated for the machine-wide part, then as
  the user removes legacy per-user installs (`%LOCALAPPDATA%\Programs\...`) and repoints an existing
  pinned taskbar shortcut. It refuses to finish if the install folder is writable by normal users.
- `LICENSE` (MIT), `SECURITY.md` (threat model + private reporting). The repo is public.
- `Launch Network Control Center.cmd` — run in place without installing.
- `tests/Invoke-Tests.ps1` — offline test runner (see below).
- `Network Center.lnk` — the author's old machine-specific shortcut; gitignored.

No build system or package manager. User-facing docs are in `README.md`.

## Running / testing changes

Windows only (Windows 10/11, Windows PowerShell 5.1 — not pwsh; WPF needs 5.1 + `-STA`).

- Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\NetworkControlCenter.ps1`.
  Not elevated, it relaunches itself elevated through `conhost.exe --headless` (one UAC prompt) and
  exits. Plain `-WindowStyle Hidden` is not enough on Windows 11: with Windows Terminal as default
  terminal it leaves an empty terminal window open for the whole session.
- **Tests** (no admin, no network changes, no window shown):
  `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1`
  (exit code = failure count). The app self-elevates, so it can't be dot-sourced: the runner parses
  it with the PowerShell AST and loads only the functions named in `$HelperFunctions` — add new pure
  helpers there. It also: reads `$script:WorkerFunctions` from the AST and checks each exists and
  never references `$ctl`/`$window`/`$script:`; runs the real (read-only) CIM inventory, also inside
  a pool built by `New-WorkerPool`; loads the XAML and checks every `$controlNames` entry exists and
  every `$ctl.<name>` used is registered.
- **Handler smoke tests** without elevation: run a copy with the elevation `if` replaced by
  `if ($false) {`, `$PSScriptRoot` replaced by the repo path, `$env:APPDATA` pointed at a temp dir,
  and `$window.ShowDialog()` replaced by `$window.Show()` plus code that raises
  `ButtonBase.ClickEvent` on `$ctl` buttons and pumps the dispatcher until `$script:Jobs` is empty.
  Non-elevated, every mutation is refused with "Access is denied", which exercises the rollback path
  without changing anything. Redefine `Confirm-Action` to answer dialogs. `RenderTargetBitmap` on
  `$window.Content` gives screenshots for layout checks.
- Real IP changes still need a manual elevated run — prefer a spare/USB NIC over the one carrying
  your connectivity.
- Scripts must stay pure ASCII (PowerShell 5.1 reads BOM-less files as ANSI): glyphs are XAML
  entities (`&#xE701;`) or `[char]0xE701`, the middle dot is `$script:Dot`.

## Architecture

`NetworkControlCenter.ps1` is organized into numbered sections (`# N. SECTION` banners):

1. **Self-elevation** (see above).
2. **Assemblies & app identity** — WPF, plus `Set-AppIdentity`: sets the process AppUserModelID via
   a Reflection.Emit P/Invoke stub (not `Add-Type`, which would start the C# compiler on every
   launch). It must equal the ID the installer writes into the shortcut (`$script:AppId` /
   `$appId` in `Install-Shortcut.ps1`), or the window won't group under the pinned taskbar icon.
3. **UI (XAML)** — one single-quoted here-string. Styles/templates live in `Window.Resources`
   (buttons, action tiles, text boxes whose `Tag` is the placeholder, editable ComboBox template,
   slim scrollbars, segmented control, switch, adapter tiles, profile chips, the keyboard
   `DrawingBrush`). Two pages in the same grid row, toggled by `Visibility`: `pnlHome` (laptop drawn
   in XAML inside a `Viewbox StretchDirection=DownOnly`, so it scales down on small screens) and
   `pnlConfig` (header with action icons; centre: profiles, IP settings, ping; right: Advanced
   MTU/VLAN/extra IPs and Details). Adapter tiles and profile chips are `ItemsControl`s with
   `DataTemplate`s bound to object properties (brushes bound as `#RRGGBB` strings; `Cached` fades a
   tile). Icons are Segoe Fluent/MDL2 glyphs - check new code points by rendering them, many are
   empty. Named elements go into the `$ctl` hashtable via `$controlNames`.
4. **Helpers**
   - Pure validation/subnet math: `Test-IPv4` (strict), `Resolve-Prefix` (takes `/24`,
     `255.255.255.0`, or picker text — only the first token counts), `Get-SubnetSummary`,
     `Get-QuickConfigForDevice`, `Resolve-VlanId`, and `Test-ConfigInput` (raw form text → normalized
     config, or a user-facing exception).
   - `Get-AdapterInventory` — **raw CIM** (`Get-CimInstance root/StandardCimv2 MSFT_*`), not
     `Get-NetAdapter` & co: the cmdlets import CDXML modules on first use (~6 s cold) versus <1 s for
     raw CIM. One bulk query per class, joined by `InterfaceIndex` in memory; never query per adapter.
     Enum values are numeric here (`Dhcp` 1, `PrefixOrigin` 2 = WellKnown, `MediaConnectState` 1, ...).
     Each object also carries display fields for the tiles (`Glyph`, `StatusText`, `IPText`, brushes).
     `Get-AdapterKind` places adapters: NdisPhysicalMedium decides; the virtual flag beats 802.3 (VPNs
     claim Ethernet); name matching is only a whole-word fallback ("Realtek" contains "lte").
   - `ConvertTo-VlanInfo` — only a numeric VLAN **ID** property counts; never `*PriorityVLANTag`
     ("Packet Priority & VLAN", an enum on most Intel/Realtek NICs — writing an ID into it corrupts
     the driver setting). Covered by tests.
   - Mutations (cmdlets, run only in the work runspace): `Clear-IPv4Config` clears routes/IPs in
     **both** ActiveStore and PersistentStore (active-only leaves stale entries that make
     `New-NetIPAddress` fail with "DefaultGateway already exists"), `Set-StaticConfig`,
     `Set-InterfaceDhcp`, `Set-InterfaceMtu`, `Set-Vlan`, `Restore-AdapterConfig`.
   - `Invoke-ConfigTransaction` — one whole change in the worker: fresh single-adapter snapshot →
     change → automatic rollback to the snapshot on failure → MTU/VLAN as separate best-effort steps
     (failures become warnings) → fresh full inventory. Returns a plain result object.
   - `Invoke-AdapterAction` (enable/disable/restart/renew/flush DNS/clear ARP), `Invoke-PingTest`.
   - Internet sharing (Windows ICS) via the `HNetCfg.HNetShare` COM API (admin only; non-admin it
     reports "not available"): `Get-IcsState` (pair as interface indexes, `ScopeAddress`, reboot
     persistence, neighbor-cache clients), `Invoke-IcsChange` (Start / Update / Stop; indexes only,
     like the other workers). Windows allows one pair; only `ScopeAddress` (registry, always a /24)
     and `EnableRebootPersistConnection` are configurable - don't promise more in the UI. A changed
     address needs a SharedAccess service restart. Stop also sets the private port back to DHCP
     (Windows leaves it on the static sharing address). Undo after Start uses a snapshot with
     `UndoIcs = $true`, which makes the Restore transaction disable sharing first.
     `Assert-IcsScopeAddress` / `Get-IcsConflict` (UI side) validate the address.
   - `$script:WorkerFunctions` — the functions copied into the background runspaces.
   - Profiles (`ConvertTo-NccProfile` normalizes anything loaded/imported), `Write-JsonFileAtomic`
     (temp + move; `-InputObject` keeps 0/1 items an array), the adapter cache
     (`Save-InventoryCache` / `Read-InventoryCache`, versioned — bump `Version` when the inventory
     shape changes; cached objects get `Cached = $true` and grey brushes and are never written back),
     `Write-ChangeLog` (must never throw).
5. **UI binding / state / background jobs**
   - Two `RunspacePool`s from `New-WorkerPool` (opened asynchronously): `ScanPool` (inventory, VLAN
     scan, ping, flush/ARP) and `WorkPool` (adapter changes; a warm-up job imports NetTCPIP /
     DnsClient / NetAdapter at startup so the first Apply doesn't pay for it). Size 1 each, so jobs
     in a pool run in order.
   - `Start-WorkJob -Pool -Script -Params -Context -OnDone [-BusyLabel]`: the script is plain text run
     in the pool; `OnDone` runs on the UI thread from the 120 ms `DispatcherTimer`
     (`Complete-WorkJobs`) as `& $OnDone $result $err $ctx`. Pass state through `-Context`, never via
     `GetNewClosure()` (a closure is bound to a new module scope that can't see this script's
     functions). `-BusyLabel` makes it a foreground job: `Set-Busy` locks the pages and shows the
     progress bar until it finishes.
   - `Update-Inventory` is the single entry point for new adapter data (cache, scan, or a job's
     `After`): merges `$script:VlanCache`, re-renders home, and refreshes the open page — re-filling
     the form only if it isn't dirty.
   - Dirty tracking compares `Get-FormSignature` against the baseline taken in `Show-Adapter`, so
     undoing an edit by hand clears it; `$script:Populating` suppresses change events while the code
     itself fills the form.
6. **Event handlers** — tile and chip clicks use one `AddHandler(ButtonBase.ClickEvent)` per
   `ItemsControl` and read `OriginalSource.DataContext` (chips also `CommandParameter`); editable
   combos raise `TextBoxBase.TextChangedEvent`. Plus F5 / Esc, `Dispatcher.UnhandledException` →
   status bar, and a close guard while a change is running.
7. **Startup** — size/centre the window inside `SystemParameters.WorkArea` (laptops at 150% scaling
   have ~750 px of height; never hard-code a taller window), draw from the cache, start the poll
   timer, `ShowDialog()`. Pools, the live scan,
   the module warm-up and profile loading happen in the `Loaded` → `BeginInvoke(Background)`
   callback, after the window has painted. Keep new startup work there.

### Key conventions to preserve when editing

- **Security model (see `SECURITY.md`).** The app runs elevated, so: it must only be installed where
  normal users can't write (Program Files; the app warns via `$script:LocationWarning` otherwise);
  everything in `%APPDATA%\NetworkControlCenter` and every UI value is untrusted input. Elevated
  workers take an **interface index** and resolve the adapter name and VLAN driver keyword live
  (`Invoke-ConfigTransaction`, `Invoke-AdapterAction`) — never pass names/keywords from the UI or
  cache into them (a test checks their parameter lists). Job scripts stay constant strings with
  parameters; never interpolate user input into `-Script`.
- **Public repo hygiene.** No real MACs, hostnames, internal IPs or emails in code, tests or commit
  messages (use RFC 5737 / private-range examples and dummy MACs like `00-1A-2B-3C-4D-5E`).
  `*.json`, logs and backups are gitignored because profiles/caches hold real site data.
- **Identity.** The repo belongs to the GitHub account **cesariluca**; commits are
  `cesariluca <luca.cesari@omniaccess.com>` (work email on purpose - don't switch to a no-reply address).

- **The UI thread never calls networking cmdlets** (module import would freeze it for seconds) and
  never does blocking network I/O — go through `Start-WorkJob`. Raw CIM reads belong in the worker
  too.
- **Validate everything before touching the adapter** — `btnApply` runs `Test-ConfigInput`,
  `Resolve-VlanId` and the in-memory duplicate-IP check before starting the job.
- **IP changes go through `Start-ConfigChange` → `Invoke-ConfigTransaction`** (rollback, change log,
  undo snapshot). The undo snapshot is the transaction's fresh `Before`, with VLAN fields copied
  from the adapter object; after a successful `Set-Vlan` the new value is written into
  `$script:VlanCache` immediately.
- **Worker functions are self-contained**: no `$ctl`, `$window` or `$script:` (a test enforces it).
- **VLAN is tri-state** (`VlanSupported` `$null` = not scanned yet) and only `Update-VlanFields`
  touches the VLAN controls.
- **Errors go to the status bar** (`Set-Status $msg 'ok'|'warn'|'err'`; it collapses multi-line CIM
  messages). Popups are only for confirmations (`Confirm-Action`: disable adapter, delete/overwrite
  profile, discard edits, close during a change) and file pickers.
- **Never pipe a `[void]` cast** (`[void]$x.M() | Out-Null` is a runtime error).
- **Profiles are flat plain data (`Name/Mode/IP/Prefix/Gateway/Dns1/Dns2/Mtu/Vlan`)**; new fields must
  keep that shape and be handled in `ConvertTo-NccProfile`.
