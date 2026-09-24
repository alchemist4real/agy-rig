<#
.SYNOPSIS
    AGY RIG — Windows One-Line Installer
.DESCRIPTION
    Downloads and installs AGY RIG (Antigravity Account Switcher + Live Quota Dock),
    configures desktop shortcuts, Start menu entry, and PowerShell profile aliases.
.EXAMPLE
    irm https://raw.githubusercontent.com/alchemist4real/agy-rig/main/install.ps1 | iex
#>

$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor DarkYellow
Write-Host "     ___   _______  __   ___  ________ " -ForegroundColor Yellow
Write-Host "    / _ | / ___/\ \/ /  / _ \/  _/ ___/ " -ForegroundColor Yellow
Write-Host "   / __ |/ (_ /  \  /  / , _// // (_ /  " -ForegroundColor Yellow
Write-Host "  /_/ |_|\___/   /_/  /_/|_|/___/\___/   " -ForegroundColor Yellow
Write-Host "  ================================================================" -ForegroundColor DarkYellow
Write-Host "   AGY RIG — Windows One-Line Installer" -ForegroundColor White
Write-Host "  ================================================================" -ForegroundColor DarkYellow
Write-Host ""

$installDir = Join-Path $env:LOCALAPPDATA "AgyRig"
$tempZip = Join-Path $env:TEMP ("agyrig-install-" + [Guid]::NewGuid().ToString().Substring(0,8) + ".zip")
$tempExtract = Join-Path $env:TEMP ("agyrig-extract-" + [Guid]::NewGuid().ToString().Substring(0,8))
$zipUrl = "https://github.com/alchemist4real/agy-rig/archive/refs/heads/main.zip"

try {
    # 1. Download with retry & 30s timeout
    $maxRetries = 3
    $downloaded = $false
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Write-Host "  [1/4] Downloading latest AGY RIG package (attempt $attempt/$maxRetries)..." -ForegroundColor Cyan
            Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing -TimeoutSec 30
            $downloaded = $true
            break
        } catch {
            Write-Host "        [WARN] Attempt $attempt failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($attempt -lt $maxRetries) { Start-Sleep -Seconds 2 }
        }
    }

    if (-not $downloaded) {
        Write-Host "  [ERROR] Failed to download package from GitHub after $maxRetries attempts." -ForegroundColor Red
        exit 1
    }

    # 2. Extract files
    Write-Host "  [2/4] Extracting files..." -ForegroundColor Cyan
    Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

    $extractedRoot = Join-Path $tempExtract "agy-rig-main"
    if (-not (Test-Path $extractedRoot)) {
        $firstDir = Get-ChildItem -Path $tempExtract -Directory | Select-Object -First 1
        if ($firstDir) { $extractedRoot = $firstDir.FullName }
    }

    # 3. Install
    Write-Host "  [3/4] Installing application into $installDir..." -ForegroundColor Cyan
    if (-not (Test-Path $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }

    Get-ChildItem -Path $extractedRoot -Exclude ".git", ".github" | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $installDir -Recurse -Force
    }

    # 4. Configure shortcuts & aliases
    Write-Host "  [4/4] Configuring shortcuts, profile aliases & dependencies..." -ForegroundColor Cyan
    $setupScript = Join-Path $installDir "setup.ps1"
    if (Test-Path $setupScript) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $setupScript
    } else {
        Write-Host "  [OK] Installed successfully to $installDir." -ForegroundColor Green
    }
} finally {
    # Ensure temporary files are completely cleaned up
    if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
    if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
}
