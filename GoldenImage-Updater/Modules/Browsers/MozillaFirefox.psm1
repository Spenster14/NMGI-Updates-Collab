#Requires -Version 5.1
<#
    Mozilla Firefox (Rapid Release & ESR) - Production Update Module
    Strategy:
      * Tier 1 (Primary): Direct Mozilla Enterprise CDN download (x64 MSI) via official
        Mozilla product-details API (product-details.mozilla.org). Dynamically detects
        whether the machine is on Firefox Standard or Firefox ESR.
      * Tier 2 (Fallback): WinGet silent automation (Mozilla.Firefox / Mozilla.Firefox.ESR).
    Rules:
      * Headless execution under NT AUTHORITY\SYSTEM.
      * Suppresses module-level reboots (traps 3010/1641 and defers to orchestrator).
      * Auto-logs verbose MSI output to C:\ProgramData\GoldenImageUpdater\Logs\MSI-MozillaFirefox-*.log.
#>

$script:AppName         = 'Mozilla Firefox'
$script:UninstallName   = 'Mozilla Firefox*'
$script:VersionApi      = 'https://product-details.mozilla.org/1.0/firefox_versions.json'
$script:ProcessesToStop = @('firefox')
$script:TargetVersion   = ''

function Get-AppMetadata {
    [pscustomobject]@{
        Name      = $script:AppName
        DependsOn = @()
        Priority  = 20
    }
}

function Test-IsEsr {
    <# Checks if the currently installed Firefox instance is Extended Support Release (ESR) #>
    $entry = @(Get-UninstallEntry -DisplayName $script:UninstallName) | Select-Object -First 1
    if ($entry) {
        if ($entry.DisplayName -like '*ESR*' -or $entry.DisplayVersion -like '*esr*') {
            return $true
        }
    }
    return $false
}

function Get-LatestFirefoxRelease {
    <#
    .SYNOPSIS
        Queries Mozilla's official product-details API for current Rapid and ESR releases.
    .OUTPUTS
        [pscustomobject] Version, MsiUrl, IsEsr, WinGetId
    #>
    [CmdletBinding()]
    param([bool]$UseEsr = $false)
    
    $result = [pscustomobject]@{
        Version  = ''
        MsiUrl   = ''
        IsEsr    = $UseEsr
        WinGetId = if ($UseEsr) { 'Mozilla.Firefox.ESR' } else { 'Mozilla.Firefox' }
    }
    
    if ($UseEsr) {
        $result.MsiUrl = 'https://download.mozilla.org/?product=firefox-esr-msi-latest-ssl&os=win64&lang=en-US'
    } else {
        $result.MsiUrl = 'https://download.mozilla.org/?product=firefox-msi-latest-ssl&os=win64&lang=en-US'
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod -Uri $script:VersionApi -TimeoutSec 15 -ErrorAction Stop
        if ($UseEsr -and $r.FIREFOX_ESR) {
            $result.Version = [string]$r.FIREFOX_ESR
        } elseif ($r.LATEST_FIREFOX_VERSION) {
            $result.Version = [string]$r.LATEST_FIREFOX_VERSION
        }
    } catch { }

    return $result
}

function Test-AppInstalled {
    [CmdletBinding()] [OutputType([bool])] param()
    return [bool](@(Get-UninstallEntry -DisplayName $script:UninstallName).Count -gt 0)
}

function Get-AppVersion {
    [CmdletBinding()] [OutputType([string])] param()
    $e = @(Get-UninstallEntry -DisplayName $script:UninstallName) | Select-Object -First 1
    if ($e -and $e.DisplayVersion) { return [string]$e.DisplayVersion }
    return ''
}

function Invoke-AppUpdate {
    [CmdletBinding()] param([switch]$Simulate)
    $result = [PSCustomObject]@{ Success = $false; RebootRequired = $false; Message = ''; TargetVersion = '' }
    $msi = Join-Path ([IO.Path]::GetTempPath()) ("firefox-{0}.msi" -f [guid]::NewGuid().ToString('N'))
    
    try {
        $current = Get-AppVersion
        $isEsr = Test-IsEsr
        $release = Get-LatestFirefoxRelease -UseEsr:$isEsr
        
        $script:TargetVersion = $release.Version
        $msiUrl = $release.MsiUrl
        $wingetId = $release.WinGetId
        
        # If API returned empty version, query WinGet latest version as fallback target
        if (-not $script:TargetVersion) {
            $script:TargetVersion = Get-WinGetLatestVersion -Id $wingetId
        }
        $result.TargetVersion = $script:TargetVersion

        # Check if already current
        if ($script:TargetVersion -and $current -and (Compare-AppVersion -Left $current -Right $script:TargetVersion) -ge 0) {
            $result.Success = $true
            $result.Message = "Already up to date ($current)."
            return $result
        }

        # Simulation Mode
        if ($Simulate) {
            $edition = if ($isEsr) { 'ESR' } else { 'Standard' }
            $result.Success = $true
            $result.Message = "SIMULATE: would download $msiUrl ($edition) and run msiexec /i /qn /norestart (current $current, target $($script:TargetVersion))."
            return $result
        }

        # --- TIER 1: Direct Enterprise MSI Installation ---
        try {
            [void](Stop-ProcessSafely -Name $script:ProcessesToStop)
            [void](Save-RemoteFile -Uri $msiUrl -OutFile $msi)
            $code = Start-InstallerProcess -FilePath 'msiexec.exe' -Arguments ('/i "{0}" /qn /norestart' -f $msi) -LogName 'MozillaFirefox'
            switch ($code) {
                0       { $result.Success = $true;  $result.Message = 'Installed.' }
                3010    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed; reboot required.' }
                1641    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed; reboot initiated by installer.' }
                default { throw "msiexec exit code $code." }
            }
            if ($result.Success) {
                [void](Move-DesktopShortcut -Pattern @('Firefox*', 'Mozilla Firefox*') -SubFolder 'Applications')
            }
            return $result
        } catch {
            Write-Log "[$($script:AppName)] Direct MSI update failed: $($_.Exception.Message). Falling back to WinGet..." -Level WARN
        }

        # --- TIER 2: WinGet Fallback Automation ---
        try {
            $r = Invoke-WinGetUpgrade -Id $wingetId -Simulate:$Simulate
            $result.Success        = [bool]$r.Success
            $result.RebootRequired = [bool]$r.RebootRequired
            $result.Message        = "Direct MSI failed; WinGet fallback: $($r.Message)"
            if ($result.Success) {
                [void](Move-DesktopShortcut -Pattern @('Firefox*', 'Mozilla Firefox*') -SubFolder 'Applications')
            }
            return $result
        } catch {
            $result.Success = $false
            $result.Message = "Direct update and WinGet fallback failed: $($_.Exception.Message)"
        }
    } catch {
        $result.Success = $false
        $result.Message = "Unhandled error: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    }
    return $result
}

function Test-UpdateSuccess {
    [CmdletBinding()] [OutputType([bool])] param()
    if (-not (Test-AppInstalled)) { return $false }
    if (-not $script:TargetVersion) { return $true }
    return ((Compare-AppVersion -Left (Get-AppVersion) -Right $script:TargetVersion) -ge 0)
}

Export-ModuleMember -Function Test-AppInstalled, Get-AppVersion, Invoke-AppUpdate, Test-UpdateSuccess, Get-AppMetadata
