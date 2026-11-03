#Requires -Version 5.1
<#
    Microsoft Edge (Enterprise) - Production Update Module
    Strategy:
      * Tier 1 (Primary): Direct Microsoft Enterprise CDN download (x64 MSI) via official
        Microsoft Edge Enterprise Release API (edgeupdates.microsoft.com).
      * Tier 2 (Fallback): WinGet silent automation (Microsoft.Edge) if direct download/install fails.
    Rules:
      * Headless execution under NT AUTHORITY\SYSTEM.
      * Suppresses module-level reboots (traps 3010/1641 and defers to orchestrator).
      * Auto-logs verbose MSI output to C:\ProgramData\GoldenImageUpdater\Logs\MSI-MicrosoftEdge-*.log.
#>

$script:AppName         = 'Microsoft Edge'
$script:UninstallName   = 'Microsoft Edge*'
$script:WinGetId        = 'Microsoft.Edge'
$script:EnterpriseApi   = 'https://edgeupdates.microsoft.com/api/products?view=enterprise'
$script:FallbackMsiUrl  = 'https://go.microsoft.com/fwlink/?linkid=2108834'
$script:ProcessesToStop = @('msedge')
$script:TargetVersion   = ''

function Get-AppMetadata {
    [pscustomobject]@{
        Name      = $script:AppName
        DependsOn = @()
        Priority  = 20
    }
}

function Get-LatestEdgeRelease {
    <#
    .SYNOPSIS
        Queries Microsoft's official Edge Enterprise API for the current Stable x64 release.
    .OUTPUTS
        [pscustomobject] Version, MsiUrl, Sha256
    #>
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod -Uri $script:EnterpriseApi -TimeoutSec 15 -ErrorAction Stop
        $stable = @($r | Where-Object { $_.Product -eq 'Stable' })[0]
        if ($stable) {
            $x64 = @($stable.Releases | Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq 'x64' })[0]
            if ($x64) {
                $artifact = @($x64.Artifacts | Where-Object { $_.ArtifactName -eq 'msi' })[0]
                $url = if ($artifact) { [string]$artifact.Location } else { $script:FallbackMsiUrl }
                $hash = if ($artifact) { [string]$artifact.Hash } else { '' }
                return [pscustomobject]@{
                    Version = [string]$x64.ProductVersion
                    MsiUrl  = $url
                    Sha256  = $hash
                }
            }
        }
    } catch { }
    return $null
}

function Test-AppInstalled {
    [CmdletBinding()] [OutputType([bool])] param()
    # Filter explicitly for 'Microsoft Edge' to avoid false positives on 'Microsoft Edge WebView2' or 'Microsoft Edge Update'
    return [bool](@(Get-UninstallEntry -DisplayName $script:UninstallName | Where-Object { $_.DisplayName -eq 'Microsoft Edge' }).Count -gt 0)
}

function Get-AppVersion {
    [CmdletBinding()] [OutputType([string])] param()
    $e = @(Get-UninstallEntry -DisplayName $script:UninstallName | Where-Object { $_.DisplayName -eq 'Microsoft Edge' }) | Select-Object -First 1
    if ($e -and $e.DisplayVersion) { return [string]$e.DisplayVersion }
    return ''
}

function Invoke-AppUpdate {
    [CmdletBinding()] param([switch]$Simulate)
    $result = [PSCustomObject]@{ Success = $false; RebootRequired = $false; Message = ''; TargetVersion = '' }
    $msi = Join-Path ([IO.Path]::GetTempPath()) ("msedge-{0}.msi" -f [guid]::NewGuid().ToString('N'))
    
    try {
        $current = Get-AppVersion
        $release = Get-LatestEdgeRelease
        
        $msiUrl = $script:FallbackMsiUrl
        if ($release -and $release.Version) {
            $script:TargetVersion = $release.Version
            if ($release.MsiUrl) { $msiUrl = $release.MsiUrl }
        } else {
            # Secondary check via WinGet latest version if API was unreachable
            $script:TargetVersion = Get-WinGetLatestVersion -Id $script:WinGetId
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
            $result.Success = $true
            $result.Message = "SIMULATE: would download $msiUrl and run msiexec /i /qn /norestart (current $current, target $($script:TargetVersion))."
            return $result
        }

        # --- TIER 1: Direct Enterprise MSI Installation ---
        try {
            [void](Stop-ProcessSafely -Name $script:ProcessesToStop)
            [void](Save-RemoteFile -Uri $msiUrl -OutFile $msi)
            $code = Start-InstallerProcess -FilePath 'msiexec.exe' -Arguments ('/i "{0}" /qn /norestart' -f $msi) -LogName 'MicrosoftEdge'
            switch ($code) {
                0       { $result.Success = $true;  $result.Message = 'Installed.' }
                3010    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed; reboot required.' }
                1641    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed; reboot initiated by installer.' }
                default { throw "msiexec exit code $code." }
            }
            if ($result.Success) {
                [void](Move-DesktopShortcut -Pattern @('Microsoft Edge*', 'Edge*') -SubFolder 'Applications')
            }
            return $result
        } catch {
            Write-Log "[$($script:AppName)] Direct MSI update failed: $($_.Exception.Message). Falling back to WinGet..." -Level WARN
        }

        # --- TIER 2: WinGet Fallback Automation ---
        try {
            $r = Invoke-WinGetUpgrade -Id $script:WinGetId -Simulate:$Simulate
            $result.Success        = [bool]$r.Success
            $result.RebootRequired = [bool]$r.RebootRequired
            $result.Message        = "Direct MSI failed; WinGet fallback: $($r.Message)"
            if ($result.Success) {
                [void](Move-DesktopShortcut -Pattern @('Microsoft Edge*', 'Edge*') -SubFolder 'Applications')
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
