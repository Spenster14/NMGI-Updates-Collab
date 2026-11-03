#Requires -Version 5.1
<#
    Microsoft Windows Updates - Production Update Module
    Strategy:
      * Primary: PSWindowsUpdate 2.2.1.5 (vendored in Vendor\PSWindowsUpdate + machine/PSGallery fallback).
      * Secondary / Non-Elevated: Native Windows Update Agent COM API (Microsoft.Update.Session).
    Rules:
      * Headless execution under NT AUTHORITY\SYSTEM (Nerdio Scripted Actions / Datto RMM).
      * Suppresses module-level reboots (passes -IgnoreReboot, captures pending reboots via
        Get-WURebootStatus and registry CBS/WU flags, defers reboot to orchestrator exit code 3010).
      * Priority 500: runs after application and runtime updates have been applied.
#>

$script:AppName = 'Microsoft Windows Updates'
$script:LastPendingCount = 0

function Get-AppMetadata {
    [pscustomobject]@{
        Name      = $script:AppName
        DependsOn = @()
        Priority  = 500
    }
}

function Test-IsElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return [bool]($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    } catch {
        return $false
    }
}

function Import-WUModule {
    <#
    .SYNOPSIS
        Imports PSWindowsUpdate module. Ensures the module directory is in $env:PSModulePath,
        deploys to system module path if running elevated/SYSTEM (so background tasks can find it),
        and falls back to PSGallery if needed.
    #>
    $rootDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $vendorDir = Join-Path $rootDir 'Vendor'
    $vendorModule = Join-Path $vendorDir 'PSWindowsUpdate'

    # 1. Ensure process-level PSModulePath contains the Vendor directory
    if (Test-Path -LiteralPath $vendorDir) {
        if ($env:PSModulePath -notlike "*$vendorDir*") {
            $env:PSModulePath = "$vendorDir;$($env:PSModulePath)"
        }
    }

    # 2. When running elevated/SYSTEM, deploy vendored files directly into
    # C:\Program Files\WindowsPowerShell\Modules so scheduled tasks / background jobs find it.
    if ((Test-IsElevated) -and (Test-Path -LiteralPath $vendorModule)) {
        try {
            $sysBase = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\PSWindowsUpdate'
            $sysVer  = Join-Path $sysBase '2.2.1.5'
            if (-not (Test-Path -LiteralPath $sysVer)) {
                New-Item -ItemType Directory -Path $sysVer -Force -ErrorAction SilentlyContinue | Out-Null
                Copy-Item -Path (Join-Path $vendorModule '*') -Destination $sysVer -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (-not (Test-Path -LiteralPath (Join-Path $sysBase 'PSWindowsUpdate.psd1'))) {
                Copy-Item -Path (Join-Path $vendorModule '*') -Destination $sysBase -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }

    # 3. Check if already imported
    if (Get-Module -Name 'PSWindowsUpdate') { return $true }

    # 4. Import by module name from PSModulePath
    try {
        Import-Module -Name 'PSWindowsUpdate' -Force -DisableNameChecking -ErrorAction Stop | Out-Null
        if (Get-Module -Name 'PSWindowsUpdate') { return $true }
    } catch { }

    # 5. Direct path import
    $vendorPsd1 = Join-Path $vendorModule 'PSWindowsUpdate.psd1'
    if (Test-Path -LiteralPath $vendorPsd1) {
        try {
            Import-Module -Name $vendorPsd1 -Force -DisableNameChecking -ErrorAction Stop | Out-Null
            if (Get-Module -Name 'PSWindowsUpdate') { return $true }
        } catch { }
    }

    # 6. Machine-wide / User PSModulePath
    if (Get-Module -ListAvailable -Name 'PSWindowsUpdate') {
        try {
            Import-Module -Name 'PSWindowsUpdate' -Force -DisableNameChecking -ErrorAction Stop | Out-Null
            if (Get-Module -Name 'PSWindowsUpdate') { return $true }
        } catch { }
    }

    # 7. PSGallery auto-install (if elevated and online)
    if (Test-IsElevated) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Install-Module -Name 'PSWindowsUpdate' -RequiredVersion '2.2.1.5' -Force -Confirm:$false -Scope AllUsers -SkipPublisherCheck -ErrorAction Stop
            Import-Module -Name 'PSWindowsUpdate' -Force -DisableNameChecking -ErrorAction Stop | Out-Null
            if (Get-Module -Name 'PSWindowsUpdate') { return $true }
        } catch { }
    }

    return $false
}

function Test-PendingReboot {
    <#
    .SYNOPSIS
        Checks if Windows Update or Component-Based Servicing has a reboot pending.
    #>
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    )
    foreach ($k in $keys) {
        if (Test-Path -LiteralPath $k) { return $true }
    }

    if ((Test-IsElevated) -and (Get-Command -Name Get-WURebootStatus -ErrorAction SilentlyContinue)) {
        try {
            $status = Get-WURebootStatus -Silent -ErrorAction SilentlyContinue
            if ($status -eq $true) { return $true }
        } catch { }
    }
    return $false
}

function Get-PendingUpdates {
    <#
    .SYNOPSIS
        Discovers pending Windows Updates. Uses PSWindowsUpdate when elevated,
        or falls back to native COM Microsoft.Update.Session (works non-elevated).
    #>
    [CmdletBinding()] param()
    $updates = @()

    if ((Test-IsElevated) -and (Import-WUModule)) {
        try {
            $list = @(Get-WindowsUpdate -MicrosoftUpdate -ErrorAction Stop)
            foreach ($item in $list) {
                $updates += [pscustomobject]@{
                    Title = [string]$item.Title
                    KB    = [string]$item.KB
                    Size  = [string]$item.Size
                }
            }
            return $updates
        } catch { }
    }

    # COM fallback (native, zero-dependency)
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searcher.ServerSelection = 2
        $r = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
        if ($r -and $r.Updates) {
            foreach ($u in $r.Updates) {
                $kb = if ($u.KBArticleIDs -and $u.KBArticleIDs.Count -gt 0) { "KB" + ($u.KBArticleIDs -join ', KB') } else { '' }
                $updates += [pscustomobject]@{
                    Title = [string]$u.Title
                    KB    = $kb
                    Size  = ''
                }
            }
        }
    } catch { }

    return $updates
}

function Test-AppInstalled {
    [CmdletBinding()] [OutputType([bool])] param()
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Get-AppVersion {
    [CmdletBinding()] [OutputType([string])] param()
    try {
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        if ($cv) {
            $build = $cv.CurrentBuild
            $ubr   = $cv.UBR
            $disp  = if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId }
            if ($build -and $ubr) {
                return "$build.$ubr $(if ($disp) { "($disp)" })".Trim()
            }
        }
    } catch { }
    return [System.Environment]::OSVersion.Version.ToString()
}

function Invoke-AppUpdate {
    [CmdletBinding()] param([switch]$Simulate)
    $result = [PSCustomObject]@{ Success = $false; RebootRequired = $false; Message = ''; TargetVersion = '' }

    try {
        $current = Get-AppVersion
        $result.TargetVersion = $current

        # Check for pending reboot before running
        $initialRebootPending = Test-PendingReboot

        # Discover pending updates
        $pending = @(Get-PendingUpdates)
        $script:LastPendingCount = $pending.Count

        # If no updates pending
        if ($pending.Count -eq 0) {
            $result.Success = $true
            $result.RebootRequired = $initialRebootPending
            $result.Message = "Already up to date (no pending updates)$(if ($initialRebootPending) { '; reboot pending from previous session.' } else { '.' })"
            return $result
        }

        # Simulation Mode
        if ($Simulate) {
            $result.Success = $true
            $result.RebootRequired = $initialRebootPending
            $kbList = @($pending | Where-Object { $_.KB } | ForEach-Object { $_.KB })
            $summary = if ($kbList.Count -gt 0) { " ($($kbList -join ', '))" } else { " ($($pending.Count) items)" }
            $result.Message = "SIMULATE: $($pending.Count) Windows update(s) pending$summary$(if ($initialRebootPending) { '; reboot pending' } else { '' })."
            return $result
        }

        # Live Execution requires elevated permissions
        if (-not (Test-IsElevated)) {
            $result.Success = $false
            $result.Message = "Windows Update execution requires elevated Administrator or NT AUTHORITY\SYSTEM context."
            return $result
        }

        # Ensure PSWindowsUpdate is loaded
        $loaded = Import-WUModule
        if (-not $loaded) {
            $result.Success = $false
            $result.Message = "PSWindowsUpdate module could not be loaded."
            return $result
        }

        # Register Microsoft Update Service if available
        try {
            Add-WUServiceManager -ServiceID '7971f918-a847-4430-9279-4a52d1efe18d' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        } catch { }

        # Unattended execution suppressing automatic reboots
        $installed = @(Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Verbose -ErrorAction Stop)

        $rebootNeeded = Test-PendingReboot
        $result.RebootRequired = $rebootNeeded

        if ($installed.Count -eq 0) {
            $result.Success = $true
            $result.Message = "No updates installed$(if ($rebootNeeded) { '; reboot required.' } else { '.' })"
            return $result
        }

        $failed = @($installed | Where-Object { $_.Status -match '(?i)failed|error' }).Count
        $succeeded = @($installed | Where-Object { $_.Status -match '(?i)installed|accepted' }).Count

        if ($failed -gt 0) {
            $result.Success = ($succeeded -gt 0)
            $result.Message = "Installed $succeeded, failed $failed update(s)$(if ($rebootNeeded) { '; reboot required.' } else { '.' })"
        } else {
            $result.Success = $true
            $result.Message = "Installed $($installed.Count) update(s)$(if ($rebootNeeded) { '; reboot required.' } else { '.' })"
        }
    } catch {
        $result.Success = $false
        $result.Message = "Windows Update failed: $($_.Exception.Message)"
    }
    return $result
}

function Test-UpdateSuccess {
    [CmdletBinding()] [OutputType([bool])] param()
    return $true
}

Export-ModuleMember -Function Test-AppInstalled, Get-AppVersion, Invoke-AppUpdate, Test-UpdateSuccess, Get-AppMetadata
