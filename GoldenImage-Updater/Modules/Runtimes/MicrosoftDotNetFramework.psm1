#Requires -Version 5.1
<#
    Microsoft .NET Framework - Production Update & Runtime Servicing Module
    Strategy:
      * Core Runtime Target: .NET Framework 4.8.1 (Release >= 533320).
      * On Windows 11 (22H2+) / Server 2025: .NET 4.8.1 is built directly into the OS.
        Ongoing security and cumulative updates are serviced via Windows Update.
      * On Windows 10 / Server 2016/2019/2022 (< 4.8.1): Downloads and executes the
        official Microsoft .NET Framework 4.8.1 standalone offline installer silently.
      * Legacy Accounting Compatibility: Ensures .NET Framework 3.5 (NetFx3) is enabled
        via DISM, which is required by Thomson Reuters, CCH, and Intuit desktop suites.
    Rules:
      * Headless execution under NT AUTHORITY\SYSTEM.
      * Suppresses module-level reboots (traps 3010 and defers to orchestrator).
#>

$script:AppName          = 'Microsoft .NET Framework'
$script:MinTargetRelease = 533320 # .NET Framework 4.8.1
$script:TargetVersion    = '4.8.1'
$script:OfflineInstallerUrl = 'https://download.microsoft.com/download/4/b/2/cd00d4ed-ebdd-49ee-8a33-eabc3d1030e3/NDP481-x86-x64-AllOS-ENU.exe'

function Get-AppMetadata {
    [pscustomobject]@{
        Name      = $script:AppName
        DependsOn = @()
        Priority  = 10 # Runtimes execute early so dependencies are satisfied for applications
    }
}

function Get-DotNet4Info {
    $path = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    if (Test-Path -LiteralPath $path) {
        $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        if ($props -and $props.Release) {
            $release = [int]$props.Release
            $friendly = switch ($release) {
                { $_ -ge 533320 } { '4.8.1' }
                { $_ -ge 528040 } { '4.8' }
                { $_ -ge 461808 } { '4.7.2' }
                { $_ -ge 461308 } { '4.7.1' }
                { $_ -ge 460798 } { '4.7' }
                { $_ -ge 394802 } { '4.6.2' }
                default           { '4.x' }
            }
            return [pscustomobject]@{
                Release  = $release
                Version  = [string]$props.Version
                Friendly = $friendly
            }
        }
    }
    return $null
}

function Test-NetFx3Enabled {
    # 1. Quick registry check
    $v35Path = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v3.5'
    if (Test-Path -LiteralPath $v35Path) {
        $install = (Get-ItemProperty -Path $v35Path -Name 'Install' -ErrorAction SilentlyContinue).Install
        if ($install -eq 1) { return $true }
    }

    # 2. DISM / Windows Optional Feature check
    try {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName 'NetFx3' -ErrorAction SilentlyContinue
        if ($feat -and $feat.State -eq 'Enabled') { return $true }
    } catch { }

    return $false
}

function Test-AppInstalled {
    [CmdletBinding()] [OutputType([bool])] param()
    $info = Get-DotNet4Info
    return ($null -ne $info)
}

function Get-AppVersion {
    [CmdletBinding()] [OutputType([string])] param()
    $info = Get-DotNet4Info
    if ($info) {
        # Format as e.g. 4.8.1 (533509)
        return "{0} ({1})" -f $info.Friendly, $info.Release
    }
    return ''
}

function Invoke-AppUpdate {
    [CmdletBinding()] param([switch]$Simulate)
    $result = [PSCustomObject]@{
        Success        = $false
        RebootRequired = $false
        Message        = ''
        TargetVersion  = $script:TargetVersion
    }

    $tempFile = $null

    try {
        $info = Get-DotNet4Info
        if (-not $info) {
            $result.Success = $false
            $result.Message = 'Unable to detect .NET Framework 4.x in registry.'
            return $result
        }

        $currentRelease = $info.Release
        $currentFriendly = $info.Friendly
        $hasNetFx3 = Test-NetFx3Enabled

        # Check if already on .NET 4.8.1 or higher
        $isCurrent481 = ($currentRelease -ge $script:MinTargetRelease)

        # Simulation mode
        if ($Simulate) {
            $result.Success = $true
            if ($isCurrent481) {
                $statusFx3 = if ($hasNetFx3) { "NetFx3 enabled" } else { "would enable NetFx3 feature" }
                $result.Message = "SIMULATE: .NET Framework is current ($currentFriendly, Release $currentRelease; $statusFx3)."
            } else {
                $result.Message = "SIMULATE: would install .NET Framework 4.8.1 via offline installer (current: $currentFriendly, Release $currentRelease)."
            }
            return $result
        }

        # --- STEP 1: Ensure .NET Framework 3.5 (NetFx3) is enabled for accounting suites ---
        if (-not $hasNetFx3) {
            Write-Log "[$($script:AppName)] .NET Framework 3.5 (NetFx3) is disabled. Enabling via DISM..." -Level INFO
            $dismCode = Start-InstallerProcess -FilePath 'dism.exe' -Arguments '/Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart /Quiet' -LogName 'NetFx3'
            switch ($dismCode) {
                0       { Write-Log "[$($script:AppName)] NetFx3 enabled successfully." -Level INFO }
                3010    {
                    $result.RebootRequired = $true
                    Write-Log "[$($script:AppName)] NetFx3 enabled; restart required." -Level INFO
                }
                default {
                    Write-Log "[$($script:AppName)] DISM NetFx3 warning: exit code $dismCode. Continuing..." -Level WARN
                }
            }
        }

        # --- STEP 2: Upgrade .NET Framework 4.x to 4.8.1 if on older OS baseline ---
        if (-not $isCurrent481) {
            Write-Log "[$($script:AppName)] Current .NET ($currentFriendly, Release $currentRelease) below 4.8.1. Downloading standalone installer..." -Level INFO
            $tempFile = Join-Path ([IO.Path]::GetTempPath()) ("ndp481-setup-{0}.exe" -f [guid]::NewGuid().ToString('N'))
            [void](Save-RemoteFile -Uri $script:OfflineInstallerUrl -OutFile $tempFile)

            Write-Log "[$($script:AppName)] Installing .NET Framework 4.8.1 silently..." -Level INFO
            $code = Start-InstallerProcess -FilePath $tempFile -Arguments '/q /norestart' -LogName 'DotNet481'
            switch ($code) {
                0       { $result.Success = $true;  $result.Message = 'Installed .NET Framework 4.8.1.' }
                3010    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed .NET Framework 4.8.1; reboot required.' }
                1641    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed .NET Framework 4.8.1; reboot initiated by installer.' }
                5100    {
                    # 5100 indicates already installed or not applicable to this OS edition
                    $result.Success = $true
                    $result.Message = 'Installer reported .NET 4.8.1 not applicable or already current (5100).'
                }
                default { throw "Offline installer exit code $code." }
            }
        } else {
            $fx3Msg = if ($hasNetFx3 -or (Test-NetFx3Enabled)) { 'NetFx3 enabled' } else { 'NetFx3 pending' }
            $result.Success = $true
            $result.Message = "Already up to date (.NET $currentFriendly, Release $currentRelease; $fx3Msg). Monthly cumulative patches serviced by Windows Update."
        }

        return $result
    } catch {
        $result.Success = $false
        $result.Message = "Unhandled error: $($_.Exception.Message)"
        return $result
    } finally {
        if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-UpdateSuccess {
    [CmdletBinding()] [OutputType([bool])] param()
    $info = Get-DotNet4Info
    if (-not $info) { return $false }
    return ($info.Release -ge $script:MinTargetRelease)
}

Export-ModuleMember -Function Test-AppInstalled, Get-AppVersion, Invoke-AppUpdate, Test-UpdateSuccess, Get-AppMetadata
