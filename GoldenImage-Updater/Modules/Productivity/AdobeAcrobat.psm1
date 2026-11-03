#Requires -Version 5.1
<#
    Adobe Acrobat (Pro / Standard) - Production Update Module
    Strategy:
      * Tier 1 (Primary): Direct Adobe Enterprise MSP patch download from official Adobe CDN
        (ardownload2.adobe.com) targeted against Adobe's official Continuous release manifest.
        Applied silently via msiexec.exe /p with verbose logging.
      * Tier 2 (Fallback): WinGet silent automation (Adobe.Acrobat.Pro).
    Rules:
      * Headless execution under NT AUTHORITY\SYSTEM.
      * Suppresses module-level reboots (traps 3010/1641 and defers to orchestrator).
      * Automatically moves desktop shortcuts to C:\Users\Public\Desktop\Applications.
#>

$script:AppName          = 'Adobe Acrobat'
$script:UninstallPattern = 'Adobe*Acrobat*'
$script:WinGetId         = 'Adobe.Acrobat.Pro'
$script:ProcessesToStop  = @('Acrobat', 'AcroRd32', 'AcroCEF', 'AdobeARM', 'AdobeCollabSync', 'armsvc', 'AGSService')
$script:TargetVersion    = ''

function Get-AppMetadata {
    [pscustomobject]@{
        Name      = $script:AppName
        DependsOn = @()
        Priority  = 100
    }
}

function Get-LatestAcrobatRelease {
    <#
    .SYNOPSIS
        Queries Adobe's official Continuous track release manifest directly,
        with fallback to WinGet package repositories.
    #>
    # 1. Official Adobe ARM version manifest (instant, authorative)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $v = (Invoke-WebRequest -Uri 'https://armmf.adobe.com/arm-manifests/mac/AcrobatDC/acrobat/current_version.txt' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop).Content.Trim()
        if ($v -match '^\d{2}\.\d{3}\.\d{5}$') { return $v }
    } catch { }

    # 2. WinGet Adobe.Acrobat.Pro
    try {
        $v = Get-WinGetLatestVersion -Id $script:WinGetId
        if ($v) { return $v }
    } catch { }

    # 3. Fallback to unified 64-bit Continuous track version (Reader & Acrobat share milestone)
    try {
        $v = Get-WinGetLatestVersion -Id 'Adobe.Acrobat.Reader.64-bit'
        if ($v) { return $v }
    } catch { }

    return ''
}

function Get-AcrobatEntry {
    @(Get-UninstallEntry -DisplayName $script:UninstallPattern |
        Where-Object { $_.DisplayName -notmatch '(?i)reader' -and $_.DisplayName -match '(?i)acrobat' }) |
        Select-Object -First 1
}

function Test-Is64BitInstalled {
    $e = Get-AcrobatEntry
    if ($e -and $e.DisplayName -match '64-bit') { return $true }
    if (Test-Path -LiteralPath "$env:ProgramFiles\Adobe\Acrobat DC\Acrobat\Acrobat.exe") { return $true }
    return [System.Environment]::Is64BitOperatingSystem
}

function Test-AppInstalled {
    [CmdletBinding()] [OutputType([bool])] param()
    $e = Get-AcrobatEntry
    if ($e) { return $true }

    # Fallback binary check
    $paths = @(
        "$env:ProgramFiles\Adobe\Acrobat DC\Acrobat\Acrobat.exe",
        "${env:ProgramFiles(x86)}\Adobe\Acrobat DC\Acrobat\Acrobat.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) {
            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($p)
            if ($vi.FileDescription -notmatch '(?i)reader' -and $vi.ProductName -notmatch '(?i)reader') {
                return $true
            }
        }
    }
    return $false
}

function Get-AppVersion {
    [CmdletBinding()] [OutputType([string])] param()
    $e = Get-AcrobatEntry
    if ($e -and $e.DisplayVersion) { return [string]$e.DisplayVersion }

    $paths = @(
        "$env:ProgramFiles\Adobe\Acrobat DC\Acrobat\Acrobat.exe",
        "${env:ProgramFiles(x86)}\Adobe\Acrobat DC\Acrobat\Acrobat.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) {
            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($p)
            if ($vi.FileVersion) { return [string]$vi.FileVersion }
        }
    }
    return ''
}

function Restore-AcrobatSetupCache {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SetupDir)
    $zipUrl = 'https://trials.adobe.com/AdobeProducts/APRO/Acrobat_HelpX/win32/Acrobat_DC_Web_x64_WWMUI.zip'
    $tempZip = Join-Path ([IO.Path]::GetTempPath()) ('AcrobatBase-{0}.zip' -f [guid]::NewGuid().ToString('N'))
    try {
        Write-Log "[$($script:AppName)] Restoring missing cabinet files to local setup cache ($SetupDir)..." -Level INFO
        [void](Save-RemoteFile -Uri $zipUrl -OutFile $tempZip)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
        try {
            foreach ($entry in $zip.Entries) {
                if ($entry.Name -like '*.cab') {
                    $destPath = Join-Path $SetupDir $entry.Name
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destPath, $true)
                }
            }
        } finally {
            $zip.Dispose()
        }
        Write-Log "[$($script:AppName)] Successfully restored base cabinet files to setup cache." -Level INFO
        return $true
    } catch {
        Write-Log "[$($script:AppName)] Failed to restore setup cache: $($_.Exception.Message)" -Level WARN
        return $false
    } finally {
        if (Test-Path -LiteralPath $tempZip) {
            Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-AppUpdate {
    [CmdletBinding()] param([switch]$Simulate)
    $result = [PSCustomObject]@{ Success = $false; RebootRequired = $false; Message = ''; TargetVersion = '' }
    $tempFile = $null

    try {
        $current = Get-AppVersion
        $is64 = Test-Is64BitInstalled

        # Determine target version via official Adobe manifest / WinGet
        $script:TargetVersion = Get-LatestAcrobatRelease
        $result.TargetVersion = $script:TargetVersion

        # Check if already current
        if ($script:TargetVersion -and $current -and (Compare-AppVersion -Left $current -Right $script:TargetVersion) -ge 0) {
            $result.Success = $true
            $result.Message = "Already up to date ($current)."
            return $result
        }

        # Build direct MSP download URL
        $cleanVer = if ($script:TargetVersion) { $script:TargetVersion -replace '\.' } else { '' }
        $mspUrl = if ($cleanVer) {
            if ($is64) {
                "https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC/$cleanVer/AcrobatDCx64Upd${cleanVer}.msp"
            } else {
                "https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC/$cleanVer/AcrobatDCUpd${cleanVer}.msp"
            }
        } else { '' }

        # Simulation Mode
        if ($Simulate) {
            $result.Success = $true
            $sourceDesc = if ($mspUrl) { "direct MSP ($mspUrl)" } else { "WinGet ($($script:WinGetId))" }
            $result.Message = "SIMULATE: would update Adobe Acrobat via $sourceDesc (current: $current, target: $($script:TargetVersion))."
            return $result
        }

        # --- TIER 1: Direct Adobe Enterprise MSP Patch ---
        if ($mspUrl) {
            $cabsRestored = $false
            $guidDir = "$env:CommonProgramFiles\Adobe\Acrobat\Setup Files\{AC76BA86-1033-FFFF-7760-BC15014EA700}"
            try {
                # Pre-flight check: Ensure setup cache has required cabinet files (heals Error 1311)
                if ((Test-Path -LiteralPath $guidDir) -and -not (Test-Path -LiteralPath (Join-Path $guidDir 'Intermediate.cab'))) {
                    Write-Log "[$($script:AppName)] Detected missing Intermediate.cab in setup cache ($guidDir). Auto-restoring base CABs..." -Level INFO
                    $cabsRestored = Restore-AcrobatSetupCache -SetupDir $guidDir
                }

                $tempFile = Join-Path ([IO.Path]::GetTempPath()) ("AcrobatUpd-{0}.msp" -f [guid]::NewGuid().ToString('N'))
                Write-Log "[$($script:AppName)] Downloading Enterprise MSP patch from $mspUrl..." -Level INFO
                [void](Save-RemoteFile -Uri $mspUrl -OutFile $tempFile)

                Stop-Service -Name 'AdobeARMservice' -Force -ErrorAction SilentlyContinue
                [void](Stop-ProcessSafely -Name $script:ProcessesToStop)

                Write-Log "[$($script:AppName)] Applying Enterprise patch via msiexec (this may take several minutes)..." -Level INFO
                $code = Start-InstallerProcess -FilePath 'msiexec.exe' -Arguments ('/p "{0}" /qn /norestart' -f $tempFile) -LogName 'AdobeAcrobat'
                switch ($code) {
                    0       { $result.Success = $true;  $result.Message = 'Installed via MSP patch.' }
                    3010    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed via MSP patch; reboot required.' }
                    1641    { $result.Success = $true;  $result.RebootRequired = $true; $result.Message = 'Installed via MSP patch; reboot initiated by installer.' }
                    default { throw "msiexec /p exit code $code." }
                }
                if ($result.Success) {
                    [void](Move-DesktopShortcut -Pattern @('Adobe Acrobat*', 'Acrobat.lnk') -SubFolder 'Applications')
                    return $result
                }
            } catch {
                Write-Log "[$($script:AppName)] Direct MSP update failed: $($_.Exception.Message). Falling back to WinGet..." -Level WARN
            } finally {
                if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
                    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
                    $tempFile = $null
                }
                if ($cabsRestored -and (Test-Path -LiteralPath $guidDir)) {
                    Write-Log "[$($script:AppName)] Purging temporary cabinet files from setup cache to reclaim disk space (~1.5 GB)..." -Level INFO
                    Get-ChildItem -Path $guidDir -Filter '*.cab' -ErrorAction SilentlyContinue |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # --- TIER 2: WinGet Fallback Automation ---
        try {
            [void](Stop-ProcessSafely -Name $script:ProcessesToStop)
            $r = Invoke-WinGetUpgrade -Id $script:WinGetId -Simulate:$Simulate
            $result.Success        = [bool]$r.Success
            $result.RebootRequired = [bool]$r.RebootRequired
            $result.Message        = "Direct MSP failed; WinGet fallback: $($r.Message)"
            if ($result.Success) {
                [void](Move-DesktopShortcut -Pattern @('Adobe Acrobat*', 'Acrobat.lnk') -SubFolder 'Applications')
            }
            return $result
        } catch {
            $result.Success = $false
            $result.Message = "Direct MSP and WinGet fallback failed: $($_.Exception.Message)"
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
