$dir = $PSScriptRoot
if (-not $dir) { $dir = Split-Path -Parent $MyInvocation.MyCommand.Path }
Set-Location $dir

# Configure local git user if not set
$gitName = & git config user.name 2>$null
if (-not $gitName) {
    & git config user.name "alchemist4real"
    & git config user.email "alchemist4real@users.noreply.github.com"
    Write-Host "Configured local Git user: alchemist4real"
}

# Remove publish.ps1 from git staging before committing
if (Test-Path "publish.ps1") {
    # add to .gitignore or remove from staging
    & git reset HEAD "publish.ps1" 2>$null
}

# Add all files to staging
& git add -A
& git status -s

# Commit
& git commit -m "feat: initial release of AGY RIG v1.0.0"

# Check if remote exists, otherwise create via gh CLI
$remote = & git remote get-url origin 2>$null
if (-not $remote) {
    Write-Host "`nCreating GitHub repository 'agy-rig' via gh CLI..."
    & gh repo create "agy-rig" --public --source=. --remote=origin --description "Super-compact dock for Google Antigravity (AGY) - Multi-account switcher, real-time quota telemetry, and parallel isolated profiles." --push
} else {
    Write-Host "`nPushing to remote origin..."
    & git push -u origin main
}

Write-Host "`nRepository successfully created and pushed!"
& gh repo view --web=false
