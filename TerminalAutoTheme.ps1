#Requires -Version 7.0
<#
.SYNOPSIS
    Switches the Windows Terminal color scheme of selected profiles between a day and a night scheme
    based on local sunrise/sunset, and refreshes running GitHub Copilot CLI sessions so they pick up
    the new terminal palette without restarting the shell or Copilot.

.EXAMPLE
    .\TerminalAutoTheme.ps1 -Install -Latitude 51.5074 -Longitude -0.1278
    .\TerminalAutoTheme.ps1 -Status
    .\TerminalAutoTheme.ps1                 # apply the scheme for the current time
    .\TerminalAutoTheme.ps1 -Mode Night     # force a scheme now (the next scheduled switch restores auto)
    .\TerminalAutoTheme.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Install', Mandatory)] [switch]$Install,
    [Parameter(ParameterSetName = 'Install')] [ValidateRange(-90, 90)] [double]$Latitude = [double]::NaN,
    [Parameter(ParameterSetName = 'Install')] [ValidateRange(-180, 180)] [double]$Longitude = [double]::NaN,
    [Parameter(ParameterSetName = 'Uninstall', Mandatory)] [switch]$Uninstall,
    [Parameter(ParameterSetName = 'Status', Mandatory)] [switch]$Status,
    [Parameter(ParameterSetName = 'Apply')] [ValidateSet('Auto', 'Day', 'Night')] [string]$Mode = 'Auto',
    [Parameter(ParameterSetName = 'Apply')] [switch]$RefreshCopilot,
    [Parameter(ParameterSetName = 'Worker', Mandatory, DontShow)] [switch]$CopilotWorker,
    [Parameter(ParameterSetName = 'Worker', Mandatory, DontShow)] [string]$CopilotTheme
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$ConfigPath = Join-Path $Root 'config.json'
$LogPath = Join-Path $Root 'TerminalAutoTheme.log'
$TaskName = 'TerminalAutoTheme'

#region Utilities

function Write-Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $PID, $Message
    try {
        Add-Content -Path $LogPath -Value $line -Encoding utf8
        $lines = Get-Content $LogPath
        if ($lines.Count -gt 2000) { $lines | Select-Object -Last 1000 | Set-Content $LogPath -Encoding utf8 }
    } catch { }
    if ($PSCmdlet.ParameterSetName -ne 'Worker') { Write-Verbose $line }
}

function Get-DefaultConfig {
    [ordered]@{
        # Set with -Install -Latitude <lat> -Longitude <lon> (decimal degrees; south and west are negative).
        latitude              = $null
        longitude             = $null
        dayScheme             = 'One Half Light'
        nightScheme           = 'Vintage'
        sunriseOffsetMinutes  = 0
        sunsetOffsetMinutes   = 30
        # Windows Terminal profile GUIDs or names to switch.
        profiles              = @('{574e775e-4f2a-5b96-ac1e-a2962a402336}')
        copilot               = [ordered]@{
            enabled                = $true
            # Copilot theme for each mode (same as running `/settings theme <name>`).
            dayTheme               = 'github'
            nightTheme             = 'default'
            processNames           = @('copilot')
            # Only sessions running inside Windows Terminal are affected by its color scheme.
            requireWindowsTerminal = $true
            # How long to wait for an unsent draft in the Copilot input box to be cleared before giving up.
            maxWaitMinutes         = 15
            # Pause for Windows Terminal to reload its settings and for Copilot to re-read the palette.
            settleSeconds          = 4
        }
    }
}

function Get-Config {
    $config = Get-DefaultConfig
    if (Test-Path $ConfigPath) {
        $saved = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
        foreach ($key in $saved.Keys) {
            if ($saved[$key] -is [System.Collections.IDictionary] -and $config[$key] -is [System.Collections.IDictionary]) {
                foreach ($sub in $saved[$key].Keys) { $config[$key][$sub] = $saved[$key][$sub] }
            } else { $config[$key] = $saved[$key] }
        }
    }
    $config
}

function Save-Config($Config) {
    $Config | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding utf8
}

#endregion

#region Sun schedule

# NOAA general solar position approximation (accurate to about a minute). Returns local DateTimes,
# or $null for the event that does not happen on that day (polar day/night).
function Get-SunTimes([datetime]$Date, [double]$Lat, [double]$Lon) {
    $deg = [Math]::PI / 180
    $day = $Date.Date
    $gamma = 2 * [Math]::PI / (365 + [int][datetime]::IsLeapYear($day.Year)) * ($day.DayOfYear - 1)
    $eqTime = 229.18 * (0.000075 + 0.001868 * [Math]::Cos($gamma) - 0.032077 * [Math]::Sin($gamma) -
        0.014615 * [Math]::Cos(2 * $gamma) - 0.040849 * [Math]::Sin(2 * $gamma))
    $decl = 0.006918 - 0.399912 * [Math]::Cos($gamma) + 0.070257 * [Math]::Sin($gamma) -
        0.006758 * [Math]::Cos(2 * $gamma) + 0.000907 * [Math]::Sin(2 * $gamma) -
        0.002697 * [Math]::Cos(3 * $gamma) + 0.00148 * [Math]::Sin(3 * $gamma)
    $cosHa = [Math]::Cos(90.833 * $deg) / ([Math]::Cos($Lat * $deg) * [Math]::Cos($decl)) - [Math]::Tan($Lat * $deg) * [Math]::Tan($decl)
    if ($cosHa -gt 1) { return @{ Sunrise = $null; Sunset = $null; Polar = 'Night' } }
    if ($cosHa -lt -1) { return @{ Sunrise = $null; Sunset = $null; Polar = 'Day' } }
    $ha = [Math]::Acos($cosHa) / $deg
    # Minutes from UTC midnight of the local calendar date; the offset of local time can push events across UTC midnight.
    $utcMidnight = [datetime]::SpecifyKind($day, [DateTimeKind]::Utc)
    $toLocal = { param($minutes) [TimeZoneInfo]::ConvertTimeFromUtc($utcMidnight.AddMinutes($minutes), [TimeZoneInfo]::Local) }
    $sunrise = & $toLocal (720 - 4 * ($Lon + $ha) - $eqTime)
    $sunset = & $toLocal (720 - 4 * ($Lon - $ha) - $eqTime)
    # Correct for longitudes where the UTC-based calculation lands on the neighbouring local date.
    if ($sunrise.Date -ne $day) { $sunrise = $sunrise.AddDays(($day - $sunrise.Date).TotalDays) }
    if ($sunset.Date -ne $day -and $sunset -lt $sunrise) { $sunset = $sunset.AddDays(1) }
    @{ Sunrise = $sunrise; Sunset = $sunset; Polar = $null }
}

# Day window for a calendar date: [sunrise + sunriseOffset, sunset + sunsetOffset).
function Get-DayWindow([datetime]$Date, $Config) {
    $sun = Get-SunTimes $Date $Config.latitude $Config.longitude
    if ($sun.Polar) { return @{ Polar = $sun.Polar } }
    @{
        Polar      = $null
        Sunrise    = $sun.Sunrise
        Sunset     = $sun.Sunset
        DayStart   = $sun.Sunrise.AddMinutes($Config.sunriseOffsetMinutes)
        NightStart = $sun.Sunset.AddMinutes($Config.sunsetOffsetMinutes)
    }
}

function Get-ThemeSchedule([datetime]$Now, $Config) {
    if ($null -eq $Config.latitude -or $null -eq $Config.longitude) {
        throw 'Location is not set. Run: .\TerminalAutoTheme.ps1 -Install -Latitude <lat> -Longitude <lon>'
    }
    $today = Get-DayWindow $Now $Config
    if ($today.Polar) {
        return @{ Mode = $today.Polar; NextChange = $Now.Date.AddDays(1).AddMinutes(1); Today = $today }
    }
    if ($Now -lt $today.DayStart) { return @{ Mode = 'Night'; NextChange = $today.DayStart; Today = $today } }
    if ($Now -lt $today.NightStart) { return @{ Mode = 'Day'; NextChange = $today.NightStart; Today = $today } }
    $tomorrow = Get-DayWindow $Now.Date.AddDays(1) $Config
    $next = if ($tomorrow.Polar) { $Now.Date.AddDays(1).AddMinutes(1) } else { $tomorrow.DayStart }
    @{ Mode = 'Night'; NextChange = $next; Today = $today }
}

#endregion

#region Windows Terminal settings

function Get-WtSettingsPaths {
    @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    ) | Where-Object { Test-Path $_ }
}

# Minimal JSONC scanner: records every string token (with its innermost enclosing container) and
# every container's span, so a single value can be replaced without reformatting the file or losing comments.
function Get-JsoncTokens([string]$Text) {
    $strings = [System.Collections.Generic.List[object]]::new()
    $containers = @{}
    $stack = [System.Collections.Generic.Stack[int]]::new()
    $i = 0; $n = $Text.Length
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($c -eq '"') {
            $sb = [System.Text.StringBuilder]::new(); $j = $i + 1
            while ($j -lt $n -and $Text[$j] -ne '"') {
                if ($Text[$j] -eq '\') { [void]$sb.Append($Text[$j + 1]); $j += 2 } else { [void]$sb.Append($Text[$j]); $j++ }
            }
            $parent = if ($stack.Count) { $stack.Peek() } else { -1 }
            $strings.Add([pscustomobject]@{ Start = $i; End = $j + 1; Value = $sb.ToString(); Parent = $parent })
            $i = $j + 1; continue
        }
        if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '/') { $j = $Text.IndexOf("`n", $i); $i = if ($j -lt 0) { $n } else { $j }; continue }
        if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '*') { $j = $Text.IndexOf('*/', $i + 2); $i = if ($j -lt 0) { $n } else { $j + 2 }; continue }
        if ($c -eq '{' -or $c -eq '[') { $stack.Push($i) }
        elseif (($c -eq '}' -or $c -eq ']') -and $stack.Count) { $containers[$stack.Pop()] = $i + 1 }
        $i++
    }
    @{ Strings = $strings; Containers = $containers }
}

function Get-NextSignificantIndex([string]$Text, [int]$From) {
    $i = $From
    while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
    $i
}

function Find-JsoncProperty($Tokens, [string]$Text, [int]$ObjectStart, [string]$Key) {
    foreach ($s in $Tokens.Strings) {
        if ($s.Parent -ne $ObjectStart -or $s.Value -ne $Key) { continue }
        $colon = Get-NextSignificantIndex $Text $s.End
        if ($colon -ge $Text.Length -or $Text[$colon] -ne ':') { continue }
        $vStart = Get-NextSignificantIndex $Text ($colon + 1)
        $vEnd = if ($Text[$vStart] -eq '"') { ($Tokens.Strings | Where-Object Start -eq $vStart).End }
                elseif ($Tokens.Containers.ContainsKey($vStart)) { $Tokens.Containers[$vStart] }
                else { $k = $vStart; while ($k -lt $Text.Length -and $Text[$k] -notin ',', '}', "`n") { $k++ }; $k }
        return [pscustomobject]@{ KeyStart = $s.Start; ValueStart = $vStart; ValueEnd = $vEnd; Value = $Text.Substring($vStart, $vEnd - $vStart) }
    }
}

function Resolve-WtProfileGuids([string]$Text, $Profiles) {
    $list = @(($Text | ConvertFrom-Json).profiles.list)
    foreach ($p in $Profiles) {
        $match = $list | Where-Object { $_.guid -eq $p -or $_.name -eq $p } | Select-Object -First 1
        if ($match) { $match.guid } else { Write-Log "Windows Terminal profile '$p' not found" }
    }
}

# Sets the colorScheme of the given profiles; returns $true when the file was changed.
function Set-WtProfileScheme([string]$Path, $Profiles, [string]$Scheme) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [Text.UTF8Encoding]::new($false).GetString($bytes, ($hasBom ? 3 : 0), $bytes.Length - ($hasBom ? 3 : 0))
    $original = $text
    $schemeJson = $Scheme | ConvertTo-Json
    foreach ($guid in Resolve-WtProfileGuids $text $Profiles) {
        $tokens = Get-JsoncTokens $text
        $guidKey = $tokens.Strings | Where-Object { $_.Value -eq 'guid' } | ForEach-Object {
            $prop = Find-JsoncProperty $tokens $text $_.Parent 'guid'
            if ($prop -and ($prop.Value | ConvertFrom-Json) -eq $guid) { [pscustomobject]@{ Object = $_.Parent; Prop = $prop } }
        } | Select-Object -First 1
        if (-not $guidKey) { continue }
        $existing = Find-JsoncProperty $tokens $text $guidKey.Object 'colorScheme'
        if ($existing) {
            if ($existing.Value -eq $schemeJson) { continue }
            $text = $text.Remove($existing.ValueStart, $existing.ValueEnd - $existing.ValueStart).Insert($existing.ValueStart, $schemeJson)
        } else {
            $lineStart = $text.LastIndexOf("`n", $guidKey.Prop.KeyStart) + 1
            $indent = $text.Substring($lineStart, $guidKey.Prop.KeyStart - $lineStart)
            if ($indent.Trim()) { $indent = ' ' }
            $text = $text.Insert($guidKey.Prop.ValueEnd, ",`n$indent`"colorScheme`": $schemeJson")
        }
    }
    if ($text -ceq $original) { return $false }
    $null = $text | ConvertFrom-Json  # never write a file Windows Terminal cannot parse
    $out = [Text.UTF8Encoding]::new($hasBom).GetPreamble() + [Text.UTF8Encoding]::new($false).GetBytes($text)
    [IO.File]::WriteAllBytes($Path, $out)
    $true
}

function Get-WtProfileSchemes([string]$Path, $Profiles) {
    $json = Get-Content $Path -Raw | ConvertFrom-Json
    foreach ($p in $Profiles) {
        $prof = $json.profiles.list | Where-Object { $_.guid -eq $p -or $_.name -eq $p } | Select-Object -First 1
        $scheme = $prof.colorScheme ?? $json.profiles.defaults.colorScheme
        [pscustomobject]@{ Profile = $prof.name ?? $p; ColorScheme = $scheme }
    }
}

#endregion

#region Copilot CLI refresh

# Copilot CLI reads the terminal palette once at startup, and Windows Terminal does not send color-scheme
# change notifications. Switching the Copilot theme from `github` to another theme makes Copilot re-query
# the terminal colors, so the refresh first switches to an intermediate theme and then to the target theme.
function Get-CopilotSavedTheme {
    try { (Get-Content "$env:USERPROFILE\.copilot\settings.json" -Raw | ConvertFrom-Json).theme } catch { $null }
}

function Get-CopilotConsoleProcesses($Config) {
    $all = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name
    $byId = @{}; foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
    $names = $Config.copilot.processNames | ForEach-Object { "$_.exe" }
    foreach ($p in $all | Where-Object { $_.Name -in $names }) {
        $parent = $byId[[int]$p.ParentProcessId]
        if ($parent -and $parent.Name -in $names) { continue }  # child of another Copilot process in the same console
        $inWt = $false; $cur = $parent; $guard = 0
        while ($cur -and $guard++ -lt 32) {
            if ($cur.Name -eq 'WindowsTerminal.exe') { $inWt = $true; break }
            $cur = $byId[[int]$cur.ParentProcessId]
        }
        if ($Config.copilot.requireWindowsTerminal -and -not $inWt) { continue }
        [int]$p.ProcessId
    }
}

# Inspects the Copilot input box on screen: 'Empty', 'Draft' (user has unsent text) or 'Unknown'
# (no input box visible, e.g. a dialog is open).
function Get-CopilotInputState([int]$ProcessId) {
    $rows = [TerminalAutoTheme.ConsoleInput]::ReadScreen($ProcessId)
    $bottom = -1
    for ($i = $rows.Count - 1; $i -ge 0; $i--) { if ($rows[$i].StartsWith([char]0x2579)) { $bottom = $i; break } }
    if ($bottom -lt 0) { return 'Unknown' }
    $top = -1
    for ($i = $bottom - 1; $i -ge 0; $i--) { if ($rows[$i].StartsWith([char]0x257B)) { $top = $i; break } }
    if ($top -lt 0) { return 'Unknown' }
    $draft = ($rows[($top + 1)..($bottom - 1)] | ForEach-Object { $_.TrimStart([char]0x2503).Trim() }) -join ''
    if ($draft) { 'Draft' } else { 'Empty' }
}

function Send-CopilotCommand([int]$ProcessId, [string]$Command) {
    [TerminalAutoTheme.ConsoleInput]::SendText($ProcessId, $Command)
    Start-Sleep -Milliseconds 400
    [TerminalAutoTheme.ConsoleInput]::SendEnter($ProcessId)
    Start-Sleep -Milliseconds 1500
}

function Invoke-CopilotWorker([string]$Theme) {
    $config = Get-Config
    # Runs detached from any user console (attaching to other consoles requires releasing our own).
    $mutex = [Threading.Mutex]::new($false, 'Local\TerminalAutoTheme.CopilotWorker')
    if (-not $mutex.WaitOne([TimeSpan]::FromMinutes($config.copilot.maxWaitMinutes + 1))) { Write-Log 'Another Copilot refresh is still running; skipping'; return }
    try {
        Add-Type -Path (Join-Path $Root 'ConsoleInput.cs')
        # Windows Terminal reloads settings.json asynchronously; querying colors too early returns the old scheme.
        Start-Sleep -Seconds $config.copilot.settleSeconds
        $theme = $Theme
        # Copilot re-queries the terminal palette only on a github -> non-github switch, so always pass through
        # that transition (whatever the current theme is); returning to `github` then derives light/dark from it.
        $steps = if ($theme -eq 'github') { 'github', 'default', 'github' } else { 'github', $theme }
        $pending = @{}
        foreach ($procId in Get-CopilotConsoleProcesses $config) {
            try {
                $consoleId = [TerminalAutoTheme.ConsoleInput]::GetConsoleId($procId)
                if (-not $pending.ContainsValue($consoleId)) { $pending[$procId] = $consoleId }
            } catch { Write-Log "Copilot pid $procId has no attachable console: $($_.Exception.Message)" }
        }
        if (-not $pending.Count) { Write-Log 'No Copilot CLI sessions to refresh'; return }
        $deadline = (Get-Date).AddMinutes($config.copilot.maxWaitMinutes)
        while ($pending.Count) {
            foreach ($procId in @($pending.Keys)) {
                try {
                    $state = Get-CopilotInputState $procId
                    if ($state -ne 'Empty') { continue }
                    for ($i = 0; $i -lt $steps.Count; $i++) {
                        # Let each switch (and its palette re-query) finish before the next one.
                        if ($i) { Start-Sleep -Seconds $config.copilot.settleSeconds }
                        Send-CopilotCommand $procId "/settings theme $($steps[$i])"
                    }
                    Write-Log "Refreshed Copilot CLI colors in pid $procId (theme: $theme)"
                    $pending.Remove($procId)
                } catch {
                    Write-Log "Copilot pid ${procId}: $($_.Exception.Message)"
                    $pending.Remove($procId)
                }
            }
            if (-not $pending.Count) { break }
            if ((Get-Date) -ge $deadline) { Write-Log "Gave up waiting for an empty input box in Copilot pid(s) $($pending.Keys -join ', ')"; break }
            Start-Sleep -Seconds 15
        }
    } finally { $mutex.ReleaseMutex() }
}

function Start-CopilotWorker([string]$Theme) {
    $pwsh = (Get-Process -Id $PID).Path
    # conhost --headless gives the worker a private, invisible console so it never touches the caller's console.
    Start-Process -FilePath "$env:WINDIR\System32\conhost.exe" -WindowStyle Hidden -ArgumentList @(
        '--headless', "`"$pwsh`"", '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"", '-CopilotWorker', '-CopilotTheme', $Theme)
}

#endregion

#region Scheduled task

function Get-TaskTriggers([datetime]$NextChange) {
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $unlockClass = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskSessionStateChangeTrigger
    $unlock = New-CimInstance -CimClass $unlockClass -ClientOnly -Property @{ StateChange = 8; UserId = $user; Enabled = $true }
    $hourly = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1)
    @(
        New-ScheduledTaskTrigger -Once -At $NextChange.AddSeconds(5)
        New-ScheduledTaskTrigger -AtLogOn -User $user
        $unlock
        $hourly  # safety net in case the exact trigger is missed
    )
}

function Register-ThemeTask([datetime]$NextChange) {
    $pwsh = (Get-Process -Id $PID).Path
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" -Argument (
        "--headless `"$pwsh`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`"")
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (Get-TaskTriggers $NextChange) -Settings $settings `
        -Principal $principal -Description 'Switches Windows Terminal day/night color scheme at sunrise/sunset and refreshes Copilot CLI colors.' -Force | Out-Null
}

function Update-TaskNextChange([datetime]$NextChange) {
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { return }
    Set-ScheduledTask -TaskName $TaskName -Trigger (Get-TaskTriggers $NextChange) | Out-Null
}

#endregion

function Invoke-Apply([string]$ForcedMode, [switch]$ForceCopilotRefresh) {
    $config = Get-Config
    $schedule = Get-ThemeSchedule (Get-Date) $config
    $mode = if ($ForcedMode -eq 'Auto') { $schedule.Mode } else { $ForcedMode }
    $scheme = if ($mode -eq 'Day') { $config.dayScheme } else { $config.nightScheme }
    $changed = $false
    foreach ($path in Get-WtSettingsPaths) {
        if (Set-WtProfileScheme $path $config.profiles $scheme) {
            $changed = $true
            Write-Log "Set Windows Terminal scheme '$scheme' ($mode) in $path"
        }
    }
    $copilotTheme = if ($mode -eq 'Day') { $config.copilot.dayTheme } else { $config.copilot.nightTheme }
    if ($config.copilot.enabled -and ($changed -or $ForceCopilotRefresh -or (Get-CopilotSavedTheme) -ne $copilotTheme)) {
        Start-CopilotWorker $copilotTheme
    }
    try { Update-TaskNextChange $schedule.NextChange } catch { Write-Log "Could not update scheduled task: $($_.Exception.Message)" }
    [pscustomobject]@{ Mode = $mode; Scheme = $scheme; CopilotTheme = $copilotTheme; Changed = $changed; NextChange = $schedule.NextChange }
}

function Show-Status {
    $config = Get-Config
    $s = Get-ThemeSchedule (Get-Date) $config
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $info = if ($task) { $task | Get-ScheduledTaskInfo }
    [pscustomobject]@{
        Location        = '{0}, {1}' -f $config.latitude, $config.longitude
        Sunrise         = $s.Today.Sunrise
        Sunset          = $s.Today.Sunset
        DayStarts       = $s.Today.DayStart
        NightStarts     = $s.Today.NightStart
        CurrentMode     = $s.Mode
        ExpectedScheme  = if ($s.Mode -eq 'Day') { $config.dayScheme } else { $config.nightScheme }
        NextChange      = $s.NextChange
        TerminalSchemes = (Get-WtSettingsPaths | ForEach-Object { Get-WtProfileSchemes $_ $config.profiles } |
            ForEach-Object { "$($_.Profile): $($_.ColorScheme)" }) -join '; '
        ExpectedCopilot = if ($s.Mode -eq 'Day') { $config.copilot.dayTheme } else { $config.copilot.nightTheme }
        CopilotTheme    = Get-CopilotSavedTheme
        Task            = if ($task) { "$($task.State); last run $($info.LastRunTime) (result $($info.LastTaskResult)); next run $($info.NextRunTime)" } else { 'not installed' }
    }
}

try {
    switch ($PSCmdlet.ParameterSetName) {
        'Install' {
            $config = Get-Config
            if (-not [double]::IsNaN($Latitude)) { $config.latitude = $Latitude }
            if (-not [double]::IsNaN($Longitude)) { $config.longitude = $Longitude }
            Save-Config $config
            $backup = Join-Path $Root 'settings.json.backup'
            $wtSettings = Get-WtSettingsPaths | Select-Object -First 1
            if (-not $wtSettings) { throw 'Windows Terminal settings.json was not found. Install Windows Terminal and open it once first.' }
            if (-not (Test-Path $backup)) { Copy-Item $wtSettings $backup }
            $result = Invoke-Apply 'Auto'
            Register-ThemeTask $result.NextChange
            Write-Log "Installed scheduled task '$TaskName'"
            Show-Status
        }
        'Uninstall' {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log "Removed scheduled task '$TaskName'"
            "Removed scheduled task '$TaskName'. Config and log remain in $Root."
        }
        'Status' { Show-Status }
        'Worker' { Invoke-CopilotWorker $CopilotTheme }
        default { Invoke-Apply $Mode -ForceCopilotRefresh:$RefreshCopilot }
    }
} catch {
    Write-Log "ERROR: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
    throw
}
