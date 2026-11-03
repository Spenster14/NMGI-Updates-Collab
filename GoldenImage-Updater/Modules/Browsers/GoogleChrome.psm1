#Requires -Version 5.1
# Google Chrome - direct download / silent MSI reference implementation.

$script:AppName         = 'Google Chrome'
$script:UninstallName   = 'Google Chrome*'
$script:WinGetId        = 'Google.Chrome'
$script:MsiUrl          = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
$script:VersionApi      = 'https://versionhistory.googleapis.com/v1/chrome/platforms/win64/channels/stable/versions/all/releases?filter=endtime%3Dnone&order_by=version%20desc&pageSize=10'
$script:ProcessesToStop = @('chrome')
$script:TargetVersion   = ''

function Get-AppMetadata { [pscustomobject]@{ Name = $script:AppName; DependsOn = @(); Priority = 100 } }

function Get-LatestChromeVersion {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod -Uri $script:VersionApi -TimeoutSec 15 -ErrorAction Stop
        # Filter for the newest release that reached full/majority rollout (fraction >= 0.5)
        # to avoid targeting 0% or 0.005% canary staged releases that the static Enterprise MSI does not yet serve.
        $public = @($r.releases | Where-Object { [double]$_.fraction -ge 0.5 } | Select-Object -First 1)
        if ($public -and $public.version) { return [string]$public.version }
        $v = @($r.releases)[0].version
        if ($v) { return [string]$v }
    } catch { }
    return ''
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
    $msi = Join-Path ([IO.Path]::GetTempPath()) ("chrome-{0}.msi" -f [guid]::NewGuid().ToString('N'))
    try {
        $current = Get-AppVersion
        $script:TargetVersion = Get-LatestChromeVersion
        $result.TargetVersion = $script:TargetVersion
        if ($script:TargetVersion -and $current -and (Compare-AppVersion -Left $current -Right $script:TargetVersion) -ge 0) {
            $result.Success = $true; $result.Message = "Already up to date ($current)."
            return $result
        }
        if ($Simulate) {
            $result.Success = $true
            $result.Message = "SIMULATE: would download $($script:MsiUrl) and run msiexec /i /qn /norestart (current $current, target $($script:TargetVersion))."
            return $result
        }
        [void](Stop-ProcessSafely -Name $script:ProcessesToStop)
        [void](Save-RemoteFile -Uri $script:MsiUrl -OutFile $msi)
        $code = Start-InstallerProcess -FilePath 'msiexec.exe' -Arguments ('/i "{0}" /qn /norestart' -f $msi) -LogName 'GoogleChrome'
        switch ($code) {
            0       { $result.Success = $true;  $result.Message = 'Installed.' }
            3010    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed; reboot required.' }
            1641    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed; reboot initiated by installer.' }
            default { $result.Success = $false; $result.Message = "msiexec exit code $code." }
        }
        if ($result.Success) {
            [void](Move-DesktopShortcut -Pattern @('Google Chrome*', 'Chrome*') -SubFolder 'Applications')
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

