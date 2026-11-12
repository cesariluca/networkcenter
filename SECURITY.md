# Security policy

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them privately through GitHub:
**Security → Report a vulnerability** on this repository. You'll get a reply as soon as possible,
and a fix and advisory will be published once the issue is understood.

Only the latest release is supported.

## Why this app needs administrator rights

Changing IP addresses, DNS servers, MTU or VLAN settings on Windows requires administrator rights,
so Network Control Center always runs elevated (one UAC prompt per session). That shapes how it is
built and installed:

- **Install it with `Install.cmd`.** It puts the app in `C:\Program Files\NetworkControlCenter` and the
  shortcut in the all-users Start menu - places only administrators can change. If the app ran from
  a folder a normal user can write to (Downloads, Documents, a cloned repo), any program running as
  that user could replace the script and have it executed with administrator rights the next time
  you approve the UAC prompt. The app shows a warning in its status bar when it is started from such
  a folder.
- **The UAC prompt names "Console Window Host".** That is `conhost.exe --headless`, used so no
  console window appears. Only approve it when you have just clicked the Network Control Center icon.
- **Everything typed into the app or read from its files is validated** before it reaches Windows:
  IP addresses, masks, gateways, DNS servers, MTU, VLAN IDs and imported profiles. The elevated
  background workers identify an adapter only by its interface number and read its name and driver
  settings live, rather than trusting values from the user-writable files in
  `%APPDATA%\NetworkControlCenter` (profiles, adapter cache, change log).
- **No network access** beyond what you ask for (ping), no telemetry, no downloads, no third-party
  dependencies - only components that ship with Windows.

## Residual risks

- A shortcut pinned to the taskbar is a file in your user profile. Malware already running as you
  could edit it to launch something else through the same UAC prompt. This is true of any pinned
  "run as administrator" shortcut; the UAC prompt is the last line of defence.
- `profiles.json` and `changes.log` contain IP addresses of the networks you configured. They stay
  on your machine; be mindful before sharing exported profiles.
