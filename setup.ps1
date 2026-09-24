<#
.SYNOPSIS
    AGY RIG All-in-One Installer & Dependency Manager
.DESCRIPTION
    Installs AGY RIG (Antigravity Account Switcher + Live Quota Dock),
    checks and auto-installs Python, Node.js, and agy CLI if missing,
    creates Desktop and Start Menu shortcuts, and configures PowerShell aliases.
#>

[CmdletBinding()]
param(
    [switch]$SkipDependencies,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Continue"

# Output helpers
function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor DarkYellow
    Write-Host "     ___   _______  __   ___  ________ " -ForegroundColor Yellow
    Write-Host "    / _ | / ___/\ \/ /  / _ \/  _/ ___/ " -ForegroundColor Yellow
    Write-Host "   / __ |/ (_ /  \  /  / , _// // (_ /  " -ForegroundColor Yellow
    Write-Host "  /_/ |_|\___/   /_/  /_/|_|/___/\___/   " -ForegroundColor Yellow
    Write-Host "  ================================================================" -ForegroundColor DarkYellow
    Write-Host "   One-Click Installer: AGY RIG + Dependency Manager" -ForegroundColor White
    Write-Host "  ================================================================" -ForegroundColor DarkYellow
    Write-Host ""
}

function Write-Step([string]$step, [string]$title) {
    Write-Host "  [$step] $title..." -ForegroundColor Cyan
}

function Write-Success([string]$msg) {
    Write-Host "      [OK] $msg" -ForegroundColor Green
}

function Write-Info([string]$msg) {
    Write-Host "      [--] $msg" -ForegroundColor DarkGray
}

function Write-Warn([string]$msg) {
    Write-Host "      [!] $msg" -ForegroundColor Yellow
}

function Write-Fail([string]$msg) {
    Write-Host "      [FAIL] $msg" -ForegroundColor Red
}

Write-Header

$srcDir = $PSScriptRoot
if (-not $srcDir) { $srcDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

$installDir = Join-Path $env:LOCALAPPDATA "AgyRig"
$legacyDir = Join-Path $env:USERPROFILE ".gemini\antigravity\scratch\agy-switch"

# ============================================================================
# STEP 1: EXECUTION POLICY
# ============================================================================
Write-Step "1/6" "Checking PowerShell Execution Policy"
try {
    $curEp = Get-ExecutionPolicy -Scope CurrentUser
    if ($curEp -eq 'Undefined' -or $curEp -eq 'Restricted') {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
        Write-Success "ExecutionPolicy CurrentUser set to RemoteSigned"
    } else {
        Write-Success "Current ExecutionPolicy: $curEp"
    }
} catch {
    Write-Warn "Failed to set ExecutionPolicy: $($_.Exception.Message)"
}

# ============================================================================
# STEP 2: DEPENDENCIES (PYTHON, NODE.JS, AGY CLI)
# ============================================================================
if (-not $SkipDependencies) {
    Write-Step "2/6" "Checking & Installing System Dependencies"

    # -- 2a. Winget availability --
    $hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    if ($hasWinget) {
        Write-Info "Windows Package Manager (winget) is available."
    } else {
        Write-Info "winget not found, direct installer download will be used if needed."
    }

    # -- 2b. Python --
    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pyCmd) { $pyCmd = Get-Command py -ErrorAction SilentlyContinue }

    if ($pyCmd) {
        $pyVer = & $pyCmd.Source --version 2>&1
        Write-Success "Python detected: $pyVer"
    } else {
        Write-Warn "Python not found. Downloading & installing Python automatically..."
        $installedPy = $false

        if ($hasWinget) {
            try {
                Write-Info "Installing Python via winget (silent)..."
                $proc = Start-Process -FilePath "winget" -ArgumentList "install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements --silent" -Wait -PassThru -NoNewWindow
                if ($proc.ExitCode -eq 0) { $installedPy = $true }
            } catch {}
        }

        if (-not $installedPy) {
            # Fallback: direct download official installer
            $pyUrl = "https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe"
            $pyInstaller = Join-Path $env:TEMP "python-installer.exe"
            Write-Info "Downloading Python 3.12 from python.org..."
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
                Invoke-WebRequest -Uri $pyUrl -OutFile $pyInstaller -UseBasicParsing
                Write-Info "Installing Python (silent)..."
                $proc = Start-Process -FilePath $pyInstaller -ArgumentList "/passive InstallAllUsers=0 PrependPath=1 Include_pip=1" -Wait -PassThru
                if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) { $installedPy = $true }
                Remove-Item $pyInstaller -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Fail "Failed to download Python: $($_.Exception.Message)"
            }
        }

        if ($installedPy) {
            Write-Success "Python installed successfully."
            # Refresh local PATH for current session
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","User") + ";" + [System.Environment]::GetEnvironmentVariable("Path","Machine")
        } else {
            Write-Warn "Python automatic install could not complete. You can install from https://python.org later."
        }
    }

    # -- 2c. Node.js --
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) {
        $nodeVer = & $nodeCmd.Source --version 2>&1
        Write-Success "Node.js detected: $nodeVer"
    } else {
        Write-Warn "Node.js not found. Downloading & installing Node.js LTS automatically..."
        $installedNode = $false

        if ($hasWinget) {
            try {
                Write-Info "Installing Node.js LTS via winget (silent)..."
                $proc = Start-Process -FilePath "winget" -ArgumentList "install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements --silent" -Wait -PassThru -NoNewWindow
                if ($proc.ExitCode -eq 0) { $installedNode = $true }
            } catch {}
        }

        if (-not $installedNode) {
            # Fallback: direct download official MSI
            $nodeUrl = "https://nodejs.org/dist/v20.18.0/node-v20.18.0-x64.msi"
            $nodeMsi = Join-Path $env:TEMP "nodejs-installer.msi"
            Write-Info "Downloading Node.js LTS from nodejs.org..."
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
                Invoke-WebRequest -Uri $nodeUrl -OutFile $nodeMsi -UseBasicParsing
                Write-Info "Installing Node.js (silent)..."
                $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$nodeMsi`" /qn" -Wait -PassThru
                if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) { $installedNode = $true }
                Remove-Item $nodeMsi -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Fail "Failed to download Node.js: $($_.Exception.Message)"
            }
        }

        if ($installedNode) {
            Write-Success "Node.js LTS installed successfully."
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","User") + ";" + [System.Environment]::GetEnvironmentVariable("Path","Machine")
        } else {
            Write-Warn "Node.js automatic install could not complete. You can install from https://nodejs.org later."
        }
    }

    # -- 2d. Antigravity Native CLI (agy) --
    $agyCmd = Get-Command agy -ErrorAction SilentlyContinue
    if (-not $agyCmd) {
        $agyBin = "$env:USERPROFILE\.gemini\antigravity\bin\agy.exe"
        if (Test-Path $agyBin) {
            Write-Info "Registering Antigravity native CLI (agy install)..."
            try {
                & "$agyBin" install | Out-Null
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","User") + ";" + [System.Environment]::GetEnvironmentVariable("Path","Machine")
            } catch {}
        }
    }
    $ver = & agy --version 2>$null
    if ($ver) {
        Write-Success "Antigravity CLI (agy) detected: v$ver"
    } else {
        Write-Info "Antigravity CLI will be active after opening a new terminal."
    }
} else {
    Write-Info "Dependency checks skipped (--SkipDependencies)."
}

# ============================================================================
# STEP 3: INSTALL APPLICATION FILES
# ============================================================================
Write-Step "3/6" "Setting up Application Files in $installDir"

if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

$coreFiles = @(
    "AgyRig-GUI.ps1",
    "agy-rig.ps1",
    "AgySwitch-GUI.ps1",
    "agy-switch.ps1",
    "agy-rig.ico",
    "agy-rig.png"
)

foreach ($f in $coreFiles) {
    $srcPath = Join-Path $srcDir $f
    if (-not (Test-Path $srcPath)) {
        $srcPath = Join-Path $legacyDir $f
    }
    if (Test-Path $srcPath) {
        Copy-Item -Path $srcPath -Destination (Join-Path $installDir $f) -Force
        Write-Info "Copied: $f"
    } else {
        Write-Warn "File not found: $f"
    }
}

# Ensure data directories exist in both installDir and legacyDir
$dataDirs = @(
    (Join-Path $installDir "accounts"),
    (Join-Path $installDir "credits"),
    (Join-Path $legacyDir "accounts"),
    (Join-Path $legacyDir "credits"),
    (Join-Path $env:USERPROFILE ".gemini\antigravity\profiles")
)
foreach ($d in $dataDirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

# Migrate existing accounts, credits, and active state to installDir
foreach ($sub in @("accounts", "credits")) {
    $srcSub = Join-Path $srcDir $sub
    $dstSub = Join-Path $installDir $sub
    if (Test-Path $srcSub) {
        Get-ChildItem -Path $srcSub -File -EA SilentlyContinue | ForEach-Object {
            $destFile = Join-Path $dstSub $_.Name
            if (-not (Test-Path $destFile)) {
                Copy-Item -Path $_.FullName -Destination $destFile -Force
                Write-Info "Migrated data: $sub\$($_.Name)"
            }
        }
    }
}
$srcActive = Join-Path $srcDir "active_account.txt"
$dstActive = Join-Path $installDir "active_account.txt"
if ((Test-Path $srcActive) -and -not (Test-Path $dstActive)) {
    Copy-Item -Path $srcActive -Destination $dstActive -Force
}

Write-Success "Directory structure and application files installed."

# ============================================================================
# STEP 4: CREATE SHORTCUTS (DESKTOP & START MENU)
# ============================================================================
Write-Step "4/6" "Creating Desktop & Start Menu Shortcuts"

$guiTarget = Join-Path $installDir "AgyRig-GUI.ps1"
if (-not (Test-Path $guiTarget)) { $guiTarget = Join-Path $installDir "AgySwitch-GUI.ps1" }
$iconTarget = Join-Path $installDir "agy-rig.ico"
$desktopDir = [Environment]::GetFolderPath("Desktop")
$startMenuDir = Join-Path ([Environment]::GetFolderPath("ApplicationData")) "Microsoft\Windows\Start Menu\Programs"

try {
    $shell = New-Object -ComObject WScript.Shell

    # 1. Desktop Shortcut
    $desktopShortcutPath = Join-Path $desktopDir "AGY RIG.lnk"
    $sc = $shell.CreateShortcut($desktopShortcutPath)
    $sc.TargetPath = "powershell.exe"
    $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$guiTarget`""
    $sc.WorkingDirectory = $installDir
    $sc.Description = "AGY RIG - Antigravity Account Switcher & Live Quota Dock"
    $sc.WindowStyle = 7
    if (Test-Path $iconTarget) {
        $sc.IconLocation = "$iconTarget, 0"
    }
    $sc.Save()
    Write-Success "Desktop Shortcut: AGY RIG.lnk"

    # Also update legacy shortcut name if present
    $legacyLnk = Join-Path $desktopDir "Antigravity Switcher.lnk"
    if (Test-Path $legacyLnk) {
        try {
            $lsc = $shell.CreateShortcut($legacyLnk)
            $lsc.TargetPath = "powershell.exe"
            $lsc.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$guiTarget`""
            $lsc.WorkingDirectory = $installDir
            if (Test-Path $iconTarget) { $lsc.IconLocation = "$iconTarget, 0" }
            $lsc.Save()
            Write-Info "Legacy shortcut 'Antigravity Switcher.lnk' updated to AGY RIG."
        } catch {}
    }

    # 2. Start Menu Shortcut
    $startShortcutPath = Join-Path $startMenuDir "AGY RIG.lnk"
    $scStart = $shell.CreateShortcut($startShortcutPath)
    $scStart.TargetPath = "powershell.exe"
    $scStart.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$guiTarget`""
    $scStart.WorkingDirectory = $installDir
    $scStart.Description = "AGY RIG - Antigravity Account Switcher & Live Quota Dock"
    $scStart.WindowStyle = 7
    if (Test-Path $iconTarget) {
        $scStart.IconLocation = "$iconTarget, 0"
    }
    $scStart.Save()
    Write-Success "Start Menu Shortcut: AGY RIG.lnk"

    # Flush Windows shell icon cache
    Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;
    public class ShellIconNotifier {
        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);
    }
"@ -EA SilentlyContinue
    try {
        [ShellIconNotifier]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Process "ie4uinit.exe" -ArgumentList "-show" -NoNewWindow -EA SilentlyContinue
    } catch {}
} catch {
    Write-Warn "Failed to create shortcuts: $($_.Exception.Message)"
}

# ============================================================================
# STEP 5: POWERSHELL PROFILE ALIASES & CLI INTEGRATION
# ============================================================================
Write-Step "5/6" "Registering PowerShell Profile Aliases"

$cliTarget = Join-Path $installDir "agy-switch.ps1"
$rigCliTarget = Join-Path $installDir "agy-rig.ps1"
$profilePath = $PROFILE.CurrentUserCurrentHost
$aliasContent = @"

# --- AGY RIG INTEGRATION ---
function agy-switch { & '$cliTarget' `@args }
function agy-rig {
    if (`$args.Count -eq 0) {
        Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File','$guiTarget'
    } else {
        & '$rigCliTarget' `@args
    }
}
function agy-gui { Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File','$guiTarget' }
# --- END AGY RIG ---
"@

try {
    $profDir = Split-Path -Parent $profilePath
    if (-not (Test-Path $profDir)) { New-Item -ItemType Directory -Path $profDir -Force | Out-Null }
    if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Path $profilePath -Force | Out-Null }

    $existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if ($existing -notmatch "AGY RIG INTEGRATION") {
        Add-Content -Path $profilePath -Value $aliasContent -Encoding UTF8
        Write-Success "Aliases 'agy-rig', 'agy-gui', and 'agy-switch' added to PowerShell Profile."
    } else {
        # Update existing block
        $updated = $existing -replace '(?s)# --- AGY RIG INTEGRATION ---.*?# --- END AGY RIG ---', $aliasContent.Trim()
        Set-Content -Path $profilePath -Value $updated -Encoding UTF8
        Write-Success "PowerShell Profile aliases updated."
    }
} catch {
    Write-Warn "Failed to register profile aliases: $($_.Exception.Message)"
}

# ============================================================================
# STEP 6: COMPLETE & LAUNCH
# ============================================================================
Write-Step "6/6" "Installation Complete"

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host "     AGY RIG INSTALLED AND READY TO USE" -ForegroundColor Green
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  How to Launch AGY RIG:" -ForegroundColor White
Write-Host "    1. Double-click the 'AGY RIG' icon on Desktop" -ForegroundColor Yellow
Write-Host "    2. Search 'AGY RIG' in Windows Start Menu" -ForegroundColor Yellow
Write-Host "    3. Type 'agy-rig' or 'agy-switch' in any PowerShell terminal" -ForegroundColor Yellow
Write-Host ""

if (-not $NoLaunch) {
    Write-Host "  >> Launching AGY RIG now..." -ForegroundColor Cyan
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$guiTarget`""
}

Write-Host ""
