# agy-switch.ps1 - AGY RIG Forwarder (Backwards Compatibility)
param(
    [Parameter(Position=0)]
    [string]$Command = "help",

    [Parameter(Position=1)]
    [string]$TargetName = "",

    [Parameter(Position=2)]
    [string]$ExtraParam = ""
)

$targetScript = Join-Path $PSScriptRoot "agy-rig.ps1"
if (Test-Path $targetScript) {
    & $targetScript -Command $Command -TargetName $TargetName -ExtraParam $ExtraParam
} else {
    Write-Host "[ERROR] agy-rig.ps1 tidak ditemukan di $PSScriptRoot" -ForegroundColor Red
}
