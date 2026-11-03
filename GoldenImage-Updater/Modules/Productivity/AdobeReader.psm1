#Requires -Version 5.1
<#
    Adobe Acrobat Reader - Production Update Module
    Strategy:
      * Tier 1 (Primary): Direct Adobe Enterprise MSP patch download from official Adobe CDN
        (ardownload2.adobe.com). Applied silently via msiexec.exe /p with verbose logging.
      * Tier 2 (Fallback): WinGet silent automation (Adobe.Acrobat.Reader.64-bit / 32-bit).
    Rules:
      * Headless execution under NT AUTHORITY\SYSTEM.
      * Suppresses module-level reboots (traps 3010/1641 and defers to orchestrator).
      * Automatically moves desktop shortcuts to C:\Users\Public\Desktop\Applications.
#>

$script:AppName          = 'Adobe Reader'
$script:UninstallPattern = 'Adobe*Reader*'
$script:WinGet64Id       = 'Adobe.Acrobat.Reader.64-bit'
$script:WinGet32Id       = 'Adobe.Acrobat.Reader.32-bit'
$script:ProcessesToStop  = @('AcroRd32', 'Acrobat', 'AcroCEF', 'AdobeARM', 'AdobeCollabSync', 'armsvc', 'AGSService')
$script:TargetVersion    = ''

function Get-AppMetadata {
    [pscustomobject]@{
        Name      = $script:AppName
        DependsOn = @()
        Priority  = 100
    }
}

function Get-LatestReaderRelease {
    <#
    .SYNOPSIS
        Queries Adobe's official Continuous track release manifest directly,
        with fallback to WinGet package repositories.
    #>
    # 1. Official Adobe ARM version manifest
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $v = (Invoke-WebRequest -Uri 'https://armmf.adobe.com/arm-manifests/mac/AcrobatDC/reader/current_version.txt' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop).Content.Trim()
        if ($v -match '^\d{2}\.\d{3}\.\d{5}$') { return $v }
    } catch { }

    # 2. WinGet 64-bit / 32-bit fallback
    try {
        $v = Get-WinGetLatestVersion -Id $script:WinGet64Id
        if ($v) { return $v }
    } catch { }

    return ''
}

function Get-ReaderEntry {
    @(Get-UninstallEntry -DisplayName $script:UninstallPattern |
        Where-Object { $_.DisplayName -match '(?i)reader' -and $_.DisplayName -notmatch '(?i)\bpro\b|\bstandard\b' }) |
        Select-Object -First 1
}

function Test-Is64BitInstalled {
    $e = Get-ReaderEntry
    if ($e -and $e.DisplayName -match '64-bit') { return $true }
    if (Test-Path -LiteralPath "$env:ProgramFiles\Adobe\Acrobat DC\Acrobat\Acrobat.exe") { return $true }
    return [System.Environment]::Is64BitOperatingSystem
}

function Test-AppInstalled {
    [CmdletBinding()] [OutputType([bool])] param()
    $e = Get-ReaderEntry
    if ($e) { return $true }

    # Fallback binary check
    $paths = @(
        "$env:ProgramFiles\Adobe\Acrobat DC\Acrobat\AcroRd32.exe",
        "${env:ProgramFiles(x86)}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $true }
    }
    return $false
}

function Get-AppVersion {
    [CmdletBinding()] [OutputType([string])] param()
    $e = Get-ReaderEntry
    if ($e -and $e.DisplayVersion) { return [string]$e.DisplayVersion }

    $paths = @(
        "$env:ProgramFiles\Adobe\Acrobat DC\Acrobat\AcroRd32.exe",
        "${env:ProgramFiles(x86)}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) {
            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($p)
            if ($vi.FileVersion) { return [string]$vi.FileVersion }
        }
    }
    return ''
}

function Invoke-AppUpdate {
    [CmdletBinding()] param([switch]$Simulate)
    $result = [PSCustomObject]@{ Success = $false; RebootRequired = $false; Message = ''; TargetVersion = '' }
    $tempFile = $null

    try {
        $current = Get-AppVersion
        $is64 = Test-Is64BitInstalled
        $winGetId = if ($is64) { $script:WinGet64Id } else { $script:WinGet32Id }

        # Determine target version via official Adobe manifest / WinGet
        $script:TargetVersion = Get-LatestReaderRelease
        if (-not $script:TargetVersion) { $script:TargetVersion = Get-WinGetLatestVersion -Id $winGetId }
        $result.TargetVersion = $script:TargetVersion

        # Check if already current
        if ($script:TargetVersion -and $current -and (Compare-AppVersion -Left $current -Right $script:TargetVersion) -ge 0) {
            $result.Success = $true
            $result.Message = "Already up to date ($current)."
            return $result
        }

        # Build download URLs
        $cleanVer = if ($script:TargetVersion) { $script:TargetVersion -replace '\.' } else { '' }
        $mspUrl = if ($cleanVer) {
            if ($is64) {
                "https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC/$cleanVer/AcrobatDCx64Upd${cleanVer}.msp"
            } else {
                "https://ardownload2.adobe.com/pub/adobe/reader/win/AcrobatDC/$cleanVer/AcroRdrDCUpd${cleanVer}.msp"
            }
        } else { '' }

        $fullExeUrl = if ($cleanVer -and $is64) {
            "https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC/$cleanVer/AcroRdrDCx64${cleanVer}_MUI.exe"
        } else { '' }

        # Check whether local Setup Files cache (Intermediate.cab) is intact for delta MSP patching
        $hasIntermediateCab = $false
        $setupDirs = @(
            "$env:CommonProgramFiles\Adobe\Acrobat\Setup Files",
            "${env:CommonProgramFiles(x86)}\Adobe\Acrobat\Setup Files",
            "$env:CommonProgramFiles\Adobe\Reader\Setup Files",
            "${env:CommonProgramFiles(x86)}\Adobe\Reader\Setup Files"
        )
        foreach ($sDir in $setupDirs) {
            if (Test-Path -LiteralPath $sDir) {
                if (@(Get-ChildItem -Path $sDir -Filter 'Intermediate.cab' -Recurse -ErrorAction SilentlyContinue).Count -gt 0) {
                    $hasIntermediateCab = $true
                    break
                }
            }
        }

        # Simulation Mode
        if ($Simulate) {
            $result.Success = $true
            $sourceDesc = if (-not $hasIntermediateCab -and $fullExeUrl) {
                "direct full installer ($fullExeUrl) [Intermediate.cab missing]"
            } elseif ($mspUrl) {
                "direct MSP ($mspUrl)"
            } else {
                "WinGet ($winGetId)"
            }
            $result.Message = "SIMULATE: would update Adobe Reader via $sourceDesc (current: $current, target: $($script:TargetVersion))."
            return $result
        }

        # --- TIER 1A: Direct Enterprise MSP Patch (if Setup Files cache intact) ---
        if ($hasIntermediateCab -and $mspUrl) {
            try {
                $tempFile = Join-Path ([IO.Path]::GetTempPath()) ("AcroRdrUpd-{0}.msp" -f [guid]::NewGuid().ToString('N'))
                [void](Save-RemoteFile -Uri $mspUrl -OutFile $tempFile)

                Stop-Service -Name 'AdobeARMservice' -Force -ErrorAction SilentlyContinue
                [void](Stop-ProcessSafely -Name $script:ProcessesToStop)

                Write-Log "[$($script:AppName)] Applying Enterprise patch via msiexec (this may take several minutes)..." -Level INFO
                $code = Start-InstallerProcess -FilePath 'msiexec.exe' -Arguments ('/p "{0}" /qn /norestart' -f $tempFile) -LogName 'AdobeReader'
                switch ($code) {
                    0       { $result.Success = $true;  $result.Message = 'Installed via MSP patch.' }
                    3010    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed via MSP patch; reboot required.' }
                    1641    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed via MSP patch; reboot initiated by installer.' }
                    default { throw "msiexec /p exit code $code." }
                }
                if ($result.Success) {
                    [void](Move-DesktopShortcut -Pattern @('*Acrobat*Reader*', 'Adobe Reader*', 'Acrobat.lnk') -SubFolder 'Applications')
                    return $result
                }
            } catch {
                Write-Log "[$($script:AppName)] Direct MSP update failed: $($_.Exception.Message)." -Level WARN
            } finally {
                if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
                    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
                    $tempFile = $null
                }
            }
        } elseif (-not $hasIntermediateCab) {
            Write-Log "[$($script:AppName)] Baseline setup cache missing (Intermediate.cab not found under Setup Files). Using full self-contained installer to avoid Error 1311..." -Level INFO
        }

        # --- TIER 1B: Direct Full Self-Contained Installer (AcroRdrDCx64) ---
        if ($fullExeUrl) {
            try {
                $tempFile = Join-Path ([IO.Path]::GetTempPath()) ("AcroRdrInstaller-{0}.exe" -f [guid]::NewGuid().ToString('N'))
                Write-Log "[$($script:AppName)] Downloading full self-contained installer from $fullExeUrl (~761 MB)..." -Level INFO
                [void](Save-RemoteFile -Uri $fullExeUrl -OutFile $tempFile)

                Stop-Service -Name 'AdobeARMservice' -Force -ErrorAction SilentlyContinue
                [void](Stop-ProcessSafely -Name $script:ProcessesToStop)

                Write-Log "[$($script:AppName)] Running full self-contained installer..." -Level INFO
                $code = Start-InstallerProcess -FilePath $tempFile -Arguments '/sAll /rs /msi EULA_ACCEPT=YES /qn /norestart' -LogName 'AdobeReader'
                switch ($code) {
                    0       { $result.Success = $true;  $result.Message = 'Installed via full self-contained installer.' }
                    3010    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed via full self-contained installer; reboot required.' }
                    1641    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed via full self-contained installer; reboot initiated by installer.' }
                    default { throw "Full installer exit code $code." }
                }
                if ($result.Success) {
                    [void](Move-DesktopShortcut -Pattern @('*Acrobat*Reader*', 'Adobe Reader*', 'Acrobat.lnk') -SubFolder 'Applications')
                    return $result
                }
            } catch {
                Write-Log "[$($script:AppName)] Full installer update failed: $($_.Exception.Message). Falling back to WinGet..." -Level WARN
            } finally {
                if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
                    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
                    $tempFile = $null
                }
            }
        }

        # --- TIER 2: WinGet Fallback Automation ---
        try {
            [void](Stop-ProcessSafely -Name $script:ProcessesToStop)
            $r = Invoke-WinGetUpgrade -Id $winGetId -Simulate:$Simulate
            $result.Success        = [bool]$r.Success
            $result.RebootRequired = [bool]$r.RebootRequired
            $result.Message        = "Direct installers failed; WinGet fallback: $($r.Message)"
            if ($result.Success) {
                [void](Move-DesktopShortcut -Pattern @('*Acrobat*Reader*', 'Adobe Reader*', 'Acrobat.lnk') -SubFolder 'Applications')
            }
            return $result
        } catch {
            $result.Success = $false
            $result.Message = "Direct installers and WinGet fallback failed: $($_.Exception.Message)"
        }
    } catch {
        $result.Success = $false
        $result.Message = "Unhandled error: $($_.Exception.Message)"
    } finally {
        if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
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
