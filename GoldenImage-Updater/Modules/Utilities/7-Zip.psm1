#Requires -Version 5.1
<#
    7-Zip - Production Update Module
    Strategy:
      * Tier 1 (Primary): Direct vendor MSI download (x64) from official release repository
        (ip7z/7zip on GitHub / 7-zip.org). Avoids public manifest lag.
      * Tier 2 (Fallback): WinGet silent automation (7zip.7zip) if direct download/install fails.
    Rules:
      * Headless execution under NT AUTHORITY\SYSTEM.
      * Suppresses module-level reboots (traps 3010/1641 and defers to orchestrator).
      * Auto-logs verbose MSI output to C:\ProgramData\GoldenImageUpdater\Logs\MSI-7-Zip-*.log.
      * Auto-relocates any desktop shortcuts to C:\Users\Public\Desktop\Applications.
#>

$script:AppName         = '7-Zip'
$script:UninstallName   = '7-Zip*'
$script:WinGetId        = '7zip.7zip'
$script:GitHubApiUrl    = 'https://api.github.com/repos/ip7z/7zip/releases/latest'
$script:WebDownloadUrl  = 'https://www.7-zip.org/download.html'
$script:ProcessesToStop = @('7zFM', '7zG')
$script:UpdateMethod    = 'Hybrid'    # 'Hybrid' (Direct Primary + WinGet Fallback) | 'WinGetOnly' | 'DirectOnly'
$script:TargetVersion   = ''

function Get-AppMetadata {
    [pscustomobject]@{
        Name      = $script:AppName
        DependsOn = @()
        Priority  = 30
    }
}

function Get-Latest7ZipRelease {
    <#
    .SYNOPSIS
        Discovers the newest 7-Zip x64 MSI release from official release endpoints.
        Queries GitHub API (ip7z/7zip) first, falls back to parsing 7-zip.org/download.html.
    .OUTPUTS
        [pscustomobject] Version, MsiUrl
    #>
    [CmdletBinding()] param()
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        # Primary: Official GitHub releases API for ip7z/7zip
        $r = Invoke-RestMethod -Uri $script:GitHubApiUrl -Headers @{ 'User-Agent' = 'GoldenImageUpdater' } -TimeoutSec 10 -ErrorAction Stop
        $msi = @($r.assets | Where-Object { $_.name -match '7z.*-x64\.msi$' })[0]
        if ($msi -and $r.tag_name) {
            return [pscustomobject]@{
                Version = [string]$r.tag_name
                MsiUrl  = [string]$msi.browser_download_url
            }
        }
    } catch { }

    # Fallback: Scrape official 7-zip.org download page
    try {
        $html = (Invoke-WebRequest -Uri $script:WebDownloadUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop).Content
        $ver = $null
        $msiUrl = $null
        if ($html -match 'Download 7-Zip ([\d\.]+)') {
            $ver = $Matches[1]
        }
        $lines = $html -split "`n" | Where-Object { $_ -match '7z.*x64\.msi' }
        if ($lines -and $lines[0] -match 'href="([^"]+)"') {
            $raw = $Matches[1]
            $msiUrl = if ($raw -notmatch '^https?:') { "https://www.7-zip.org/$raw" } else { $raw }
        }
        if ($ver -and $msiUrl) {
            return [pscustomobject]@{
                Version = $ver
                MsiUrl  = $msiUrl
            }
        }
    } catch { }

    return $null
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
    $msi = Join-Path ([IO.Path]::GetTempPath()) ("7zip-{0}.msi" -f [guid]::NewGuid().ToString('N'))

    try {
        $current = Get-AppVersion
        $method = if ($env:GIU_7ZIP_METHOD) { $env:GIU_7ZIP_METHOD } else { $script:UpdateMethod }

        # --- TIER 1: Direct Vendor Download (Preferred) ---
        if ($method -in 'Hybrid', 'DirectOnly') {
            $release = Get-Latest7ZipRelease
            if ($release -and $release.Version -and $release.MsiUrl) {
                $script:TargetVersion = $release.Version
                $result.TargetVersion = $script:TargetVersion

                # Version check
                if ($script:TargetVersion -and $current -and (Compare-AppVersion -Left $current -Right $script:TargetVersion) -ge 0) {
                    $result.Success = $true
                    $result.Message = "Already up to date ($current)."
                    return $result
                }

                if ($Simulate) {
                    $result.Success = $true
                    $result.Message = "SIMULATE: would download $($release.MsiUrl) and run msiexec /i /qn /norestart (current $current, target $($script:TargetVersion))."
                    return $result
                }

                try {
                    [void](Stop-ProcessSafely -Name $script:ProcessesToStop)
                    [void](Save-RemoteFile -Uri $release.MsiUrl -OutFile $msi)
                    $code = Start-InstallerProcess -FilePath 'msiexec.exe' -Arguments ('/i "{0}" /qn /norestart' -f $msi) -LogName '7-Zip'
                    switch ($code) {
                        0       { $result.Success = $true;  $result.Message = 'Installed.' }
                        3010    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed; reboot required.' }
                        1641    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed; reboot initiated by installer.' }
                        default { throw "msiexec exit code $code." }
                    }
                    if ($result.Success) {
                        [void](Move-DesktopShortcut -Pattern @('7-Zip*', '7z*') -SubFolder 'Applications')
                        return $result
                    }
                } catch {
                    Write-Log "[$($script:AppName)] Direct MSI update failed: $($_.Exception.Message). Falling back to WinGet..." -Level WARN
                }
            }
        }

        # --- TIER 2: WinGet Fallback Automation ---
        if ($method -in 'Hybrid', 'WinGetOnly') {
            $script:TargetVersion = Get-WinGetLatestVersion -Id $script:WinGetId
            $result.TargetVersion = $script:TargetVersion

            if ($script:TargetVersion -and $current -and (Compare-AppVersion -Left $current -Right $script:TargetVersion) -ge 0) {
                $result.Success = $true
                $result.Message = "Already up to date ($current)."
                return $result
            }

            if (-not $Simulate) { [void](Stop-ProcessSafely -Name $script:ProcessesToStop) }
            $r = Invoke-WinGetUpgrade -Id $script:WinGetId -Simulate:$Simulate
            $result.Success        = [bool]$r.Success
            $result.RebootRequired = [bool]$r.RebootRequired
            $result.Message        = [string]$r.Message
            if ($result.Success -and -not $Simulate) {
                [void](Move-DesktopShortcut -Pattern @('7-Zip*', '7z*') -SubFolder 'Applications')
            }
            return $result
        }

        $result.Success = $false
        $result.Message = 'All configured update methods failed or exhausted.'
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
