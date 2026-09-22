# ⚡ AGY RIG

<p align="center">
  <img src="agy-rig.png" width="96" height="96" alt="AGY RIG Icon" />
</p>

<p align="center">
  <strong>Super-Compact Dock & Account Manager for Google Antigravity (AGY)</strong><br />
  Hot-swap Google accounts, monitor live quota telemetry, and launch isolated parallel instances with one click.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Windows-0078D6?logo=windows&logoColor=white" alt="Platform" />
  <img src="https://img.shields.io/badge/Language-PowerShell%20%2F%20WPF-5391FE?logo=powershell&logoColor=white" alt="Language" />
  <img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License" />
</p>

---

## ✨ Features

- 🎯 **Super-Compact Dock (380×260px)**: A sleek retro-modern desktop instrument with zero fluff. Every single element is functional data or an actionable control.
- 🔄 **One-Click Hot-Swap (Dropdown)**: Switch active Google OAuth credentials in Windows Credential Manager instantly with persistent custom dropdown.
- ⚡ **Simultaneous Parallel Profiles**: Run isolated Antigravity instances concurrently with separate user data directories (`--user-data-dir`).
- 📊 **Real-Time Quota Telemetry**: Live progress bars for **Gemini 5-Hour**, **Gemini Weekly**, **Claude 5-Hour**, and **Claude Weekly** limits with exact countdown timers.
- 💎 **Credit Tracking**: Live AI Studio / AGY credit balance with quick top-up link.
- 📌 **Always-on-Top Hardware Saklar**: Hardware-style toggle switch slider to pin the dock above your IDE.
- 📦 **One-Click Installer (`INSTALL.bat`)**: Automatically checks and installs **Python**, **Node.js**, and native **AGY CLI** if missing, configures shortcuts, and registers PowerShell aliases.

---

## 🚀 Quick Start / Installation

### Method 1: Double-Click Installer (Recommended)
1. Clone or download this repository:
   ```bash
   git clone https://github.com/alchemist4real/agy-rig.git
   cd agy-rig
   ```
2. Double-click **`INSTALL.bat`**.
   - It will verify and auto-install Python, Node.js, and AGY CLI if missing.
   - It will place **`AGY RIG`** in your Start Menu and create a Desktop shortcut with the custom gold-triangle icon.
   - It will register PowerShell profile aliases (`agy-rig`, `agy-gui`, `agy-switch`).

### Method 2: Manual / Terminal
Run the PowerShell setup script:
```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

---

## 🖥️ Usage

### 1. GUI Dock
- Double-click the **AGY RIG** icon on your Desktop or Start Menu.
- Or type in PowerShell:
  ```powershell
  agy-rig
  ```

| Control | Action |
|---|---|
| **Account Dropdown** | Click to open list of saved accounts. Select any account to view email and status. |
| **SWITCH** | Switches the primary Antigravity Google OAuth session to the selected account. |
| **PARALEL** | Launches an independent, parallel Antigravity window using that account's profile. |
| **+ LOGIN** | Opens a browser window to securely log into a new Google account via OAuth PKCE loopback. |
| **+ SIMPAN** | Saves the currently active Antigravity session into a named slot. |
| **↻ SYNC** | Refreshes quota bars, credit balance, and account status in real time. |
| **[ PIN ● ]** | Hardware toggle switch to pin the widget always-on-top above all windows. |

### 2. CLI Companion (`agy-switch`)
Manage accounts directly from your terminal:
```bash
agy-switch quota        # View live 5h and weekly quota telemetry
agy-switch list         # List all saved accounts
agy-switch save <name>  # Save currently active Google session as <name>
agy-switch use <name>   # Switch primary credentials to <name>
agy-switch launch <name># Launch isolated parallel instance for <name>
agy-switch profiles     # View all active parallel profile directories
```

---

## 🔒 Security & Credential Storage

AGY RIG uses enterprise-grade security for credential handling:
- **Windows DPAPI (Data Protection API)**: All refresh tokens are encrypted using machine and user-specific keys (`CryptProtectData`).
- **Windows Credential Manager**: Directly integrates with Windows `advapi32.dll` (`CredRead`, `CredWrite`, `CredDelete`) for the active `antigravity_google_oauth_credential` target.
- **Loopback OAuth PKCE**: Never requires entering Google passwords into third-party tools; authentication happens directly in your official Google browser session via `http://localhost:port`.

---

## 📁 Architecture

```
agy-rig/
├── AgyRig-GUI.ps1     # Main WPF Dock GUI (Clean XAML, HD ClearType, no default chrome)
├── agy-rig.ps1        # Full-featured CLI companion
├── AgySwitch-GUI.ps1  # Backwards-compatibility forwarder
├── agy-switch.ps1     # Backwards-compatibility forwarder
├── setup.ps1          # All-in-one installer and dependency auto-installer
├── INSTALL.bat        # Double-clickable Windows batch installer
├── RUN.bat            # Double-clickable quick launcher
├── agy-rig.ico        # Custom gold-triangle dark application icon
├── agy-rig.png        # High-res icon asset
├── LICENSE            # MIT License
└── README.md          # Documentation
```

---

## 📄 License

MIT License © 2026 Alchemist / AGY RIG Contributors
