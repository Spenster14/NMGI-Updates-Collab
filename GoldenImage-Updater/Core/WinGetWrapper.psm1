#Requires -Version 5.1
# SYSTEM-context aware WinGet discovery and runner.

$script:NoApplicableUpdate = -1978335189   # 0x8A15002B
$script:AlreadyInstalled   = -1978335135   # 0x8A150061 (package already installed)
$script:CommonArgs = @('--accept-source-agreements', '--accept-package-agreements', '--silent', '--disable-interactivity')

function Test-IsSystemContext {
    [CmdletBinding()] param()
    return [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
}

function Get-WinGetPath {
    <#
    .SYNOPSIS
        Locates winget.exe. Honors $env:GIU_WINGET_PATH (test override), then searches
        WindowsApps for the newest Microsoft.DesktopAppInstaller_* package (required under SYSTEM,
        where the per-user alias is not on PATH).
    #>
    [CmdletBinding()] param()
    if ($env:GIU_WINGET_PATH -and (Test-Path -LiteralPath $env:GIU_WINGET_PATH)) { return $env:GIU_WINGET_PATH }
    $root = Join-Path $env:ProgramFiles 'WindowsApps'
    $hits = @()
    try {
        $hits = @(Get-ChildItem -Path (Join-Path $root 'Microsoft.DesktopAppInstaller_*') -Directory -ErrorAction Stop |
            ForEach-Object {
                $exe = Join-Path $_.FullName 'winget.exe'
                if (Test-Path -LiteralPath $exe) {
                    $ver = [version]'0.0'
                    if ($_.Name -match '_(\d+(\.\d+){1,3})_') { $ver = [version]$Matches[1] }
                    [pscustomobject]@{ Path = $exe; Version = $ver; Arch = if ($_.Name -match '_x64_') { 1 } else { 0 } }
                }
            })
    } catch { }   # WindowsApps is ACL-restricted for non-elevated users
    if ($hits.Count -gt 0) { return ($hits | Sort-Object Arch, Version -Descending | Select-Object -First 1).Path }
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-WinGet {
    <#
    .SYNOPSIS
        Runs winget with the given arguments plus silent/non-interactive flags.
        Enforces execution timeout and safe process termination.
    .OUTPUTS
        [pscustomobject] ExitCode, Output (string[]), Context
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$NoCommonArgs,
        [int]$TimeoutSeconds = 300
    )
    if ($env:GIU_WINGET_TIMEOUT_SECONDS) {
        $parsed = 0
        if ([int]::TryParse($env:GIU_WINGET_TIMEOUT_SECONDS, [ref]$parsed) -and $parsed -gt 0) {
            $TimeoutSeconds = $parsed
        }
    }
    $exe = Get-WinGetPath
    if (-not $exe) { throw 'winget.exe could not be located (App Installer not provisioned on this machine).' }
    $isSystem = Test-IsSystemContext
    $all = @($Arguments)
    if (-not $NoCommonArgs) {
        $cmd = if ($Arguments.Count -gt 0) { [string]$Arguments[0] } else { '' }
        if ($cmd -in 'show', 'search', 'list') {
            $all += @('--accept-source-agreements', '--disable-interactivity')
        } else {
            $all += $script:CommonArgs
        }
    }
    # Under SYSTEM there is no user profile: force machine scope for install/upgrade.
    if ($isSystem -and $Arguments[0] -in 'install', 'upgrade' -and $all -notcontains '--scope') { $all += @('--scope', 'machine') }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($exe -match '\.(cmd|bat)$') {
        $psi.FileName = $env:ComSpec
        $escaped = ($all | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' '
        $psi.Arguments = ('/c "{0}" {1}' -f $exe, $escaped)
    } else {
        $psi.FileName = $exe
        $escaped = ($all | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' '
        $psi.Arguments = $escaped
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdOutTask = $proc.StandardOutput.ReadToEndAsync()
    $stdErrTask = $proc.StandardError.ReadToEndAsync()

    $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) {
        try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        throw "winget.exe execution timed out after $TimeoutSeconds seconds."
    }
    $proc.WaitForExit()
    $code = [int]$proc.ExitCode
    $outText = [string]$stdOutTask.Result
    $errText = [string]$stdErrTask.Result
    $output = @()
    if ($outText) { $output += ($outText -split "`r?`n") }
    if ($errText) { $output += ($errText -split "`r?`n") }
    $output = @($output | Where-Object { $_ -ne '' })
    [pscustomobject]@{ ExitCode = $code; Output = $output; Context = $(if ($isSystem) { 'SYSTEM' } else { 'Interactive' }) }
}

function Get-WinGetLatestVersion {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Id, [int]$TimeoutSeconds = 60)
    try {
        $r = Invoke-WinGet -Arguments @('show', '--id', $Id, '--exact') -TimeoutSeconds $TimeoutSeconds
        if ($r.ExitCode -ne 0) { return '' }
        foreach ($l in $r.Output) { if ($l -match '^\s*Version:\s*(\S+)') { return $Matches[1] } }
    } catch { }
    return ''
}

function Invoke-WinGetUpgrade {
    <#
    .SYNOPSIS
        Upgrades a package by exact id and normalizes the result. Never throws.
    .OUTPUTS
        [pscustomobject] Success, RebootRequired, NoUpdate, ExitCode, Message
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [switch]$Simulate, [int]$TimeoutSeconds = 300)
    if ($Simulate) {
        return [pscustomobject]@{ Success = $true; RebootRequired = $false; NoUpdate = $false; ExitCode = 0; Message = "SIMULATE: would run winget upgrade --id $Id" }
    }
    try {
        $r = Invoke-WinGet -Arguments @('upgrade', '--id', $Id, '--exact', '--include-unknown') -TimeoutSeconds $TimeoutSeconds
    } catch {
        return [pscustomobject]@{ Success = $false; RebootRequired = $false; NoUpdate = $false; ExitCode = -1; Message = $_.Exception.Message }
    }
    $tail = ($r.Output | Select-Object -Last 3) -join ' | '
    switch ($r.ExitCode) {
        0                      { $o = @($true, $false, $false, 'Upgrade completed.') }
        3010                   { $o = @($true, $true, $false, 'Upgrade completed; reboot required.') }
        $script:NoApplicableUpdate { $o = @($true, $false, $true, 'Already up to date.') }
        $script:AlreadyInstalled   { $o = @($true, $false, $true, 'Already installed.') }
        default                { $o = @($false, $false, $false, "winget exit code $($r.ExitCode): $tail") }
    }
    [pscustomobject]@{ Success = $o[0]; RebootRequired = $o[1]; NoUpdate = $o[2]; ExitCode = $r.ExitCode; Message = $o[3] }
}

Export-ModuleMember -Function Test-IsSystemContext, Get-WinGetPath, Invoke-WinGet, Get-WinGetLatestVersion, Invoke-WinGetUpgrade
