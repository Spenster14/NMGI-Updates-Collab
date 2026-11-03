#Requires -Version 5.1
<#
    Microsoft Edge WebView2 Runtime - Production Update Module
    Strategy:
      * Tier 1 (Primary): Direct Microsoft CDN download of Evergreen Standalone x64 installer
        (go.microsoft.com/fwlink/p/?LinkId=2124701). Targeted against official Edge Stable milestone.
      * Tier 2 (Fallback): WinGet silent automation (Microsoft.EdgeWebView2Runtime).
    Rules:
      * Headless execution under NT AUTHORITY\SYSTEM.
      * Suppresses module-level reboots (traps 3010/1641 and defers to orchestrator).
      * Priority 10 ensures runtimes update prior to dependent applications and web shells.
#>

$script:AppName         = 'Microsoft Edge WebView2'
$script:UninstallName   = 'Microsoft Edge WebView2*'
$script:WinGetId        = 'Microsoft.EdgeWebView2Runtime'
$script:EnterpriseApi   = 'https://edgeupdates.microsoft.com/api/products?view=enterprise'
$script:StandaloneUrl   = 'https://go.microsoft.com/fwlink/p/?LinkId=2124701'
$script:ProcessesToStop = @('msedgewebview2')
$script:TargetVersion   = ''

function Get-AppMetadata {
    [pscustomobject]@{
        Name      = $script:AppName
        DependsOn = @()
        Priority  = 10
    }
}

function Get-LatestWebView2Release {
    <#
    .SYNOPSIS
        Queries Microsoft Edge Enterprise API for the current Stable milestone
        (which WebView2 Runtime tracks identically) or falls back to WinGet.
    .OUTPUTS
        [string] Version
    #>
    [CmdletBinding()] param()
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod -Uri $script:EnterpriseApi -TimeoutSec 15 -ErrorAction Stop
        $stable = @($r | Where-Object { $_.Product -eq 'Stable' })[0]
        if ($stable) {
            $x64 = @($stable.Releases | Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq 'x64' })[0]
            if ($x64 -and $x64.ProductVersion) {
                return [string]$x64.ProductVersion
            }
        }
    } catch { }

    try {
        $v = Get-WinGetLatestVersion -Id $script:WinGetId
        if ($v) { return [string]$v }
    } catch { }

    return ''
}

function Test-AppInstalled {
    [CmdletBinding()] [OutputType([bool])] param()
    $found = @(Get-UninstallEntry -DisplayName $script:UninstallName)
    if ($found.Count -gt 0) { return $true }

    # Fallback check against machine-wide EdgeUpdate Client state key
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-F509-4142-AF80-BCAC677077E4}',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-F509-4142-AF80-BCAC677077E4}'
    )
    foreach ($k in $keys) {
        if (Test-Path -LiteralPath $k) {
            $pv = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).pv
            if ($pv) { return $true }
        }
    }
    return $false
}

function Get-AppVersion {
    [CmdletBinding()] [OutputType([string])] param()
    $e = @(Get-UninstallEntry -DisplayName $script:UninstallName) | Select-Object -First 1
    if ($e -and $e.DisplayVersion) { return [string]$e.DisplayVersion }

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-F509-4142-AF80-BCAC677077E4}',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-F509-4142-AF80-BCAC677077E4}'
    )
    foreach ($k in $keys) {
        if (Test-Path -LiteralPath $k) {
            $pv = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).pv
            if ($pv) { return [string]$pv }
        }
    }
    return ''
}

function Invoke-AppUpdate {
    [CmdletBinding()] param([switch]$Simulate)
    $result = [PSCustomObject]@{ Success = $false; RebootRequired = $false; Message = ''; TargetVersion = '' }
    $installer = Join-Path ([IO.Path]::GetTempPath()) ("edgewebview2-{0}.exe" -f [guid]::NewGuid().ToString('N'))

    try {
        $current = Get-AppVersion
        $script:TargetVersion = Get-LatestWebView2Release
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
            $result.Message = "SIMULATE: would download $($script:StandaloneUrl) and run /silent /install (current $current, target $($script:TargetVersion))."
            return $result
        }

        # --- TIER 1: Direct Standalone Installer ---
        try {
            [void](Stop-ProcessSafely -Name $script:ProcessesToStop)
            [void](Save-RemoteFile -Uri $script:StandaloneUrl -OutFile $installer)
            $code = Start-InstallerProcess -FilePath $installer -Arguments '/silent /install' -LogName 'EdgeWebView2'
            switch ($code) {
                0       { $result.Success = $true;  $result.Message = 'Installed.' }
                3010    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed; reboot required.' }
                1641    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed; reboot initiated by installer.' }
                default { throw "WebView2 installer exit code $code." }
            }
            return $result
        } catch {
            Write-Log "[$($script:AppName)] Direct standalone installer failed: $($_.Exception.Message). Falling back to WinGet..." -Level WARN
        }

        # --- TIER 2: WinGet Fallback Automation ---
        try {
            $r = Invoke-WinGetUpgrade -Id $script:WinGetId -Simulate:$Simulate
            $result.Success        = [bool]$r.Success
            $result.RebootRequired = [bool]$r.RebootRequired
            $result.Message        = "Direct installer failed; WinGet fallback: $($r.Message)"
            return $result
        } catch {
            $result.Success = $false
            $result.Message = "Direct install and WinGet fallback failed: $($_.Exception.Message)"
        }
    } catch {
        $result.Success = $false
        $result.Message = "Unhandled error: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
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
