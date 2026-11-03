#Requires -Version 5.1
# AST validation of every .ps1/.psm1 in the repo. Exit 0 = pass, 1 = fail.
$root = Split-Path $PSScriptRoot -Parent
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })
$failed = 0
foreach ($f in $files) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    if ($errors) {
        $failed++
        Write-Host "[FAIL] $($f.FullName)"
        $errors | ForEach-Object { Write-Host "       line $($_.Extent.StartLineNumber): $($_.Message)" }
    } else {
        Write-Host "[PASS] $($f.FullName.Substring($root.Length + 1))"
    }
}
Write-Host ("Syntax: {0} file(s), {1} failure(s)" -f $files.Count, $failed)
if ($failed) { throw "Syntax errors in $failed file(s)." }
