# Network Control Center

A fast, native Windows app for field engineers who keep re-addressing their laptop to talk to
modems, routers and lab gear. Your laptop is on screen with its connections around it — wired on
the left, wireless on the right. Click one, type (or pick) the settings, **Apply**. One UAC prompt
per session, no digging through `ncpa.cpl`.

Single PowerShell + WPF script: nothing to install beyond what ships with Windows.

## Features

- **Visual overview** — the laptop with its Ethernet / USB-dock ports, Wi-Fi and cellular, each
  showing link state, speed and current IP. VPN, Hyper-V and Bluetooth adapters are one toggle away.
- **Easy addressing**
  - *Connecting to a device?* Type the device's IP (e.g. `192.168.1.1`) and the app fills in your
    IP (`192.168.1.10`), mask and gateway.
  - Subnet mask, DNS and MTU are pick-or-type lists (`/24  255.255.255.0  254 hosts`,
    `8.8.8.8 Google`, `1492 PPPoE`, ...).
  - Live subnet line under the fields: network, mask, usable range, host count.
  - *Suggest* fills the gateway with the subnet's first address.
  - Mistakes are shown as you type (gateway outside the subnet, broadcast address, IP already on
    another adapter, ...) and **Apply** stays disabled until the form is valid.
- **Profiles** — one-click chips (e.g. *"Newtec MDM5000 - Mgmt"*); save the current form as a
  profile, import/export them as JSON to share with the team.
- **Safety net**
  - Nothing is changed unless every field is valid.
  - If Windows rejects a change halfway, the previous settings are **restored automatically**.
  - **Undo last change** puts back the settings from before your last change.
  - Every change is written to `changes.log`, so you can tell afterwards what was set on site.
- **Fast** — the adapters from last time appear instantly (greyed out, marked *last known*) while
  fresh data loads in the background, about a second later; all network work runs in the
  background so the window never freezes.
- **Fits any laptop screen** — the window sizes itself to the screen and the laptop view scales down.
- **Field tools** — ping (with loss/latency), renew DHCP, flush DNS, clear the ARP cache,
  enable/disable/restart the adapter, copy its configuration for tickets and reports.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in — PowerShell 7 / `pwsh` is **not** supported)
- Administrator rights (asked once per session via UAC)

## Install (recommended) — one click from the taskbar

1. Download the ZIP from the [latest release](../../releases/latest) (or clone the repository).
   Optionally compare the ZIP's SHA-256 with the one in the release notes
   (`Get-FileHash .\NetworkControlCenter-*.zip`). Then unblock and extract it:
   ```powershell
   Unblock-File .\NetworkControlCenter-*.zip
   ```
2. Double-click **`Install.cmd`** and approve the UAC prompt. It installs the app to
   `C:\Program Files\NetworkControlCenter`, adds a *Network Control Center* entry to the Start menu
   and starts the app.
3. While it's open: right-click its taskbar icon → **Pin to taskbar**.
   (Windows doesn't allow programs to pin themselves; this is a one-time click.)

From then on, one click on the taskbar icon → UAC prompt → app. The UAC prompt names
*Console Window Host*: that is the hidden launcher that keeps a console window from appearing.

Why Program Files: the app runs as administrator, so it must live where only administrators can
change it - see [SECURITY.md](SECURITY.md).

- Desktop shortcut too: `Install.cmd -Desktop`
- Update: replace the files and run `Install.cmd` again (profiles and log are kept). Installs made by
  older versions (per user, in `%LOCALAPPDATA%`) are removed and a pinned icon is moved over.
- Remove: `powershell -ExecutionPolicy Bypass -File .\Install-Shortcut.ps1 -Uninstall`

## Run without installing

For a quick try or development. The app shows a warning in its status bar when it runs from a folder
other programs could modify. Double-click **`Launch Network Control Center.cmd`**, or:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\NetworkControlCenter.ps1
```

## Using it

1. Click a connection on the home screen.
2. Choose **Automatic (DHCP)** or **Manual (static)**. For manual, either type the device's IP in
   the blue *Connecting to a device?* box and click **Fill in**, click a **profile**, or type the fields.
3. Click **Apply changes**. The status bar at the bottom says exactly what happened.

The adapter page: action icons along the top, profiles / IP settings / ping test in the middle,
and the rarely needed settings (MTU, VLAN, additional IPs) plus hardware details on the right.

| Where | Action | What it does |
| --- | --- | --- |
| Bottom bar | Apply changes | Validates, then applies IP/DNS (+ MTU and VLAN if changed). Rolls back automatically on failure. |
| Bottom bar | Undo last change | Restores the adapter as it was before the last Apply / DHCP switch. |
| Bottom bar | Discard edits | Throws away your edits and shows the adapter's current settings. |
| Top icons | DHCP now | Switches to DHCP immediately. |
| Top icons | Renew | `ipconfig /renew`, and tells you if no DHCP server answered. |
| Top icons | Restart / Disable / Enable | Bounce or switch the NIC. |
| Top icons | Copy info | Text summary (IP, mask, gateway, DNS, MAC, ...) to the clipboard. |
| Profiles | Save current | Saves the form as a profile (also Import / Export to share). |
| Test connection | Ping | Pre-filled with the gateway (or the device after *Fill in*); type any target. |
| Home | Ping | Pre-filled with your default gateway; type anything else to ping that instead. |
| Home | Flush DNS / Clear ARP / Log & data | DNS cache, ARP cache, and the folder with profiles + change log. |

Keys: **F5** rescans, **Esc** goes back (or closes the profile-name box), **Enter** in the device /
ping / profile boxes triggers the button next to it.

**Additional IPs** (*Advanced*, right side) are added as "skip as source", so you can reach a second subnet
while outbound traffic keeps using the primary address.

**Careful:** changing the adapter you're currently connected *through* (e.g. remote desktop over
that NIC) drops your session — that's Windows, not the app.

### VLAN IDs

Windows has no native 802.1Q tagging; it depends on the NIC driver exposing a **VLAN ID**
setting. The app checks this in the background and enables the field only when the driver
supports it. Many laptop NICs (e.g. Intel I219, which only has a *"Packet Priority & VLAN"*
on/off switch) don't — use a Hyper-V external switch, the vendor utility (Intel PROSet / ANS),
or a switch access port instead.

## Where data is stored

Everything lives in `%APPDATA%\NetworkControlCenter` (**Data folder & log** on the home screen):

| File | Contents |
| --- | --- |
| `profiles.json` | Your profiles. Seeded with a few examples on first run. Safe to hand-edit. |
| `changes.log` | Timestamped log of every change (rotates to `changes.log.1` at 1 MB). |
| `adapter-cache.json` | Last adapter list, for the instant start. Safe to delete. |

If `profiles.json` ever becomes unreadable it is backed up as `profiles.json.corrupt-<date>.bak`
before defaults are loaded — your data is never silently thrown away.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Nothing appears after the UAC prompt | Run the `powershell.exe ... -File` command above from a console to see the error. |
| "Running scripts is disabled on this system" | Use `Install.cmd` / the launcher; they bypass the policy for this app only. |
| VLAN field is greyed out | The NIC driver has no VLAN ID setting — see [VLAN IDs](#vlan-ids). |
| "... is already set on ..." | The same IP is on another adapter (often a dock NIC). Change it there first. |
| Renew says no DHCP server answered | The device on the other end isn't serving DHCP — use a static IP / profile. |
| The adapter list looks out of date | It's refreshed automatically a second after start; press **F5** to rescan. |
| Status bar says "Running from ... run Install.cmd" | You started a copy outside Program Files. Fine for testing; install it for daily use. |
| Pinned icon stopped working after an update | Unpin it, start the app from the Start menu and pin it again. |

## Security

The app runs as administrator; see [SECURITY.md](SECURITY.md) for how it is protected, what to
watch out for, and how to report a vulnerability privately.

## Development

The whole app is `NetworkControlCenter.ps1`; `Install-Shortcut.ps1` installs it.
Offline tests (no admin, no network changes) cover validation, subnet math, quick-fill, adapter
classification, VLAN detection, profile storage, the background runspaces and the XAML wiring:

```bash
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
```

See `CLAUDE.md` for the architecture notes.

## License

[MIT](LICENSE)
