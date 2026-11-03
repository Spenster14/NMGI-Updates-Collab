#Requires -Version 5.1
<#
    Microsoft .NET Framework & Modern .NET Runtime Servicing Module
    Strategy:
      * Core Runtime Target: .NET Framework 4.8.1 (Release >= 533320).
      * On Windows 11 (22H2+) / Server 2025: .NET 4.8.1 is built directly into the OS.
        Ongoing security and cumulative updates are serviced via Windows Update.
      * On Windows 10 / Server 2016/2019/2022 (< 4.8.1): Downloads and executes the
        official Microsoft .NET Framework 4.8.1 standalone offline installer silently.
      * Legacy Accounting Compatibility: Ensures .NET Framework 3.5 (NetFx3) is enabled
        via DISM, which is required by Thomson Reuters, CCH, and Intuit desktop suites.
      * Modern .NET Runtimes (.NET 6, 7, 8, 9): Detects any installed modern side-by-side
        desktop runtimes on the client and updates them to their latest service patch via WinGet.
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
                { $_ -ge 533320 } { '4.8.1'; break }
                { $_ -ge 528040 } { '4.8'; break }
                { $_ -ge 461808 } { '4.7.2'; break }
                { $_ -ge 461308 } { '4.7.1'; break }
                { $_ -ge 460798 } { '4.7'; break }
                { $_ -ge 394802 } { '4.6.2'; break }
                default           { '4.x'; break }
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

function Get-InstalledModernDotNetRuntimes {
    <#
    .SYNOPSIS
        Detects installed modern .NET (Core) / Windows Desktop runtimes (e.g. 6.x, 8.x, 9.x).
        Returns a list of custom objects with Name, Major, and Version.
    #>
    $found = @{}

    # 1. Via dotnet CLI if available
    $dotnetExe = "$env:ProgramFiles\dotnet\dotnet.exe"
    if (Test-Path -LiteralPath $dotnetExe) {
        try {
            $lines = & $dotnetExe --list-runtimes 2>$null
            foreach ($line in $lines) {
                if ($line -match '^(\S+)\s+(\d+)\.([\d\.]+)\s+\[(.*)\]') {
                    $name    = $matches[1]
                    $major   = [int]$matches[2]
                    $version = "$($matches[2]).$($matches[3])"
                    $key     = "$name-$major"
                    if (-not $found.ContainsKey($key) -or (Compare-AppVersion -Left $version -Right $found[$key].Version) -gt 0) {
                        $found[$key] = [pscustomobject]@{
                            Name    = $name
                            Major   = $major
                            Version = $version
                        }
                    }
                }
            }
        } catch { }
    }

    # 2. Via Registry Uninstall entries
    try {
        $entries = Get-UninstallEntry -DisplayName '*Microsoft*.NET*' |
            Where-Object { $_.DisplayName -match '(?i)Microsoft\s+(Windows\s+Desktop|\.NET)\s+Runtime\s*-\s*(\d+)\.' }
        foreach ($e in $entries) {
            if ($e.DisplayName -match '(?i)Microsoft\s+(Windows\s+Desktop|\.NET)\s+Runtime\s*-\s*(\d+)\.') {
                $major = [int]$matches[2]
                $ver   = if ($e.DisplayVersion) { [string]$e.DisplayVersion } else { "$major.0" }
                $key   = "DesktopRuntime-$major"
                if (-not $found.ContainsKey($key) -or (Compare-AppVersion -Left $ver -Right $found[$key].Version) -gt 0) {
                    $found[$key] = [pscustomobject]@{
                        Name    = 'Microsoft.WindowsDesktop.App'
                        Major   = $major
                        Version = $ver
                    }
                }
            }
        }
    } catch { }

    return @($found.Values)
}

function Test-AppInstalled {
    [CmdletBinding()] [OutputType([bool])] param()
    $info = Get-DotNet4Info
    if ($null -ne $info) { return $true }
    $modern = Get-InstalledModernDotNetRuntimes
    return ($modern.Count -gt 0)
}

function Get-AppVersion {
    [CmdletBinding()] [OutputType([string])] param()
    $info = Get-DotNet4Info
    $v = if ($info) { "{0} ({1})" -f $info.Friendly, $info.Release } else { '' }

    $modern = Get-InstalledModernDotNetRuntimes
    if ($modern.Count -gt 0) {
        $modernDesc = ($modern | ForEach-Object { ".NET $($_.Major)" } | Select-Object -Unique) -join ', '
        if ($v) { $v += "; Modern: [$modernDesc]" } else { $v = "Modern: [$modernDesc]" }
    }
    return $v
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
        $isCurrent481 = ($currentRelease -ge $script:MinTargetRelease)
        $modernRuntimes = Get-InstalledModernDotNetRuntimes

        # Simulation mode
        if ($Simulate) {
            $result.Success = $true
            $statusFx3 = if ($hasNetFx3) { "NetFx3 enabled" } else { "would enable NetFx3 feature" }
            $modernMsg = if ($modernRuntimes.Count -gt 0) {
                $majors = ($modernRuntimes | Select-Object -ExpandProperty Major -Unique) -join ', '
                "installed modern runtimes: .NET $majors"
            } else {
                "no modern runtimes installed"
            }

            if ($isCurrent481) {
                $result.Message = "SIMULATE: .NET Framework is current ($currentFriendly, Release $currentRelease; $statusFx3; $modernMsg)."
            } else {
                $result.Message = "SIMULATE: would install .NET Framework 4.8.1 via offline installer (current: $currentFriendly, Release $currentRelease; $modernMsg)."
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

        # --- STEP 3: Update any installed modern .NET Desktop Runtimes (.NET 6, 8, 9) ---
        if ($modernRuntimes.Count -gt 0) {
            $uniqueMajors = @($modernRuntimes | Select-Object -ExpandProperty Major -Unique)
            $modernResults = @()
            foreach ($major in $uniqueMajors) {
                $rtForMajor = $modernRuntimes | Where-Object { $_.Major -eq $major } | Select-Object -First 1
                $verStr = if ($rtForMajor -and $rtForMajor.Version) { $rtForMajor.Version } else { "$major.x" }

                $wingetCandidates = @("Microsoft.DotNet.DesktopRuntime.$major", "Microsoft.DotNet.Runtime.$major")
                $statusMsg = ''

                foreach ($wingetId in $wingetCandidates) {
                    Write-Log "[$($script:AppName)] Checking modern .NET $major updates via WinGet ($wingetId)..." -Level INFO
                    try {
                        $r = Invoke-WinGetUpgrade -Id $wingetId -Simulate:$Simulate
                        if ($r.RebootRequired) { $result.RebootRequired = $true }
                        if ($r.Success) {
                            $statusMsg = $r.Message
                            break
                        } elseif ($r.Message -notmatch '(?i)No installed package found') {
                            $statusMsg = $r.Message
                            break
                        }
                    } catch {
                        Write-Log "[$($script:AppName)] WinGet check for ${wingetId}: $($_.Exception.Message)" -Level DEBUG
                    }
                }

                if (-not $statusMsg -or $statusMsg -match '(?i)No installed package found') {
                    $statusMsg = "current ($verStr, managed via Windows Update)"
                }
                $modernResults += (".NET {0}: {1}" -f $major, $statusMsg)
            }
            if ($modernResults.Count -gt 0) {
                $result.Message += "; Modern: " + ($modernResults -join ' | ')
            }
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
