#Requires -Version 5.1
# Dependency-free contract + mock test runner (works regardless of installed Pester version).
# Usage: powershell -File Tests\ModuleContract.Tests.ps1   (exit 0 = all pass)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'Mocks\MockEnvironment.psm1') -Force -DisableNameChecking
Import-CoreForTest

$script:pass = 0; $script:fail = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:pass++; Write-Host "[PASS] $Name" }
    catch { $script:fail++; Write-Host "[FAIL] $Name -> $($_.Exception.Message)" }
}
function Assert([bool]$Cond, [string]$Msg = 'assertion failed') { if (-not $Cond) { throw $Msg } }
function Invoke-Fn($Mod, [string]$Fn, [hashtable]$Params = @{}) { & $Mod.ExportedCommands[$Fn] @Params }

$files = [ordered]@{
    'App.template'            = Join-Path $root 'Modules\_Template\App.template.psm1'
    'GoogleChrome'            = Join-Path $root 'Modules\Browsers\GoogleChrome.psm1'
    'MicrosoftEdge'           = Join-Path $root 'Modules\Browsers\MicrosoftEdge.psm1'
    'MozillaFirefox'          = Join-Path $root 'Modules\Browsers\MozillaFirefox.psm1'
    '7-Zip'                   = Join-Path $root 'Modules\Utilities\7-Zip.psm1'
    'MicrosoftEdgeWebView2'   = Join-Path $root 'Modules\Runtimes\MicrosoftEdgeWebView2.psm1'
    'MicrosoftWindowsUpdates' = Join-Path $root 'Modules\Productivity\MicrosoftWindowsUpdates.psm1'
    'AdobeReader'             = Join-Path $root 'Modules\Productivity\AdobeReader.psm1'
    'AdobeAcrobat'            = Join-Path $root 'Modules\Productivity\AdobeAcrobat.psm1'
    'MicrosoftDotNetFramework' = Join-Path $root 'Modules\Runtimes\MicrosoftDotNetFramework.psm1'
    'MicrosoftOffice365'      = Join-Path $root 'Modules\Productivity\MicrosoftOffice365.psm1'
    'ThomsonUltraTaxCS'       = Join-Path $root 'Modules\TaxAccounting\ThomsonReuters\ThomsonUltraTaxCS.psm1'
}
$required = 'Test-AppInstalled', 'Get-AppVersion', 'Invoke-AppUpdate', 'Test-UpdateSuccess'
$mods = @{}
foreach ($k in $files.Keys) { $mods[$k] = Import-Module $files[$k] -Force -PassThru -DisableNameChecking }

# --- 1. Exports ---
foreach ($k in $files.Keys) {
    foreach ($fn in $required) {
        Test-Case "$k exports $fn" { Assert $mods[$k].ExportedCommands.ContainsKey($fn) "missing $fn" }
    }
}
Test-Case 'Loader flags contract violations' {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'giu-bad.psm1'
    Set-Content $tmp 'function Test-AppInstalled { $true }; Export-ModuleMember -Function Test-AppInstalled'
    $d = Import-AppModule -File (Get-Item $tmp)
    Remove-Item $tmp -Force
    Assert ($d.Error -like '*Contract violation*') "expected violation, got '$($d.Error)'"
}
Test-Case 'Loader skips _Template and finds reference modules' {
    $names = @(Get-AppModuleFile -ModulesRoot (Join-Path $root 'Modules') | ForEach-Object BaseName)
    Assert ($names -contains 'GoogleChrome' -and $names -contains '7-Zip' -and $names -notcontains 'App.template') ($names -join ',')
}
Test-Case 'Dependency ordering honors DependsOn' {
    $a = [pscustomobject]@{ Name = 'A'; DependsOn = @('B'); Priority = 1; Error = $null }
    $b = [pscustomobject]@{ Name = 'B'; DependsOn = @(); Priority = 200; Error = $null }
    $o = @(Get-AppModuleOrder -Descriptors @($a, $b))
    Assert ($o[0].Name -eq 'B' -and $o[1].Name -eq 'A') 'B should precede A'
}

# --- 2. Schema + behaviour with mocks ---
function Assert-Schema($r) {
    $p = $r.PSObject.Properties.Name
    foreach ($n in 'Success', 'RebootRequired', 'Message', 'TargetVersion') { Assert ($p -contains $n) "missing property $n" }
    Assert ($r.Success -is [bool] -and $r.RebootRequired -is [bool]) 'Success/RebootRequired must be [bool]'
    Assert ($r.Message -is [string] -and $r.TargetVersion -is [string]) 'Message/TargetVersion must be [string]'
}

Set-MockRegistry -Entries @(@{ DisplayName = '7-Zip 23.01 (x64)'; DisplayVersion = '23.01' }, @{ DisplayName = 'Google Chrome'; DisplayVersion = '100.0.0.1' })
Test-Case 'Mock registry: Test-AppInstalled true / Get-AppVersion' {
    foreach ($k in '7-Zip', 'GoogleChrome') {
        Assert ([bool](Invoke-Fn $mods[$k] 'Test-AppInstalled') -eq $true) "$k not detected"
        Assert ((Invoke-Fn $mods[$k] 'Get-AppVersion') -is [string]) 'version not string'
    }
    Assert ((Invoke-Fn $mods['7-Zip'] 'Get-AppVersion') -eq '23.01') '7-Zip version'
}
Test-Case 'Mock registry: not installed -> false' {
    Set-MockRegistry -Entries @()
    Assert ((Invoke-Fn $mods['GoogleChrome'] 'Test-AppInstalled') -eq $false) 'should be false'
    Set-MockRegistry -Entries @(@{ DisplayName = '7-Zip 23.01 (x64)'; DisplayVersion = '23.01' }, @{ DisplayName = 'Google Chrome'; DisplayVersion = '100.0.0.1' })
}

$env:GIU_7ZIP_METHOD = 'WinGetOnly'
[void](Set-MockWinGet -Mode success -Latest '24.08')
Test-Case '7-Zip winget success schema' {
    $r = Invoke-Fn $mods['7-Zip'] 'Invoke-AppUpdate'; Assert-Schema $r
    Assert ($r.Success -and -not $r.RebootRequired -and $r.TargetVersion -eq '24.08') "got $($r | ConvertTo-Json -Compress)"
}
Test-Case '7-Zip Test-UpdateSuccess false while below target' {
    Assert ((Invoke-Fn $mods['7-Zip'] 'Test-UpdateSuccess') -eq $false) 'should be false (23.01 < 24.08)'
}
Test-Case '7-Zip Test-UpdateSuccess true once version reached' {
    Set-MockRegistry -Entries @(@{ DisplayName = '7-Zip 24.08 (x64)'; DisplayVersion = '24.08' })
    Assert ((Invoke-Fn $mods['7-Zip'] 'Test-UpdateSuccess') -eq $true) 'should be true'
}
Test-Case '7-Zip winget reboot (3010) propagates' {
    [void](Set-MockWinGet -Mode reboot)
    $r = Invoke-Fn $mods['7-Zip'] 'Invoke-AppUpdate'; Assert-Schema $r
    Assert ($r.Success -and $r.RebootRequired) 'expected success + reboot'
}
Test-Case '7-Zip winget no-applicable-update treated as success' {
    [void](Set-MockWinGet -Mode noupdate)
    $r = Invoke-Fn $mods['7-Zip'] 'Invoke-AppUpdate'; Assert-Schema $r
    Assert ($r.Success -and -not $r.RebootRequired) 'expected success'
}
Test-Case '7-Zip failing winget returns Success=$false, does not throw' {
    [void](Set-MockWinGet -Mode fail)
    $r = Invoke-Fn $mods['7-Zip'] 'Invoke-AppUpdate'; Assert-Schema $r
    Assert ($r.Success -eq $false -and $r.Message -like '*exit code 1*') $r.Message
}
Test-Case '7-Zip missing winget returns Success=$false, does not throw' {
    $env:GIU_WINGET_PATH = Join-Path $env:TEMP 'does-not-exist.exe'
    $saved = $env:ProgramFiles; $savedPath = $env:PATH
    try {
        # Hide any real winget (WindowsApps + PATH alias) so this test can never touch the host.
        $env:ProgramFiles = Join-Path $env:TEMP 'nowhere'
        $env:PATH = Join-Path $env:TEMP 'nowhere'
        $r = Invoke-Fn $mods['7-Zip'] 'Invoke-AppUpdate'; Assert-Schema $r
        Assert ($r.Success -eq $false -and $r.Message -like '*winget.exe could not be located*') $r.Message
    } finally { $env:ProgramFiles = $saved; $env:PATH = $savedPath }
}
Test-Case '7-Zip -Simulate makes no winget upgrade call' {
    [void](Set-MockWinGet -Mode fail)   # would fail if upgrade were actually invoked
    $r = Invoke-Fn $mods['7-Zip'] 'Invoke-AppUpdate' @{ Simulate = $true }; Assert-Schema $r
    Assert ($r.Success -and $r.Message -like 'SIMULATE*') $r.Message
}
Test-Case '7-Zip winget timeout enforced and caught safely' {
    [void](Set-MockWinGet -Mode timeout)
    $env:GIU_WINGET_TIMEOUT_SECONDS = '2'
    try {
        $r = Invoke-Fn $mods['7-Zip'] 'Invoke-AppUpdate'; Assert-Schema $r
        Assert ($r.Success -eq $false -and $r.Message -like '*timed out*') $r.Message
    } finally {
        Remove-Item Env:\GIU_WINGET_TIMEOUT_SECONDS -ErrorAction SilentlyContinue
    }
}
Remove-Item Env:\GIU_7ZIP_METHOD -ErrorAction SilentlyContinue

Set-MockInstaller -ExitCode 0
Test-Case 'Chrome success schema' {
    $r = Invoke-Fn $mods['GoogleChrome'] 'Invoke-AppUpdate'; Assert-Schema $r
    Assert ($r.Success -and $r.TargetVersion -eq '999.0.0.0') "got $($r | ConvertTo-Json -Compress)"
}
Test-Case 'Chrome MSI 3010 -> RebootRequired' {
    Set-MockInstaller -ExitCode 3010
    $r = Invoke-Fn $mods['GoogleChrome'] 'Invoke-AppUpdate'; Assert-Schema $r
    Assert ($r.Success -and $r.RebootRequired) 'expected reboot'
}
Test-Case 'Chrome failing installer -> Success=$false' {
    Set-MockInstaller -ExitCode 1603
    $r = Invoke-Fn $mods['GoogleChrome'] 'Invoke-AppUpdate'; Assert-Schema $r
    Assert ($r.Success -eq $false -and $r.Message -like '*1603*') $r.Message
}
Test-Case 'Chrome crashing installer (exception) -> Success=$false, no throw' {
    Set-MockInstaller -Throw
    $r = Invoke-Fn $mods['GoogleChrome'] 'Invoke-AppUpdate'; Assert-Schema $r
    Assert ($r.Success -eq $false -and $r.Message -like '*crashed*') $r.Message
}
Test-Case 'Chrome -Simulate performs no install' {
    Set-MockInstaller -Throw   # would throw if installer called
    $r = Invoke-Fn $mods['GoogleChrome'] 'Invoke-AppUpdate' @{ Simulate = $true }; Assert-Schema $r
    Assert ($r.Success -and $r.Message -like 'SIMULATE*') $r.Message
}
Test-Case 'Edge -Simulate performs no install' {
    Set-MockInstaller -Throw   # would throw if installer called
    $r = Invoke-Fn $mods['MicrosoftEdge'] 'Invoke-AppUpdate' @{ Simulate = $true }; Assert-Schema $r
    Assert ($r.Success -and $r.Message -like 'SIMULATE*') $r.Message
}
Test-Case 'Firefox -Simulate performs no install' {
    Set-MockInstaller -Throw   # would throw if installer called
    $r = Invoke-Fn $mods['MozillaFirefox'] 'Invoke-AppUpdate' @{ Simulate = $true }; Assert-Schema $r
    Assert ($r.Success -and $r.Message -like 'SIMULATE*') $r.Message
}
Test-Case 'WebView2 -Simulate performs no install' {
    Set-MockInstaller -Throw   # would throw if installer called
    $r = Invoke-Fn $mods['MicrosoftEdgeWebView2'] 'Invoke-AppUpdate' @{ Simulate = $true }; Assert-Schema $r
    Assert ($r.Success -and $r.Message -like 'SIMULATE*') $r.Message
}
Test-Case 'Windows Updates -Simulate returns valid schema' {
    $r = Invoke-Fn $mods['MicrosoftWindowsUpdates'] 'Invoke-AppUpdate' @{ Simulate = $true }; Assert-Schema $r
    Assert ($r.Success -and ($r.Message -like 'SIMULATE*' -or $r.Message -like 'Already up to date*')) $r.Message
}
Test-Case 'AdobeReader -Simulate performs no install' {
    Set-MockInstaller -Throw   # would throw if installer called
    $r = Invoke-Fn $mods['AdobeReader'] 'Invoke-AppUpdate' @{ Simulate = $true }; Assert-Schema $r
    Assert ($r.Success -and ($r.Message -like 'SIMULATE*' -or $r.Message -like 'Already up to date*')) $r.Message
}
Test-Case 'AdobeAcrobat -Simulate performs no install' {
    Set-MockInstaller -Throw   # would throw if installer called
    $r = Invoke-Fn $mods['AdobeAcrobat'] 'Invoke-AppUpdate' @{ Simulate = $true }; Assert-Schema $r
    Assert ($r.Success -and ($r.Message -like 'SIMULATE*' -or $r.Message -like 'Already up to date*')) $r.Message
}
Test-Case 'MicrosoftDotNetFramework -Simulate performs no install' {
    Set-MockInstaller -Throw   # would throw if installer called
    $r = Invoke-Fn $mods['MicrosoftDotNetFramework'] 'Invoke-AppUpdate' @{ Simulate = $true }; Assert-Schema $r
    Assert ($r.Success -and ($r.Message -like 'SIMULATE*' -or $r.Message -like 'Already up to date*')) $r.Message
}
Test-Case 'MicrosoftOffice365 -Simulate performs no install' {
    Set-MockInstaller -Throw   # would throw if installer called
    $r = Invoke-Fn $mods['MicrosoftOffice365'] 'Invoke-AppUpdate' @{ Simulate = $true }; Assert-Schema $r
    Assert ($r.Success -and ($r.Message -like 'SIMULATE*' -or $r.Message -like 'Already up to date*')) $r.Message
}
Test-Case 'ThomsonUltraTaxCS -Simulate performs no install' {
    Set-MockInstaller -Throw   # would throw if installer called
    $r = Invoke-Fn $mods['ThomsonUltraTaxCS'] 'Invoke-AppUpdate' @{ Simulate = $true }; Assert-Schema $r
    Assert ($r.Success -and ($r.Message -like 'SIMULATE*' -or $r.Message -like 'No supported UltraTax*')) $r.Message
}
Test-Case 'Template Invoke-AppUpdate returns schema even on error' {
    [void](Set-MockWinGet -Mode fail)
    $r = Invoke-Fn $mods['App.template'] 'Invoke-AppUpdate'; Assert-Schema $r
    Assert ($r.Success -eq $false) 'expected failure'
}
Test-Case 'Template falls back to WinGet when direct download is not configured' {
    [void](Set-MockWinGet -Mode success -Latest '1.0.0')
    $r = Invoke-Fn $mods['App.template'] 'Invoke-AppUpdate'; Assert-Schema $r
    Assert ($r.Success -and $r.Message -eq 'Upgrade completed.') $r.Message
}
Test-Case 'Move-DesktopShortcut relocates shortcuts into subfolder' {
    $tempDesk = Join-Path ([IO.Path]::GetTempPath()) ("giu-desk-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDesk -Force | Out-Null
    try {
        $f1 = Join-Path $tempDesk 'Firefox.lnk'; Set-Content $f1 'mock'
        $f2 = Join-Path $tempDesk 'Google Chrome.lnk'; Set-Content $f2 'mock'
        $f3 = Join-Path $tempDesk 'Unrelated.txt'; Set-Content $f3 'mock'
        
        $moved = Move-DesktopShortcut -Pattern @('Firefox*', 'Google Chrome*') -SubFolder 'Applications' -DesktopPath $tempDesk
        Assert ($moved -eq 2) "expected 2 moved, got $moved"
        Assert (Test-Path (Join-Path $tempDesk 'Applications\Firefox.lnk')) 'Firefox.lnk not moved'
        Assert (Test-Path (Join-Path $tempDesk 'Applications\Google Chrome.lnk')) 'Chrome.lnk not moved'
        Assert (Test-Path $f3) 'Unrelated.txt should remain on desktop root'
    } finally {
        Remove-Item $tempDesk -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- 3. Orchestrator isolation: a failing module must not halt others ---
Test-Case 'Orchestrator continues past failing module (exit 1, others run)' {
    Reset-MockEnvironment
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("giu-orch-" + [guid]::NewGuid().ToString('N'))
    $modDir = Join-Path $tmp 'Modules\X'; New-Item -ItemType Directory $modDir -Force | Out-Null
    $common = 'function Get-AppVersion { "1.0" }; function Test-UpdateSuccess { $true }; function Test-AppInstalled { $true };'
    Set-Content (Join-Path $modDir 'A-Throws.psm1') ($common + 'function Invoke-AppUpdate { throw "boom" }; Export-ModuleMember -Function *')
    Set-Content (Join-Path $modDir 'B-Fails.psm1')  ($common + 'function Invoke-AppUpdate { [pscustomobject]@{Success=$false;RebootRequired=$false;Message="bad";TargetVersion=""} }; Export-ModuleMember -Function *')
    Set-Content (Join-Path $modDir 'C-Reboot.psm1') ($common + 'function Invoke-AppUpdate { [pscustomobject]@{Success=$true;RebootRequired=$true;Message="ok";TargetVersion="2"} }; Export-ModuleMember -Function *')
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Start-ImageUpdate.ps1') -ModulesPath (Join-Path $tmp 'Modules') -LogDirectory (Join-Path $tmp 'logs') 2>&1 | Out-String
    $code = $LASTEXITCODE
    Assert ($code -eq 1) "expected exit 1, got $code`n$out"
    Assert ($out -match 'C-Reboot\s+Yes.*Updated\s+Yes' -or $out -match 'C-Reboot') 'C module did not run'
    Assert ($out -match 'A-Throws' -and $out -match 'B-Fails') 'summary missing modules'
    # Reboot-only run
    Remove-Item (Join-Path $modDir 'A-Throws.psm1'), (Join-Path $modDir 'B-Fails.psm1')
    [void](& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Start-ImageUpdate.ps1') -ModulesPath (Join-Path $tmp 'Modules') -LogDirectory (Join-Path $tmp 'logs') 2>&1)
    Assert ($LASTEXITCODE -eq 3010) "expected 3010, got $LASTEXITCODE"
    # IncludeOnly / Exclude
    [void](& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Start-ImageUpdate.ps1') -ModulesPath (Join-Path $tmp 'Modules') -LogDirectory (Join-Path $tmp 'logs') -Exclude 'C-Reboot' 2>&1)
    Assert ($LASTEXITCODE -eq 0) "Exclude run expected 0, got $LASTEXITCODE"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Reset-MockEnvironment
Write-Host ("`nContract tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
