#Requires -Version 5.1
<#
    APP MODULE TEMPLATE - GOLDEN IMAGE HEADLESS PATCHING
    ---------------------------------------------------
    1. Copy this file to Modules\<Category>\<AppName>.psm1 (no leading underscore).
    2. Edit the CONFIG block and the bodies of the four contract functions.
    3. Do NOT edit Start-ImageUpdate.ps1 or anything in Core\.
    4. Run  Tests\ModuleContract.Tests.ps1  before committing.

    HEADLESS UPDATE STRATEGY:
    -------------------------
    * TIER 1 (PRIMARY - PREFERRED): Direct Vendor Headless Update
      - Download latest installer directly from vendor CDN (e.g. enterprise MSI/EXE).
      - Execute silently with /qn, /s, /silent and ALWAYS specify /norestart.
      - Benefit: Zero repository manifest lag; ensures the Golden Image has the exact
        latest security patches immediately.
      - See: Modules\Browsers\GoogleChrome.psm1 for reference.

    * TIER 2 (FALLBACK): WinGet Silent Automation
      - Use WinGet (Invoke-WinGetUpgrade) when direct vendor headless URLs/APIs are
        unavailable or if the primary vendor download/install fails.
      - Enforces SYSTEM-context path resolution, machine scope, and non-interactivity.
      - See: Modules\Utilities\7-Zip.psm1 for reference.

    * TIER 3 (SPECIALTY): Tax & Accounting Suites (Intuit, Thomson Reuters, Wolters Kluwer)
      - Specialized vendor CLI utilities (e.g., UltraTax CS Update, CCH ProSystem fx
        update executables, Lacerte update tools) running from local cache or network share.

    GENERAL RULES:
      * Never reboot. Never pass /restart; use /norestart. Signal reboots via RebootRequired.
      * Honor -Simulate: make NO system changes when -Simulate ($WhatIf) is present.
      * Invoke-AppUpdate must not throw; catch all exceptions and return Success = $false.
      * Available Core helpers: Write-Log, Get-UninstallEntry, Compare-AppVersion, Stop-ProcessSafely,
        Start-InstallerProcess, Save-RemoteFile, Invoke-WinGetUpgrade, Get-WinGetLatestVersion.
#>

# ---- CONFIG ---------------------------------------------------------------
$script:AppName         = 'Example App'
$script:UninstallName   = 'Example App*'       # -like pattern against registry DisplayName
$script:WinGetId        = 'Vendor.ExampleApp'  # Fallback WinGet package ID (or $null if direct-only)
$script:DirectMsiUrl    = ''                   # Primary direct vendor URL (if available)
$script:ProcessesToStop = @('exampleapp')
$script:TargetVersion   = ''
# ---------------------------------------------------------------------------

function Get-AppMetadata {
    # Optional. DependsOn lists other module names that must run first (e.g. '.NET Framework').
    [pscustomobject]@{ Name = $script:AppName; DependsOn = @(); Priority = 100 }
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
    
    try {
        if (-not $Simulate) { [void](Stop-ProcessSafely -Name $script:ProcessesToStop) }

        # --- TIER 1: Direct Vendor Headless Update (Preferred) ---
        if ($script:DirectMsiUrl) {
            if ($Simulate) {
                $result.Success = $true
                $result.Message = "SIMULATE: would download $($script:DirectMsiUrl) and execute silent installer."
                return $result
            }
            $tempFile = Join-Path ([IO.Path]::GetTempPath()) ("$($script:AppName)-update.msi")
            try {
                [void](Save-RemoteFile -Uri $script:DirectMsiUrl -OutFile $tempFile)
                $code = Start-InstallerProcess -FilePath 'msiexec.exe' -Arguments ('/i "{0}" /qn /norestart' -f $tempFile) -LogName $script:AppName
                switch ($code) {
                    0    { $result.Success = $true; $result.Message = 'Direct vendor install succeeded.' }
                    3010 { $result.Success = $true; $result.RebootRequired = $true; $result.Message = 'Direct vendor install succeeded (reboot required).' }
                    default { throw "Direct installer exited with code $code" }
                }
                return $result
            } catch {
                # Direct install failed: proceed to Tier 2 WinGet fallback
                Write-Log "[$($script:AppName)] Primary direct vendor update failed: $($_.Exception.Message). Falling back to WinGet." -Level WARN
            } finally {
                Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            }
        }

        # --- TIER 2: WinGet Fallback Automation ---
        if ($script:WinGetId) {
            $script:TargetVersion = Get-WinGetLatestVersion -Id $script:WinGetId
            $result.TargetVersion = $script:TargetVersion
            $r = Invoke-WinGetUpgrade -Id $script:WinGetId -Simulate:$Simulate
            $result.Success        = [bool]$r.Success
            $result.RebootRequired = [bool]$r.RebootRequired
            $result.Message        = [string]$r.Message
            return $result
        }

        $result.Success = $false
        $result.Message = 'No valid update method configured (neither direct URL nor WinGet ID).'
    } catch {
        $result.Success = $false
        $result.Message = "Unhandled error: $($_.Exception.Message)"
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
