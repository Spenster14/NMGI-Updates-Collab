#Requires -Version 5.1
# Process inspection/termination, installer execution, download and uninstall-registry helpers.
# These are the seams the test harness overrides to avoid touching the real system.

function Get-RunningProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Name)
    $Name | ForEach-Object { Get-Process -Name ($_ -replace '\.exe$', '') -ErrorAction SilentlyContinue }
}

function Stop-ProcessSafely {
    <#
    .SYNOPSIS
        Gracefully closes (CloseMainWindow) then force-kills processes by name. Returns count stopped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [int]$GracePeriodSeconds = 10
    )
    $procs = @(Get-RunningProcess -Name $Name)
    if ($procs.Count -eq 0) { return 0 }
    foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch { } }
    $deadline = (Get-Date).AddSeconds($GracePeriodSeconds)
    while ((Get-Date) -lt $deadline -and @($procs | Where-Object { -not $_.HasExited }).Count -gt 0) { Start-Sleep -Milliseconds 500 }
    $stopped = 0
    foreach ($p in $procs) {
        try {
            if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction Stop }
            $stopped++
        } catch { }
    }
    return $stopped
}

function Enable-GlobalMsiLogging {
    <#
    .SYNOPSIS
        Enables system-wide Windows Installer verbose logging policy in HKLM.
        Ensures even nested or wrapped MSIs (WinGet, setup.exe bootstrappers) write debug logs.
    #>
    [CmdletBinding()]
    param([string]$Policy = 'voicewarmupx')
    try {
        $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer'
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Set-ItemProperty -Path $path -Name 'Logging' -Value $Policy -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Start-InstallerProcess {
    <#
    .SYNOPSIS
        Runs an installer hidden, waits (with timeout), returns the exit code as [int].
        Automatically injects verbose MSI logging (/l*v) for any msiexec or .msi invocation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [int]$TimeoutMinutes = 30,
        [string]$LogName
    )
    # Check if this invocation is an MSI installer
    $isMsi = ($FilePath -match 'msiexec(\.exe)?$' -or $FilePath -match '\.msi$')
    if ($isMsi -and ($Arguments -notmatch '(?i)(/|-)l(\*v)?\b') -and ($Arguments -notmatch '(?i)(/|-)log\b')) {
        $logDir = 'C:\ProgramData\GoldenImageUpdater\Logs'
        if (Get-Command Get-LogPath -ErrorAction SilentlyContinue) {
            $activeLog = Get-LogPath
            if ($activeLog) { $logDir = Split-Path $activeLog -Parent }
        }
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        
        $tag = if ($LogName) {
            $LogName -replace '[^a-zA-Z0-9_\-]', ''
        } elseif ($Arguments -match '["'']?([^"''\r\n]+\.msi)["'']?') {
            [System.IO.Path]::GetFileNameWithoutExtension($Matches[1]) -replace '[^a-zA-Z0-9_\-]', ''
        } else {
            'Install'
        }
        $msiLog = Join-Path $logDir ("MSI-{0}-{1}.log" -f $tag, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $Arguments = "$Arguments /l*v `"$msiLog`"".Trim()
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Injected MSI verbose logging: $msiLog" -Level DEBUG
        }
    }

    $params = @{ FilePath = $FilePath; PassThru = $true; WindowStyle = 'Hidden' }
    if ($Arguments) { $params.ArgumentList = $Arguments }
    $p = Start-Process @params
    if (-not $p.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        try { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } catch { }
        try { if (-not $p.HasExited) { $p.Kill() } } catch { }
        throw "Installer '$FilePath' timed out after $TimeoutMinutes minutes."
    }
    return [int]$p.ExitCode
}

function Save-RemoteFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$OutFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop }
    finally { $ProgressPreference = $old }
    if (-not (Test-Path -LiteralPath $OutFile)) { throw "Download of $Uri failed." }
    return $OutFile
}

function Get-UninstallEntry {
    <#
    .SYNOPSIS
        Searches 64/32-bit uninstall registry hives for DisplayName matching a -like pattern.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DisplayName)
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher, UninstallString, InstallLocation
}

function Compare-AppVersion {
    <#
    .SYNOPSIS
        Returns -1/0/1 comparing two version strings (tolerates non-numeric suffixes).
    #>
    [CmdletBinding()]
    param([string]$Left, [string]$Right)
    function ConvertTo-Ver([string]$s) {
        $m = [regex]::Match($s, '\d+(\.\d+){0,3}')
        if (-not $m.Success) { return [version]'0.0' }
        $v = $m.Value; if ($v -notmatch '\.') { $v += '.0' }
        return [version]$v
    }
    return (ConvertTo-Ver $Left).CompareTo((ConvertTo-Ver $Right))
}

function Move-DesktopShortcut {
    <#
    .SYNOPSIS
        Moves matching desktop shortcuts (.lnk/.url) from Public Desktop
        into a subfolder (e.g. 'Applications') to keep the Golden Image desktop organized.
    .PARAMETER Pattern
        Pattern of the shortcut file to match, e.g. 'Firefox*' or @('Google Chrome*', 'Firefox*').
    .PARAMETER SubFolder
        The subfolder under Public Desktop. Defaults to 'Applications'.
    .PARAMETER DesktopPath
        Override the desktop root path (defaults to CommonDesktopDirectory / C:\Users\Public\Desktop).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Pattern,
        [string]$SubFolder = 'Applications',
        [string]$DesktopPath
    )
    $publicDesktop = if ($DesktopPath) { $DesktopPath } else { [Environment]::GetFolderPath('CommonDesktopDirectory') }
    if (-not $publicDesktop -or -not (Test-Path -LiteralPath $publicDesktop)) {
        $publicDesktop = 'C:\Users\Public\Desktop'
    }
    if (-not (Test-Path -LiteralPath $publicDesktop)) { return 0 }

    $destDir = Join-Path $publicDesktop $SubFolder
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $moved = 0
    foreach ($pat in $Pattern) {
        $filter = if ($pat -match '\.(lnk|url)$') { $pat } else { "$pat.lnk" }
        $shortcuts = @(Get-ChildItem -LiteralPath $publicDesktop -Filter $filter -File -ErrorAction SilentlyContinue)
        if ($shortcuts.Count -eq 0) {
            $shortcuts = @(Get-ChildItem -LiteralPath $publicDesktop -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like $pat -or $_.Name -like "$pat.lnk" -or $_.Name -like "$pat.url" })
        }
        foreach ($s in $shortcuts) {
            # Skip if file is already inside destination directory
            if ($s.DirectoryName -eq $destDir) { continue }
            try {
                $destFile = Join-Path $destDir $s.Name
                Move-Item -LiteralPath $s.FullName -Destination $destFile -Force -ErrorAction Stop
                $moved++
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log "Moved desktop shortcut '$($s.Name)' -> '$destDir'" -Level INFO
                }
            } catch {
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log "Failed to move desktop shortcut '$($s.Name)': $($_.Exception.Message)" -Level WARN
                }
            }
        }
    }
    return $moved
}

Export-ModuleMember -Function Get-RunningProcess, Stop-ProcessSafely, Start-InstallerProcess, Save-RemoteFile, Get-UninstallEntry, Compare-AppVersion, Enable-GlobalMsiLogging, Move-DesktopShortcut

