# AgySwitch-GUI.ps1 (Compatibility Forwarder for AGY RIG)
$target = Join-Path $PSScriptRoot "AgyRig-GUI.ps1"
if (Test-Path $target) {
    & $target @args
} else {
    Write-Error "AgyRig-GUI.ps1 not found in $PSScriptRoot"
}
