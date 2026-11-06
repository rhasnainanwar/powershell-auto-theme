# PowerShell Auto Theme

Automatically switch your Windows Terminal color scheme between a light theme during the day and a dark theme at night, based on the real sunrise and sunset times where you live. No restart needed: open terminal tabs change instantly.

If you use the [GitHub Copilot CLI](https://github.com/github/copilot-cli), running sessions are switched to a matching Copilot theme too, without restarting them.

| | Default color scheme | Default Copilot CLI theme |
|---|---|---|
| ☀️ Day (sunrise → 30 min after sunset) | One Half Light | `github` |
| 🌙 Night (30 min after sunset → sunrise) | Vintage | `default` |

Everything (schemes, themes, offsets, profiles) can be changed in `config.json`.

## Requirements

- Windows 10 or 11 with [Windows Terminal](https://github.com/microsoft/terminal)
- [PowerShell 7+](https://github.com/PowerShell/PowerShell) (`pwsh`)
- Optional: GitHub Copilot CLI

No admin rights, internet access, or location services are needed. Sun times are calculated locally.

## Quick start

1. **Download** this repository to a permanent folder, for example `C:\Tools\powershell-auto-theme`. The scheduled task runs the script from this folder, so don't delete it. Either use Code → Download ZIP, or:

   ```powershell
   git clone https://github.com/rhasnainanwar/powershell-auto-theme.git C:\Tools\powershell-auto-theme
   ```

2. **Find your coordinates.** Search "my latitude and longitude" or use [latlong.net](https://www.latlong.net). Use decimal degrees; south and west are negative (for example London is `51.5074`, `-0.1278`).

3. **Install** from a PowerShell 7 window:

   ```powershell
   cd C:\Tools\powershell-auto-theme
   Get-ChildItem | Unblock-File
   .\TerminalAutoTheme.ps1 -Install -Latitude 51.5074 -Longitude -0.1278
   ```

That's it. The right scheme is applied immediately, and a hidden scheduled task keeps it in sync from then on.

## Everyday commands

| Command | What it does |
|---|---|
| `.\TerminalAutoTheme.ps1 -Status` | Show today's sunrise/sunset, current mode, and task status |
| `.\TerminalAutoTheme.ps1` | Apply the correct scheme for the current time |
| `.\TerminalAutoTheme.ps1 -Mode Day` (or `Night`) | Force a mode now; the next scheduled switch goes back to automatic |
| `.\TerminalAutoTheme.ps1 -RefreshCopilot` | Re-sync running Copilot CLI sessions with the terminal colors |
| `.\TerminalAutoTheme.ps1 -Install -Latitude <lat> -Longitude <lon>` | Change your location (safe to re-run) |
| `.\TerminalAutoTheme.ps1 -Uninstall` | Remove the scheduled task |

## Customize

`config.json` is created on install. Edit it, then run `.\TerminalAutoTheme.ps1` to apply your changes.

| Setting | Default | Description |
|---|---|---|
| `latitude`, `longitude` | set by `-Install` | Your location in decimal degrees |
| `dayScheme`, `nightScheme` | `One Half Light`, `Vintage` | Any color scheme name from Windows Terminal (Settings → Color schemes) |
| `sunriseOffsetMinutes` | `0` | Minutes after sunrise to switch to day (negative = before) |
| `sunsetOffsetMinutes` | `30` | Minutes after sunset to switch to night (negative = before) |
| `profiles` | PowerShell 7 profile | Windows Terminal profile names or GUIDs to switch, for example `["PowerShell", "Ubuntu"]` |
| `copilot.enabled` | `true` | Set to `false` if you don't use the Copilot CLI |
| `copilot.dayTheme`, `copilot.nightTheme` | `github`, `default` | Copilot CLI theme for each mode (same names as `/settings theme <name>`) |
| `copilot.maxWaitMinutes` | `15` | How long to wait for you to finish typing before refreshing a Copilot session |
| `copilot.settleSeconds` | `4` | Pause between steps; increase it if Copilot ends up with the wrong light or dark background |

## How it works

- **Sun times** are computed with the NOAA solar equations (accurate to about a minute), including polar day and night.
- **Switching** edits only the `colorScheme` of the chosen profiles in Windows Terminal's `settings.json`. Comments and formatting are preserved, and the file is validated before it is saved. Windows Terminal reloads it automatically. A copy of your original settings is saved to `settings.json.backup` on first install.
- **Scheduling** uses a hidden scheduled task named `TerminalAutoTheme`. It runs at the exact switch time, at logon, when you unlock your PC, and hourly as a safety net.
- **Copilot CLI** only reads the terminal colors when it starts or when its theme changes away from `github`. To pick up the new colors, the script types `/settings theme ...` commands into each running Copilot session inside Windows Terminal. It waits if you have unsent text in the input box or a dialog open, so it never interferes with what you're typing.

Activity is logged to `TerminalAutoTheme.log` in the script folder.

## Troubleshooting

- **Nothing changes:** run `.\TerminalAutoTheme.ps1 -Status` and check that `TerminalSchemes` lists your profile. If it says the profile was not found, add its name to `profiles` in `config.json`.
- **"Running scripts is disabled":** run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, or use `Unblock-File` as shown in Quick start.
- **Copilot colors look wrong:** run `.\TerminalAutoTheme.ps1 -RefreshCopilot`. If this happens often, increase `copilot.settleSeconds`.
- **Wrong switch times:** check your coordinates and Windows time zone with `-Status`.

## Uninstall

```powershell
.\TerminalAutoTheme.ps1 -Uninstall
```

Then delete the folder. To restore your original Windows Terminal settings, copy `settings.json.backup` back over Windows Terminal's `settings.json`.

## License

[MIT](LICENSE)
