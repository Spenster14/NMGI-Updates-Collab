#Requires -Version 5.1
<#
    Thomson Reuters UltraTax CS Production Update Module
    Strategy:
      * Supports the last three supported tax years: 2023, 2024, and 2025.
      * Dynamic Architecture-Agnostic Shortcut Resolution:
        - Recursively scans 'C:\Users\Public\Desktop\Applications' and subfolders
          (e.g., 'Thomson Products\UltraTax') to extract authoritative target executable paths.
        - Dynamically supports both local disk installations (e.g., 'C:\WINCSI\UT24\utw24.exe')
          and network UNC/mapped shares (e.g., '\\bmctho1\thomson\UT23\UTW23.exe').
      * Autonomous CS Connect Execution:
        - Utilizes vendored AutoHotkey v2 + Microsoft UIAutomation (UIA) worker ('Update-UltraTax.ahk').
        - Handles upfront sign-in dialogs and dismisses startup bulletins ('User Bulletin',
          'Choose Data Location', 'User already present').
        - Navigates to CS Connect (Ctrl+K), triggers 'Connect', monitors Call Summary for updates,
          handles restart prompts, and cleanly cycles the application.
      * Desktop Organization:
        - Preserves / moves desktop shortcuts to 'Applications\Thomson Products\UltraTax'.
#>

$script:AppName = 'Thomson UltraTax CS'
$script:SupportedYears = @('23', '24', '25')

function Get-AppMetadata {
    [pscustomobject]@{
        Name      = $script:AppName
        DependsOn = @()
        Priority  = 110 # Tax suites execute after system runtimes, browsers, and Office suites
    }
}

function Get-UltraTaxTargets {
    <#
    .SYNOPSIS
        Discovers installed UltraTax CS executables for the target years (23, 24, 25)
        by scanning desktop shortcuts (local and UNC) and falling back to candidate paths.
    #>
    $searchRoots = @(
        'C:\Users\Public\Desktop\Applications',
        'C:\Users\Public\Desktop',
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('Desktop')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    $targets = [ordered]@{}
    $wsh = $null
    try {
        $wsh = New-Object -ComObject WScript.Shell
    } catch { }

    # 1. Authoritative desktop shortcuts (searched recursively in Applications)
    if ($wsh) {
        foreach ($root in $searchRoots) {
            $shortcuts = Get-ChildItem -Path $root -Filter "*.lnk" -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '(?i)UltraTax|UT' }

            foreach ($lnk in $shortcuts) {
                try {
                    $sc = $wsh.CreateShortcut($lnk.FullName)
                    $targetPath = [string]$sc.TargetPath
                    if ($targetPath -match '(?i)utw(\d{2})\.exe') {
                        $twoDigitYear = $Matches[1]
                        if ($twoDigitYear -in $script:SupportedYears) {
                            if (-not $targets.Contains($twoDigitYear)) {
                                $targets[$twoDigitYear] = [pscustomobject]@{
                                    Year         = "20$twoDigitYear"
                                    ShortYear    = $twoDigitYear
                                    Executable   = $targetPath
                                    ShortcutPath = $lnk.FullName
                                    Source       = 'Shortcut'
                                }
                            }
                        }
                    }
                } catch { }
            }
        }
    }

    # 2. Candidate local and mapped network fallback paths for missing years
    foreach ($yr in $script:SupportedYears) {
        if (-not $targets.Contains($yr)) {
            $candidates = @(
                "C:\WINCSI\UT$yr\utw$yr.exe",
                "C:\WinCSI\UT$yr\utw$yr.exe",
                "W:\WinCSI\UT$yr\utw$yr.exe",
                "W:\UT$yr\utw$yr.exe",
                "P:\WinCSI\UT$yr\utw$yr.exe",
                "S:\WinCSI\UT$yr\utw$yr.exe"
            )
            foreach ($cand in $candidates) {
                if (Test-Path -LiteralPath $cand) {
                    $targets[$yr] = [pscustomobject]@{
                        Year         = "20$yr"
                        ShortYear    = $yr
                        Executable   = $cand
                        ShortcutPath = $null
                        Source       = 'Filesystem'
                    }
                    break
                }
            }
        }
    }

    return $targets
}

function Test-AppInstalled {
    [CmdletBinding()] [OutputType([bool])] param()
    $targets = Get-UltraTaxTargets
    if ($targets -and $targets.Count -gt 0) {
        return $true
    }

    # Also check uninstall registry entries as a secondary confirmation
    if (Get-Command Get-UninstallEntry -ErrorAction SilentlyContinue) {
        $entries = @(Get-UninstallEntry -DisplayName 'UltraTax CS*')
        if ($entries.Count -gt 0) { return $true }
    }

    return $false
}

function Get-AppVersion {
    [CmdletBinding()] [OutputType([string])] param()
    $targets = Get-UltraTaxTargets
    if (-not $targets -or $targets.Count -eq 0) {
        return ''
    }

    $parts = @()
    foreach ($yr in $targets.Keys) {
        $t = $targets[$yr]
        $ver = 'Detected'
        try {
            if (Test-Path -LiteralPath $t.Executable) {
                $fvi = (Get-Item -LiteralPath $t.Executable).VersionInfo
                if ($fvi -and $fvi.FileVersion) {
                    $ver = $fvi.FileVersion
                }
            }
        } catch { }

        $parts += ("UT{0}: {1} ({2})" -f $yr, $ver, $t.Executable)
    }

    return ($parts -join '; ')
}

function Get-UltraTaxUpdaterExecutable {
    param([Parameter(Mandatory)][string]$AppExe)
    $dir = Split-Path $AppExe -Parent
    $csiUpd = Join-Path $dir 'csiupd.exe'
    if (Test-Path -LiteralPath $csiUpd) {
        return $csiUpd
    }
    # Check local C:\WINCSI fallback
    if ($AppExe -match '(?i)utw(\d{2})\.exe') {
        $twoDigit = $Matches[1]
        $localCsi = "C:\WINCSI\UT$twoDigit\csiupd.exe"
        if (Test-Path -LiteralPath $localCsi) { return $localCsi }
    }
    return $AppExe # Fallback to original utwXX.exe if csiupd.exe is not found
}

function Invoke-AppUpdate {
    [CmdletBinding()] param([switch]$Simulate)
    $result = [PSCustomObject]@{
        Success        = $false
        RebootRequired = $false
        Message        = ''
        TargetVersion  = ''
    }

    $targets = Get-UltraTaxTargets
    $currentVer = Get-AppVersion
    $result.TargetVersion = $currentVer

    if (-not $targets -or $targets.Count -eq 0) {
        $result.Success = $true
        $result.Message = 'No supported UltraTax CS installations (2023-2025) detected.'
        return $result
    }

    $yearsList = ($targets.Values | ForEach-Object { "$($_.Year) ($($_.Executable))" }) -join ', '

    if ($Simulate) {
        $result.Success = $true
        $result.Message = "SIMULATE: Would update UltraTax CS target years: $yearsList via CS Connect."
        return $result
    }

    # 1. Safely close any active UltraTax instances prior to updates
    $utProcesses = @('utw23', 'utw24', 'utw25', 'utuninst', 'csconnect', 'connectbgdl')
    if (Get-Command Stop-ProcessSafely -ErrorAction SilentlyContinue) {
        $stopped = Stop-ProcessSafely -Name $utProcesses -GracePeriodSeconds 10
        if ($stopped -gt 0) {
            Write-Log "[Thomson UltraTax CS] Gracefully closed $stopped active UltraTax/CS process(es)." -Level INFO
        }
    }

    # 2. Locate Vendored AutoHotkey runtime and worker script
    $cursor = $PSScriptRoot
    while ($cursor -and -not (Test-Path -LiteralPath (Join-Path $cursor 'Start-ImageUpdate.ps1'))) {
        $parent = Split-Path $cursor -Parent
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    $rootDir = if ($cursor -and (Test-Path -LiteralPath (Join-Path $cursor 'Start-ImageUpdate.ps1'))) {
        $cursor
    } else {
        'C:\ProgramData\GoldenImageUpdater'
    }
    $ahkExe = Join-Path $rootDir 'Vendor\AutoHotkey\AutoHotkey64.exe'
    if (-not (Test-Path -LiteralPath $ahkExe)) {
        $ahkExe = Join-Path $rootDir 'Vendor\AutoHotkey\AutoHotkey64_UIA.exe'
    }
    if (-not (Test-Path -LiteralPath $ahkExe)) {
        $sysAhk = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
        if (Test-Path -LiteralPath $sysAhk) { $ahkExe = $sysAhk }
    }

    $ahkScript = Join-Path $rootDir 'Vendor\AutoHotkey\Update-UltraTax.ahk'

    if (-not (Test-Path -LiteralPath $ahkExe)) {
        $result.Success = $false
        $result.Message = "AutoHotkey v2 executable could not be found at '$ahkExe'."
        Write-Log "[Thomson UltraTax CS] $($result.Message)" -Level ERROR
        return $result
    }

    if (-not (Test-Path -LiteralPath $ahkScript)) {
        $result.Success = $false
        $result.Message = "UltraTax AHK worker script missing at '$ahkScript'."
        Write-Log "[Thomson UltraTax CS] $($result.Message)" -Level ERROR
        return $result
    }

    # 3. Iterate over each detected year (sorted chronologically: 23, 24, 25)
    $allSuccess = $true
    $yearSummaries = @()

    foreach ($yr in ($targets.Keys | Sort-Object)) {
        $target = $targets[$yr]
        $updaterExe = Get-UltraTaxUpdaterExecutable -AppExe $target.Executable
        Write-Log "[Thomson UltraTax CS] Starting update cycle for UltraTax $($target.Year) ('$updaterExe')..." -Level INFO

        # Run Update-UltraTax.ahk with timeout and error suppression
        $ahkArgs = "/ErrorStdOut `"$ahkScript`" $yr `"$updaterExe`""
        $code = Start-InstallerProcess -FilePath $ahkExe -Arguments $ahkArgs -TimeoutMinutes 20 -LogName "UltraTax-$yr"

        if ($code -eq 0) {
            Write-Log "[Thomson UltraTax CS] UltraTax $($target.Year) update cycle finished successfully (code 0)." -Level INFO
            $yearSummaries += "$($target.Year): Success"
        } elseif ($code -eq 2) {
            Write-Log "[Thomson UltraTax CS] UltraTax $($target.Year) update deferred: Active users currently logged into the software." -Level WARN
            $yearSummaries += "$($target.Year): Deferred (Active Users Logged In)"
            $allSuccess = $false
        } else {
            Write-Log "[Thomson UltraTax CS] UltraTax $($target.Year) updater exited with code $code." -Level WARN
            $yearSummaries += "$($target.Year): Failed (code $code)"
            $allSuccess = $false
        }

        # Brief pause between tax years to allow file handles and services to settle
        Start-Sleep -Seconds 3
    }

    # 4. Desktop Shortcut Hygiene
    if (Get-Command Move-DesktopShortcut -ErrorAction SilentlyContinue) {
        [void](Move-DesktopShortcut -Pattern @('UltraTax*') -SubFolder 'Applications\Thomson Products\UltraTax')
    }

    # 5. Build Final Result
    $result.Success       = $allSuccess
    $result.Message       = ($yearSummaries -join '; ')
    $result.TargetVersion = Get-AppVersion

    return $result
}

function Test-UpdateSuccess {
    [CmdletBinding()] [OutputType([bool])] param()
    $isInstalled = Test-AppInstalled
    $ver = Get-AppVersion
    return ($isInstalled -and (-not [string]::IsNullOrWhiteSpace($ver)))
}

Export-ModuleMember -Function Test-AppInstalled, Get-AppVersion, Invoke-AppUpdate, Test-UpdateSuccess, Get-AppMetadata
