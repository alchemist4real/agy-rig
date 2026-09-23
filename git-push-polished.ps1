Set-Location "C:\Users\ACER\.gemini\antigravity\scratch\agy-switch"

$temp = @(
    'render-polished.ps1',
    'dock_render_polished.png',
    'test-syntax-gui.ps1',
    'test-headless-gui.ps1',
    'test-efficiency.ps1',
    'test-async-runspace.ps1'
)
foreach ($t in $temp) {
    if (Test-Path $t) { Remove-Item $t -Force -ErrorAction SilentlyContinue }
}

# Git status and push
& git add -A
& git status -s
$changes = & git status --porcelain
if ($changes) {
    & git commit -m "fix & perf: bug fixes, exact symmetry layout, inline account deletion, and non-blocking async telemetry"
    & git push origin main
    Write-Host "Pushed updates to GitHub!"
} else {
    Write-Host "No git changes to commit."
}
