#Requires -Version 5.1
<#
.SYNOPSIS
    Headless Golden Image application update orchestrator (Nerdio Scripted Actions / Datto RMM).
.DESCRIPTION
    Discovers modules under Modules\, runs Invoke-AppUpdate for each installed app, verifies with
    Test-UpdateSuccess, suppresses reboots and aggregates them.
    Exit codes: 0 = success, 3010 = success + reboot required, 1 = one or more modules failed
    (failure takes precedence over 3010 so the failure is visible to the RMM).
.PARAMETER IncludeOnly
    Run only modules whose name matches (-like, case-insensitive) one of these values.
.PARAMETER Exclude
    Skip modules whose name matches one of these values.
.PARAMETER Simulate
    Alias -WhatIf. Detects and simulates; makes no system changes.
#>
[CmdletBinding()]
param(
    [string[]]$IncludeOnly,
    [string[]]$Exclude,
    [Alias('WhatIf')][switch]$Simulate,
    [string]$ConfigPath,
    [string]$ModulesPath,
    [string]$LogDirectory
)

$ErrorActionPreference = 'Stop'
$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # $PSScriptRoot can be empty in param defaults on PS 5.1
if (-not $ConfigPath)  { $ConfigPath  = Join-Path $RootDir 'config.json' }
if (-not $ModulesPath) { $ModulesPath = Join-Path $RootDir 'Modules' }
$exitCode = 0
$results = New-Object System.Collections.ArrayList

try {
    # --- Config -----------------------------------------------------------------------------
    $config = [pscustomobject]@{
        LogDirectory = 'C:\ProgramData\GoldenImageUpdater\Logs'; FallbackLogDirectory = 'Logs'
        LogRetentionDays = 30; WinGetTimeoutSeconds = 300; EnableGlobalMsiLogging = $true; DisabledModules = @()
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        $loaded = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        foreach ($p in $loaded.PSObject.Properties) { $config | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
    }
    if ($config.WinGetTimeoutSeconds) { $env:GIU_WINGET_TIMEOUT_SECONDS = [string]$config.WinGetTimeoutSeconds }
    if ($LogDirectory) { $config.LogDirectory = $LogDirectory }
    $fallback = $config.FallbackLogDirectory
    if ($fallback -and -not [IO.Path]::IsPathRooted($fallback)) { $fallback = Join-Path $RootDir $fallback }

    # Ensure vendored modules are discoverable via $env:PSModulePath
    $vendorDir = Join-Path $RootDir 'Vendor'
    if (Test-Path -LiteralPath $vendorDir) {
        if ($env:PSModulePath -notlike "*$vendorDir*") {
            $env:PSModulePath = "$vendorDir;$($env:PSModulePath)"
        }
    }

    # --- Core -------------------------------------------------------------------------------
    foreach ($m in 'Logging', 'ProcessHelper', 'WinGetWrapper', 'ModuleLoader') {
        Import-Module (Join-Path $RootDir "Core\$m.psm1") -Force -Global -DisableNameChecking
    }
    $logFile = Initialize-Log -Directory $config.LogDirectory -FallbackDirectory $fallback
    Remove-OldLog -Directory (Split-Path $logFile -Parent) -RetentionDays ([int]$config.LogRetentionDays)
    if ($config.EnableGlobalMsiLogging -and -not $Simulate) {
        if (Enable-GlobalMsiLogging) { Write-Log "Windows Installer system-wide verbose logging policy enabled (HKLM)." -Level DEBUG }
    }

    $mode = if ($Simulate) { 'SIMULATE (no changes)' } else { 'LIVE' }
    Write-Log "Golden Image Updater starting. Mode=$mode Host=$env:COMPUTERNAME SYSTEM=$(Test-IsSystemContext) PS=$($PSVersionTable.PSVersion)"
    Write-Log "Log file: $logFile"
    if ($IncludeOnly) { Write-Log "IncludeOnly: $($IncludeOnly -join ', ')" }
    if ($Exclude)     { Write-Log "Exclude: $($Exclude -join ', ')" }

    # --- Discover ---------------------------------------------------------------------------
    $descriptors = @(Get-AppModuleFile -ModulesRoot $ModulesPath | ForEach-Object { Import-AppModule -File $_ })
    $ordered = Get-AppModuleOrder -Descriptors $descriptors
    Write-Log "Discovered $($ordered.Count) module(s)."

    function Test-NameMatch([string]$Name, [string[]]$Patterns) {
        foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
        return $false
    }

    foreach ($d in $ordered) {
        $row = [ordered]@{ Application = $d.Name; Installed = '-'; Before = ''; After = ''; Status = ''; Reboot = 'No'; Message = '' }
        $reboot = $false
        try {
            if ($d.Error) { $row.Status = 'Failed'; $row.Message = $d.Error; Write-Log "[$($d.Name)] load error: $($d.Error)" -Level ERROR; continue }
            if ($IncludeOnly -and -not (Test-NameMatch $d.Name $IncludeOnly)) { $row.Status = 'Skipped'; $row.Message = 'Not in IncludeOnly'; continue }
            if ($Exclude -and (Test-NameMatch $d.Name $Exclude) -or (Test-NameMatch $d.Name @($config.DisabledModules))) {
                $row.Status = 'Skipped'; $row.Message = 'Excluded'; continue
            }
            $cmd = $d.Module.ExportedCommands
            $installed = [bool](& $cmd['Test-AppInstalled'])
            $row.Installed = if ($installed) { 'Yes' } else { 'No' }
            if (-not $installed) { $row.Status = 'NotInstalled'; Write-Log "[$($d.Name)] not installed; skipping."; continue }

            $row.Before = [string](& $cmd['Get-AppVersion'])
            Write-Log "[$($d.Name)] installed, version '$($row.Before)'. Updating..."
            $r = & $cmd['Invoke-AppUpdate'] -Simulate:$Simulate
            $r = @($r) | Where-Object { $_ -and $_.PSObject.Properties['Success'] } | Select-Object -Last 1
            if (-not $r) { throw 'Invoke-AppUpdate returned no result object.' }
            $row.Message = [string]$r.Message
            $reboot = [bool]$r.RebootRequired

            if (-not $r.Success) {
                $row.Status = 'Failed'
            } elseif ($Simulate) {
                $row.Status = 'Simulated'
            } else {
                $row.After = [string](& $cmd['Get-AppVersion'])
                if ([bool](& $cmd['Test-UpdateSuccess'])) { $row.Status = 'Updated' }
                else {
                    $row.Status = 'Failed'
                    $expected = if ($r.TargetVersion) { " (installed: '$($row.After)', target: '$($r.TargetVersion)')" } else { '' }
                    $row.Message = "Verification failed$expected. $($row.Message)"
                }
            }
            Write-Log "[$($d.Name)] $($row.Status): $($row.Message)" -Level $(if ($row.Status -eq 'Failed') { 'ERROR' } else { 'INFO' })
        } catch {
            $row.Status = 'Failed'; $row.Message = $_.Exception.Message
            Write-Log "[$($d.Name)] unhandled exception: $($_.Exception.Message)" -Level ERROR
            Write-Log $_.ScriptStackTrace -Level DEBUG
        } finally {
            if ($reboot -and $row.Status -ne 'Failed') { $row.Reboot = 'Yes' }
            if ($row.Status) { [void]$results.Add([pscustomobject]$row) }
        }
    }

    # --- Desktop Shortcuts Sweep ------------------------------------------------------------
    if ($config.OrganizeDesktopShortcuts -and -not $Simulate) {
        $subFolder = if ($config.DesktopShortcutsSubFolder) { $config.DesktopShortcutsSubFolder } else { 'Applications' }
        $patterns = if ($config.BrowserShortcutPatterns) { @($config.BrowserShortcutPatterns) } else { @('Google Chrome*', 'Microsoft Edge*', 'Firefox*', 'Mozilla Firefox*') }
        $movedCount = Move-DesktopShortcut -Pattern $patterns -SubFolder $subFolder
        if ($movedCount -gt 0) {
            Write-Log "Organized $movedCount desktop shortcut(s) into 'C:\Users\Public\Desktop\$subFolder'."
        }
    }

    # --- Summary ----------------------------------------------------------------------------
    $anyFailed = @($results | Where-Object Status -eq 'Failed').Count -gt 0
    $anyReboot = @($results | Where-Object Reboot -eq 'Yes').Count -gt 0
    $table = ($results | Format-Table Application, Installed, Before, After, Status, Reboot, Message -AutoSize -Wrap | Out-String -Width 220).TrimEnd()
    $counts = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Log 'SUMMARY'
    Write-Host $table
    if ($logFile) { Add-Content -LiteralPath $logFile -Value $table -Encoding UTF8 }
    Write-Log ("Totals: {0}; RebootRequired={1}" -f ($counts -join ' '), $anyReboot)

    if ($anyFailed) { $exitCode = 1 } elseif ($anyReboot -and -not $Simulate) { $exitCode = 3010 } else { $exitCode = 0 }
    Write-Log "Exiting with code $exitCode."
} catch {
    Write-Host "FATAL: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    try { Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR } catch { }
    $exitCode = 1
}
exit $exitCode
