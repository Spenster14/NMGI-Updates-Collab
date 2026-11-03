#Requires -Version 5.1
# Dual console + file logger.

$script:LogPath = $null

function Initialize-Log {
    <#
    .SYNOPSIS
        Creates the timestamped log file. Falls back to FallbackDirectory if Directory is unusable.
    .OUTPUTS
        [string] full path of the log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$FallbackDirectory,
        [string]$Prefix = 'Update'
    )
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $candidates = @($Directory)
    if ($FallbackDirectory) { $candidates += $FallbackDirectory }
    foreach ($dir in $candidates) {
        try {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            $path = Join-Path $dir ("{0}-{1}.log" -f $Prefix, $stamp)
            Set-Content -LiteralPath $path -Value ("# Log started {0} on {1} as {2}" -f (Get-Date -Format o), $env:COMPUTERNAME, [Environment]::UserName) -Encoding UTF8 -ErrorAction Stop
            $script:LogPath = $path
            return $path
        } catch {
            Write-Host ("[WARN] Cannot use log directory '{0}': {1}" -f $dir, $_.Exception.Message)
        }
    }
    $script:LogPath = $null
    return $null
}

function Get-LogPath { [CmdletBinding()] param() return $script:LogPath }

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogPath) {
        try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
}

function Remove-OldLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory, [int]$RetentionDays = 30)
    if (-not (Test-Path -LiteralPath $Directory)) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $Directory -Filter 'Update-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Initialize-Log, Get-LogPath, Write-Log, Remove-OldLog

