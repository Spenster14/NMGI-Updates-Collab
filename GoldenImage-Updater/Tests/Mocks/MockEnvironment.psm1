#Requires -Version 5.1
# Mock registry / winget / installer / process state for contract tests.
# Mocks work by overriding Core seam functions in the global scope and by pointing
# GIU_WINGET_PATH at a fake winget.cmd. Call Reset-MockEnvironment to restore.

$script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:Root = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
$script:FakeDir = Join-Path ([IO.Path]::GetTempPath()) 'GIU-MockWinget'

function Import-CoreForTest {
    foreach ($m in 'Logging', 'ProcessHelper', 'WinGetWrapper', 'ModuleLoader') {
        Import-Module (Join-Path $script:Root "Core\$m.psm1") -Force -Global -DisableNameChecking
    }
}

function Set-MockRegistry {
    <# Replaces Get-UninstallEntry. -Entries: array of @{ DisplayName=..; DisplayVersion=.. } #>
    param([object[]]$Entries = @())
    $global:GIU_MockEntries = $Entries
    Set-Item -Path Function:\global:Get-UninstallEntry -Value {
        param([string]$DisplayName)
        $global:GIU_MockEntries | Where-Object { $_.DisplayName -like $DisplayName } |
            ForEach-Object { [pscustomobject]@{ DisplayName = $_.DisplayName; DisplayVersion = $_.DisplayVersion; Publisher = 'Mock'; UninstallString = ''; InstallLocation = '' } }
    }
}

function Set-MockWinGet {
    <# Creates fake winget.cmd. Mode: success | fail | reboot | noupdate | timeout. Latest = version reported by 'show'. #>
    param([ValidateSet('success', 'fail', 'reboot', 'noupdate', 'timeout')][string]$Mode = 'success', [string]$Latest = '99.0')
    New-Item -ItemType Directory -Force $script:FakeDir | Out-Null
    if ($Mode -eq 'timeout') {
        $cmd = @"
@echo off
if /i "%1"=="show" (
  echo Found Mock [Mock.Package]
  echo Version: $Latest
  exit /b 0
)
powershell.exe -NoProfile -Command "Start-Sleep -Seconds 10"
exit /b 0
"@
    } else {
        $code = switch ($Mode) { 'success' { '0' } 'fail' { '1' } 'reboot' { '3010' } 'noupdate' { '-1978335189' } }
        $cmd = @"
@echo off
if /i "%1"=="show" (
  echo Found Mock [Mock.Package]
  echo Version: $Latest
  exit /b 0
)
echo Mock winget %*
exit /b $code
"@
    }
    $path = Join-Path $script:FakeDir 'winget.cmd'
    Set-Content -LiteralPath $path -Value $cmd -Encoding ASCII
    $env:GIU_WINGET_PATH = $path
    return $path
}

function Set-MockInstaller {
    <# Replaces download + installer execution. ExitCode is returned by Start-InstallerProcess; Throw simulates a crash. #>
    param([int]$ExitCode = 0, [switch]$Throw)
    $global:GIU_MockInstallerExit = $ExitCode
    $global:GIU_MockInstallerThrow = [bool]$Throw
    Set-Item -Path Function:\global:Save-RemoteFile -Value {
        param([string]$Uri, [string]$OutFile) Set-Content -LiteralPath $OutFile -Value 'mock'; $OutFile
    }
    Set-Item -Path Function:\global:Start-InstallerProcess -Value {
        param([string]$FilePath, [string]$Arguments, [int]$TimeoutMinutes)
        if ($global:GIU_MockInstallerThrow) { throw 'Mock installer crashed.' }
        [int]$global:GIU_MockInstallerExit
    }
    Set-Item -Path Function:\global:Stop-ProcessSafely -Value { param($Name, $GracePeriodSeconds) 0 }
    Set-Item -Path Function:\global:Invoke-RestMethod -Value {
        [pscustomobject]@{ releases = @([pscustomobject]@{ version = '999.0.0.0' }) }
    }
}

function Reset-MockEnvironment {
    Remove-Item Function:\global:Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Item Env:\GIU_WINGET_PATH -ErrorAction SilentlyContinue
    Remove-Item $script:FakeDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable GIU_MockEntries, GIU_MockInstallerExit, GIU_MockInstallerThrow -Scope Global -ErrorAction SilentlyContinue
    Import-CoreForTest
}

Export-ModuleMember -Function Import-CoreForTest, Set-MockRegistry, Set-MockWinGet, Set-MockInstaller, Reset-MockEnvironment

