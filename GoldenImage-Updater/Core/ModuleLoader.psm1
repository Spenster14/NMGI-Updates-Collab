#Requires -Version 5.1
# Dynamic module discovery, contract validation and dependency ordering.

$script:RequiredFunctions = 'Test-AppInstalled', 'Get-AppVersion', 'Invoke-AppUpdate', 'Test-UpdateSuccess'

function Get-AppModuleFile {
    <# Finds every *.psm1 under Modules\, skipping folders/files that start with '_' (templates). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModulesRoot)
    Get-ChildItem -LiteralPath $ModulesRoot -Filter *.psm1 -Recurse -File |
        Where-Object { $_.FullName.Substring($ModulesRoot.Length) -notmatch '(^|[\\/])_' } |
        Sort-Object FullName
}

function Test-ModuleContract {
    <# Returns the list of missing required functions (empty array when compliant). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.PSModuleInfo]$Module)
    @($script:RequiredFunctions | Where-Object { -not $Module.ExportedCommands.ContainsKey($_) })
}

function Import-AppModule {
    <#
    .SYNOPSIS
        Imports one module file and returns a descriptor:
        Name, Category, Path, Module, DependsOn, Priority, Error.
        Optional function Get-AppMetadata may return @{ Name; DependsOn; Priority }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.IO.FileInfo]$File, [string]$ModulesRoot)
    $desc = [pscustomobject]@{
        Name = $File.BaseName; Category = $File.Directory.Name; Path = $File.FullName
        Module = $null; DependsOn = @(); Priority = 100; Error = $null
    }
    try {
        $mod = Import-Module -Name $File.FullName -Force -PassThru -DisableNameChecking -ErrorAction Stop
        $desc.Module = $mod
        $missing = Test-ModuleContract -Module $mod
        if ($missing.Count -gt 0) { throw "Contract violation, missing: $($missing -join ', ')" }
        if ($mod.ExportedCommands.ContainsKey('Get-AppMetadata')) {
            $meta = & $mod.ExportedCommands['Get-AppMetadata']
            if ($meta.Name) { $desc.Name = [string]$meta.Name }
            if ($meta.DependsOn) { $desc.DependsOn = @($meta.DependsOn) }
            if ($null -ne $meta.Priority) { $desc.Priority = [int]$meta.Priority }
        }
    } catch {
        $desc.Error = $_.Exception.Message
    }
    return $desc
}

function Get-AppModuleOrder {
    <#
    .SYNOPSIS
        Orders descriptors by DependsOn (topological), then Priority, then Name. Cycles/unknown deps are
        reported through Error on the offending descriptor and the module is appended last.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Descriptors)
    $pending = New-Object System.Collections.ArrayList
    $pending.AddRange(@($Descriptors | Sort-Object Priority, Name))
    $ordered = New-Object System.Collections.ArrayList
    $done = @{}
    $allNames = @($Descriptors | ForEach-Object { $_.Name })
    while ($pending.Count -gt 0) {
        $next = $pending | Where-Object {
            $ready = $true
            foreach ($d in $_.DependsOn) { if ($allNames -contains $d -and -not $done.ContainsKey($d)) { $ready = $false } }
            $ready
        } | Select-Object -First 1
        if (-not $next) {
            foreach ($p in $pending) { if (-not $p.Error) { $p.Error = 'Circular dependency detected.' }; [void]$ordered.Add($p) }
            break
        }
        [void]$ordered.Add($next); $done[$next.Name] = $true; $pending.Remove($next)
    }
    return @($ordered)
}

Export-ModuleMember -Function Get-AppModuleFile, Test-ModuleContract, Import-AppModule, Get-AppModuleOrder

