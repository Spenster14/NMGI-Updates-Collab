#Requires -Version 5.1
<#
    Microsoft Office 365 (Click-to-Run) & Microsoft Teams Servicing Module
    Strategy:
      * Office Click-to-Run (C2R):
        - Detects 32-bit and 64-bit Click-to-Run installations via HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration.
        - Locates OfficeC2RClient.exe in Common Files.
        - Safely closes active Office apps before updating to prevent file locking.
        - Executes 'OfficeC2RClient.exe /update user displaylevel=False forceappshutdown=true'
          which triggers an immediate CDN pull/finalize cycle for the active channel (e.g. Monthly Enterprise).
        - Monitors OfficeC2RClient worker processes until completion.
        - Suppresses module reboots (traps exit code 3010 and defers to orchestrator).
      * Microsoft Teams:
        - Detects provisioned New Teams (MSTeams MSIX package) standard on AVD / Golden Images.
        - Automatically downloads the official Microsoft teamsbootstrapper.exe.
        - Provisions New Teams machine-wide and updates the Teams Meeting Add-in for Outlook via:
          'teamsbootstrapper.exe -p --installTMA'.
        - Immediately purges temporary bootstrapper files from TEMP in a finally block to eliminate
          Azure storage charges.
#>

$script:AppName = 'Microsoft Office 365'

function Get-AppMetadata {
    [pscustomobject]@{
        Name      = $script:AppName
        DependsOn = @()
        Priority  = 40 # Productivity suites execute before tax/accounting suites that integrate with them
    }
}

function Get-OfficeC2RInfo {
    $c2rKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if (Test-Path -LiteralPath $c2rKey) {
        $props = Get-ItemProperty -Path $c2rKey -ErrorAction SilentlyContinue
        if ($props -and ($props.VersionToReport -or $props.Platform -or $props.ClientVersionToReport)) {
            $c2rExe = Join-Path ${env:CommonProgramFiles} "Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
            if ((-not (Test-Path -LiteralPath $c2rExe)) -and ${env:CommonProgramFiles(x86)}) {
                $c2rExe = Join-Path ${env:CommonProgramFiles(x86)} "Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
            }
            return [pscustomobject]@{
                Installed             = $true
                VersionToReport       = [string]$props.VersionToReport
                ClientVersionToReport = [string]$props.ClientVersionToReport
                Platform              = [string]$props.Platform
                UpdateChannel         = [string]$props.UpdateChannel
                UpdatesEnabled        = [string]$props.UpdatesEnabled
                ClientPath            = if (Test-Path -LiteralPath $c2rExe) { $c2rExe } else { $null }
            }
        }
    }
    return $null
}

function Get-TeamsInfo {
    # 1. Check provisioned AppX package (standard under SYSTEM / Golden Image AVD)
    try {
        $prov = Get-AppxProvisionedPackage -Online -ErrorAction Stop |
            Where-Object { $_.DisplayName -match 'Teams' } |
            Select-Object -First 1
        if ($prov -and $prov.Version) {
            return [pscustomobject]@{
                IsProvisioned = $true
                DisplayName   = [string]$prov.DisplayName
                Version       = [string]$prov.Version
            }
        }
    } catch { }

    # 2. Check installed user AppX package (accessible in non-elevated user context)
    try {
        $appx = Get-AppxPackage -Name '*Teams*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'MSTeams' } |
            Select-Object -First 1
        if ($appx -and $appx.Version) {
            return [pscustomobject]@{
                IsProvisioned = $false
                DisplayName   = [string]$appx.Name
                Version       = [string]$appx.Version
            }
        }
    } catch { }

    # 3. Check legacy / classic Teams Machine-Wide Installer in registry
    if (Get-Command Get-UninstallEntry -ErrorAction SilentlyContinue) {
        $classic = Get-UninstallEntry -DisplayName 'Teams Machine-Wide Installer*' | Select-Object -First 1
        if ($classic -and $classic.DisplayVersion) {
            return [pscustomobject]@{
                IsProvisioned = $false
                DisplayName   = 'Classic Teams (Machine-Wide)'
                Version       = [string]$classic.DisplayVersion
            }
        }
    }

    return $null
}

function Test-AppInstalled {
    [CmdletBinding()] [OutputType([bool])] param()
    $c2r = Get-OfficeC2RInfo
    if ($c2r -and $c2r.Installed) { return $true }
    $teams = Get-TeamsInfo
    if ($teams) { return $true }
    return $false
}

function Get-AppVersion {
    [CmdletBinding()] [OutputType([string])] param()
    $c2r = Get-OfficeC2RInfo
    $teams = Get-TeamsInfo

    $parts = @()
    if ($c2r -and $c2r.VersionToReport) {
        $c2rStr = if ($c2r.Platform) { "{0} ({1})" -f $c2r.VersionToReport, $c2r.Platform } else { $c2r.VersionToReport }
        $parts += $c2rStr
    }
    if ($teams -and $teams.Version) {
        $parts += "MSTeams {0}" -f $teams.Version
    }

    if ($parts.Count -gt 0) {
        return ($parts -join '; ')
    }
    return ''
}

function Invoke-AppUpdate {
    [CmdletBinding()] param([switch]$Simulate)
    $result = [PSCustomObject]@{
        Success        = $false
        RebootRequired = $false
        Message        = ''
        TargetVersion  = ''
    }

    $current = Get-AppVersion
    if ($Simulate) {
        $result.Success = $true
        $result.Message = "SIMULATE: would invoke OfficeC2RClient.exe /update user and provision New Teams via teamsbootstrapper.exe (current: $current)."
        $result.TargetVersion = $current
        return $result
    }

    # Safely close active Office and Teams applications to prevent file locks
    $officeProcesses = @('winword', 'excel', 'outlook', 'powerpnt', 'msaccess', 'onenote', 'mspub', 'visio', 'winproj', 'teams', 'ms-teams')
    if (Get-Command Stop-ProcessSafely -ErrorAction SilentlyContinue) {
        $stopped = Stop-ProcessSafely -Name $officeProcesses -GracePeriodSeconds 10
        if ($stopped -gt 0) {
            Write-Log "[Microsoft Office 365] Gracefully closed $stopped active Office/Teams application(s)." -Level INFO
        }
    }

    # ---------------------------------------------------------
    # Part 1: Microsoft Office Click-to-Run Update
    # ---------------------------------------------------------
    $c2r = Get-OfficeC2RInfo
    $c2rSuccess = $true
    $c2rReboot = $false
    $c2rMsg = ''

    if ($c2r -and $c2r.ClientPath) {
        $beforeVersion = $c2r.VersionToReport
        $channel = if ($c2r.UpdateChannel) { $c2r.UpdateChannel } else { 'Default CDN' }
        Write-Log "[Microsoft Office 365] Triggering Office Click-to-Run update via '$($c2r.ClientPath)' (current: $beforeVersion, channel: $channel)..." -Level INFO

        $c2rArgs = '/update user displaylevel=False forceappshutdown=true'
        $code = Start-InstallerProcess -FilePath $c2r.ClientPath -Arguments $c2rArgs -TimeoutMinutes 20 -LogName 'Office365-C2R'
        Write-Log "[Microsoft Office 365] OfficeC2RClient launcher exited with code: $code" -Level DEBUG

        if ($code -eq 3010) {
            $c2rReboot = $true
        } elseif ($code -ne 0) {
            Write-Log "[Microsoft Office 365] OfficeC2RClient launcher returned non-zero code $code." -Level WARN
        }

        # OfficeC2RClient may hand off or run background worker processes.
        # Wait for any active OfficeC2RClient processes to finish (max 10 minutes).
        Start-Sleep -Seconds 5
        $deadline = (Get-Date).AddMinutes(10)
        while ((Get-Date) -lt $deadline -and (Get-Process -Name 'OfficeC2RClient' -ErrorAction SilentlyContinue)) {
            Write-Log "[Microsoft Office 365] Waiting for OfficeC2RClient background worker to complete..." -Level DEBUG
            Start-Sleep -Seconds 10
        }

        # Check post-update configuration
        $c2rAfter = Get-OfficeC2RInfo
        $afterVersion = if ($c2rAfter) { $c2rAfter.VersionToReport } else { '' }

        if ($afterVersion -and $beforeVersion -and $afterVersion -ne $beforeVersion) {
            $c2rMsg = "Office C2R updated from $beforeVersion to $afterVersion"
            Write-Log "[Microsoft Office 365] $c2rMsg" -Level INFO
        } elseif ($afterVersion) {
            $c2rMsg = "Office C2R already up to date ($afterVersion)"
            Write-Log "[Microsoft Office 365] $c2rMsg" -Level INFO
        } else {
            $c2rMsg = "Office C2R completed (exit code $code)"
        }
    } elseif ($c2r) {
        $c2rMsg = "Office Click-to-Run registry found but OfficeC2RClient.exe was missing."
        Write-Log "[Microsoft Office 365] $c2rMsg" -Level WARN
        $c2rSuccess = $false
    } else {
        $c2rMsg = "Office Click-to-Run not installed."
        Write-Log "[Microsoft Office 365] $c2rMsg" -Level INFO
    }

    # ---------------------------------------------------------
    # Part 2: Microsoft Teams Provisioning & Meeting Add-in
    # ---------------------------------------------------------
    $teams = Get-TeamsInfo
    $teamsMsg = ''

    if ($teams) {
        Write-Log "[Microsoft Office 365] Detected Teams ($($teams.DisplayName) $($teams.Version)). Downloading teamsbootstrapper.exe..." -Level INFO
        $bootstrapperUrl = 'https://go.microsoft.com/fwlink/?linkid=2243204'
        $tempDir = [System.IO.Path]::GetTempPath()
        $bootstrapperExe = Join-Path $tempDir ("teamsbootstrapper-{0}.exe" -f [guid]::NewGuid().ToString('N'))

        try {
            Save-RemoteFile -Uri $bootstrapperUrl -OutFile $bootstrapperExe
            Write-Log "[Microsoft Office 365] Provisioning Teams machine-wide and updating Teams Meeting Add-in via '$bootstrapperExe -p --installTMA'..." -Level INFO

            $bootOutput = & $bootstrapperExe -p --installTMA 2>&1
            $bootExit = $LASTEXITCODE
            $outStr = ($bootOutput | Out-String).Trim()
            Write-Log "[Microsoft Office 365] teamsbootstrapper exit code: $bootExit. Output: $outStr" -Level DEBUG

            # If --installTMA is unrecognized or returned error, fallback to standard -p
            if ($bootExit -ne 0 -and $outStr -match '(?i)invalid|parameter|unrecognized') {
                Write-Log "[Microsoft Office 365] Retrying teamsbootstrapper with '-p' flag only..." -Level INFO
                $bootOutput = & $bootstrapperExe -p 2>&1
                $bootExit = $LASTEXITCODE
                $outStr = ($bootOutput | Out-String).Trim()
                Write-Log "[Microsoft Office 365] teamsbootstrapper -p exit code: $bootExit. Output: $outStr" -Level DEBUG
            }

            # Query updated Teams version
            $teamsAfter = Get-TeamsInfo
            if ($teamsAfter -and $teamsAfter.Version) {
                if ($teamsAfter.Version -ne $teams.Version) {
                    $teamsMsg = "Teams updated from $($teams.Version) to $($teamsAfter.Version)"
                    Write-Log "[Microsoft Office 365] $teamsMsg" -Level INFO
                } else {
                    $teamsMsg = "Teams already up to date ($($teamsAfter.Version))"
                    Write-Log "[Microsoft Office 365] $teamsMsg" -Level INFO
                }
            } else {
                $teamsMsg = "Teams provisioning completed (exit code $bootExit)"
            }
        } catch {
            $teamsMsg = "Teams provisioning warning: $($_.Exception.Message)"
            Write-Log "[Microsoft Office 365] $teamsMsg" -Level WARN
        } finally {
            # CRITICAL AZURE COST CONSTRAINT: Purge all temporary download artifacts immediately
            if (Test-Path -LiteralPath $bootstrapperExe) {
                Remove-Item -LiteralPath $bootstrapperExe -Force -ErrorAction SilentlyContinue
            }
            Get-ChildItem -Path $tempDir -Filter "*teamsbootstrapper*" -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem -Path $tempDir -Filter "*MSTeams*.msix*" -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    } else {
        $teamsMsg = "Teams not provisioned (skipped)"
        Write-Log "[Microsoft Office 365] $teamsMsg" -Level INFO
    }

    # ---------------------------------------------------------
    # Part 3: Desktop Shortcuts Organization
    # ---------------------------------------------------------
    if (Get-Command Move-DesktopShortcut -ErrorAction SilentlyContinue) {
        [void](Move-DesktopShortcut -Pattern @('Microsoft Teams*', 'Teams*', 'Word*', 'Excel*', 'Outlook*', 'PowerPoint*', 'Access*'))
    }

    # ---------------------------------------------------------
    # Part 4: Final Summary & Return
    # ---------------------------------------------------------
    $summary = @()
    if ($c2rMsg) { $summary += $c2rMsg }
    if ($teamsMsg) { $summary += $teamsMsg }

    $result.Success        = $c2rSuccess
    $result.RebootRequired = $c2rReboot
    $result.Message        = ($summary -join '; ')
    $result.TargetVersion  = Get-AppVersion

    return $result
}

function Test-UpdateSuccess {
    [CmdletBinding()] [OutputType([bool])] param()
    $isInstalled = Test-AppInstalled
    $ver = Get-AppVersion
    return ($isInstalled -and (-not [string]::IsNullOrWhiteSpace($ver)))
}

Export-ModuleMember -Function Test-AppInstalled, Get-AppVersion, Invoke-AppUpdate, Test-UpdateSuccess, Get-AppMetadata
