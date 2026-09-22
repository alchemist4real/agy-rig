# agy-switch.ps1 - Antigravity Account Switcher + Native Quota Tracker CLI
# Commands: save, use, list, delete, current, quota (or credits), help

param(
    [Parameter(Position=0)]
    [string]$Command = "help",

    [Parameter(Position=1)]
    [string]$TargetName = "",

    [Parameter(Position=2)]
    [string]$ExtraParam = ""
)

# ============================================================================
# .NET Interop & Setup
# ============================================================================

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class AgySwitchCredManager {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredWrite(ref CREDENTIAL credential, int flags);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern void CredFree(IntPtr credential);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public static string ReadCredential(string target) {
        IntPtr credPtr;
        if (!CredRead(target, 1, 0, out credPtr)) {
            return null;
        }
        CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(credPtr, typeof(CREDENTIAL));
        string blob = "";
        if (cred.CredentialBlobSize > 0 && cred.CredentialBlob != IntPtr.Zero) {
            byte[] bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, cred.CredentialBlobSize);
            blob = Encoding.UTF8.GetString(bytes);
        }
        CredFree(credPtr);
        return blob;
    }

    public static string ReadCredentialUser(string target) {
        IntPtr credPtr;
        if (!CredRead(target, 1, 0, out credPtr)) {
            return null;
        }
        CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(credPtr, typeof(CREDENTIAL));
        string user = cred.UserName;
        CredFree(credPtr);
        return user;
    }

    public static bool WriteCredential(string target, string userName, string blob) {
        byte[] blobBytes = Encoding.UTF8.GetBytes(blob);
        CREDENTIAL cred = new CREDENTIAL();
        cred.Flags = 0;
        cred.Type = 1;
        cred.TargetName = target;
        cred.Comment = "Antigravity credentials";
        cred.UserName = userName;
        cred.CredentialBlobSize = blobBytes.Length;
        cred.CredentialBlob = Marshal.AllocHGlobal(blobBytes.Length);
        Marshal.Copy(blobBytes, 0, cred.CredentialBlob, blobBytes.Length);
        cred.Persist = 2;
        cred.AttributeCount = 0;
        cred.Attributes = IntPtr.Zero;
        cred.TargetAlias = null;

        bool result = CredWrite(ref cred, 0);
        Marshal.FreeHGlobal(cred.CredentialBlob);
        return result;
    }
}
"@ -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Security

$CRED_TARGET  = "gemini:antigravity"
$BASE_DIR     = Join-Path $env:USERPROFILE ".gemini\antigravity\scratch\agy-switch"
$ACCOUNTS_DIR = Join-Path $BASE_DIR "accounts"
$CREDITS_DIR  = Join-Path $BASE_DIR "credits"
$ACTIVE_FILE  = Join-Path $BASE_DIR "active_account.txt"

foreach ($dir in @($ACCOUNTS_DIR, $CREDITS_DIR)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ============================================================================
# Crypto & Helper Functions
# ============================================================================

function Protect-String([string]$plaintext) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($plaintext)
    $encrypted = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Convert]::ToBase64String($encrypted)
}

function Unprotect-String([string]$encryptedBase64) {
    $bytes = [Convert]::FromBase64String($encryptedBase64)
    $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [System.Text.Encoding]::UTF8.GetString($decrypted)
}

function Extract-EmailFromToken([string]$jsonBlob) {
    if (-not $jsonBlob) { return $null }
    try {
        $obj = $jsonBlob | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($obj.email) { return $obj.email }

        # Check top-level id_token (Antigravity standard format)
        $idTok = if ($obj.id_token) { $obj.id_token } elseif ($obj.token -and $obj.token.id_token) { $obj.token.id_token } else { $null }

        if ($idTok) {
            $parts = $idTok -split '\.'
            if ($parts.Count -ge 2) {
                $payload = $parts[1]
                $mod = $payload.Length % 4
                if ($mod -gt 0) { $payload += '=' * (4 - $mod) }
                $payload = $payload.Replace('-', '+').Replace('_', '/')
                $claims = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($claims.email) { return $claims.email }
            }
        }

        # Fallback: Google tokeninfo endpoint using access_token
        $accTok = if ($obj.token -and $obj.token.access_token) { $obj.token.access_token } elseif ($obj.access_token) { $obj.access_token } else { $null }
        if ($accTok) {
            try {
                $info = Invoke-RestMethod -Uri "https://oauth2.googleapis.com/tokeninfo?access_token=$accTok" -TimeoutSec 3 -ErrorAction SilentlyContinue
                if ($info -and $info.email) { return $info.email }
            } catch {}
        }
    } catch {}
    return $null
}

function Repair-AccountEmail([string]$accountFilePath) {
    try {
        $data = Get-Content $accountFilePath -Raw | ConvertFrom-Json
        if (-not $data.email -or $data.email -like "*(tidak terdeteksi)*") {
            $blob = Unprotect-String $data.credential
            $realEmail = Extract-EmailFromToken $blob
            if ($realEmail) {
                $data.email = $realEmail
                $data | ConvertTo-Json -Depth 5 | Set-Content -Path $accountFilePath -Encoding UTF8
                return $realEmail
            }
        }
        return $data.email
    } catch {
        return $null
    }
}

function Format-Countdown([string]$isoStr) {
    if (-not $isoStr) { return "--" }
    try {
        $target = [DateTimeOffset]::Parse($isoStr).LocalDateTime
        $diff = $target - (Get-Date)
        if ($diff.TotalSeconds -le 0) { return "Reset Now" }
        if ($diff.TotalDays -ge 1) {
            return "$([int]$diff.TotalDays)d $($diff.Hours)h"
        } elseif ($diff.TotalHours -ge 1) {
            return "$($diff.Hours)h $($diff.Minutes)m"
        } else {
            return "$($diff.Minutes)m"
        }
    } catch {
        return "--"
    }
}

function Format-ProgressBar([double]$val, [double]$max = 1.0, [int]$width = 20) {
    if ($max -le 0) { $max = 1.0 }
    $pct = [math]::Min([math]::Max($val / $max, 0.0), 1.0)
    $filled = [math]::Floor($pct * $width)
    $empty = $width - $filled
    return ("=" * $filled) + ("-" * $empty)
}

function GetLiveAgyQuota {
    $q = @{
        success = $false
        gemini_5h = 0.0
        gemini_5h_reset = ""
        gemini_wk = 0.0
        gemini_wk_reset = ""
        claude_5h = 0.0
        claude_5h_reset = ""
        claude_wk = 0.0
        claude_wk_reset = ""
        credits = 0
        upgrade_uri = ""
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    try {
        $uRaw = & agy -p "/usage" --output-format json 2>$null
        if ($uRaw) {
            $uJson = $uRaw | ConvertFrom-Json -EA SilentlyContinue
            if ($uJson.command.data.groups) {
                foreach ($g in $uJson.command.data.groups) {
                    if ($g.name -match "Gemini") {
                        foreach ($b in $g.buckets) {
                            if ($b.window -eq "5h") {
                                $q.gemini_5h = [double]$b.remaining_fraction
                                $q.gemini_5h_reset = $b.reset_time
                            } elseif ($b.window -eq "weekly") {
                                $q.gemini_wk = [double]$b.remaining_fraction
                                $q.gemini_wk_reset = $b.reset_time
                            }
                        }
                    } elseif ($g.name -match "Claude") {
                        foreach ($b in $g.buckets) {
                            if ($b.window -eq "5h") {
                                $q.claude_5h = [double]$b.remaining_fraction
                                $q.claude_5h_reset = $b.reset_time
                            } elseif ($b.window -eq "weekly") {
                                $q.claude_wk = [double]$b.remaining_fraction
                                $q.claude_wk_reset = $b.reset_time
                            }
                        }
                    }
                }
                $q.success = $true
            }
        }

        $cRaw = & agy -p "/credits" --output-format json 2>$null
        if ($cRaw) {
            $cJson = $cRaw | ConvertFrom-Json -EA SilentlyContinue
            if ($cJson.command.data.remaining_credits -ne $null) {
                $q.credits = [int]$cJson.command.data.remaining_credits
                $q.upgrade_uri = $cJson.command.data.upgrade_uri
            }
        }
    } catch {}

    return $q
}

# ============================================================================
# Commands
# ============================================================================

function Show-Help {
    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  >> Antigravity Account Switcher + Native Quota HUD" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  == AKUN & SWITCHING ==" -ForegroundColor White
    Write-Host "    save <nama>          Simpan akun Google yang sedang aktif" -ForegroundColor Gray
    Write-Host "    login                Tambah / login akun Google baru (tanpa sign out manual)" -ForegroundColor Gray
    Write-Host "    use <nama>           Switch akun primary (akan konfirmasi sebelum restart)" -ForegroundColor Gray
    Write-Host "    list                 Tampilkan semua akun tersimpan + status quota" -ForegroundColor Gray
    Write-Host "    delete <nama>        Hapus akun tersimpan" -ForegroundColor Gray
    Write-Host "    current              Tampilkan akun aktif + status quota" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  == MULTI-PROFILE & PARALEL WORK ==" -ForegroundColor White
    Write-Host "    launch <nama>        Buka Antigravity profil baru/paralel (multi-window)" -ForegroundColor Gray
    Write-Host "    parallel <nama>      Alias untuk command 'launch'" -ForegroundColor Gray
    Write-Host "    profiles             Daftar direktori profil paralel yang tersimpan" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  == QUOTA / CREDITS (AUTO LIVE SYNC) ==" -ForegroundColor White
    Write-Host "    quota                Tampilkan live quota real-time dari agy CLI" -ForegroundColor Gray
    Write-Host "    credits              Alias untuk command 'quota'" -ForegroundColor Gray
    Write-Host "    gui                  Buka antarmuka visual (WPF HUD)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  == CONTOH ==" -ForegroundColor White
    Write-Host "    agy-switch save alchemist" -ForegroundColor Cyan
    Write-Host "    agy-switch launch muqorroben    # Buka jendela Antigravity kedua berdampingan" -ForegroundColor Cyan
    Write-Host "    agy-switch use alchemist        # Switch akun di jendela utama" -ForegroundColor Cyan
    Write-Host "    agy-switch quota" -ForegroundColor Cyan
    Write-Host "    agy-switch gui" -ForegroundColor Cyan
    Write-Host ""
}

function Save-Account {
    param([string]$Name)

    if (-not $Name) {
        Write-Host "  [ERROR] Harap tentukan nama akun. Contoh: agy-switch save aldi" -ForegroundColor Red
        return
    }

    $cleanName = $Name.ToLower().Trim()

    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  >> Menyimpan akun: $cleanName" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray

    $blob = [AgySwitchCredManager]::ReadCredential($CRED_TARGET)
    $user = [AgySwitchCredManager]::ReadCredentialUser($CRED_TARGET)

    if (-not $blob) {
        Write-Host "  [ERROR] Tidak ditemukan credential '$CRED_TARGET' di Credential Manager." -ForegroundColor Red
        Write-Host "          Pastikan kamu sudah login ke Antigravity terlebih dahulu." -ForegroundColor Yellow
        return
    }

    $email = Extract-EmailFromToken $blob
    $encryptedBlob = Protect-String $blob

    $accountData = @{
        name        = $cleanName
        user        = $user
        email       = if ($email) { $email } else { "(email tidak terdeteksi)" }
        credential  = $encryptedBlob
        saved_at    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    $accountFile = Join-Path $ACCOUNTS_DIR "$cleanName.dat"
    $accountData | ConvertTo-Json -Depth 5 | Set-Content -Path $accountFile -Encoding UTF8

    # MCP OAuth tokens backup
    $mcpFile = Join-Path $env:USERPROFILE ".gemini\antigravity\mcp_oauth_tokens.json"
    if (Test-Path $mcpFile) {
        $mcpContent = Get-Content $mcpFile -Raw
        $encryptedMcp = Protect-String $mcpContent
        $mcpBackup = Join-Path $ACCOUNTS_DIR "$($cleanName)_mcp.dat"
        Set-Content -Path $mcpBackup -Value $encryptedMcp -Encoding UTF8
    }

    Set-Content -Path $ACTIVE_FILE -Value $cleanName -Encoding UTF8

    Write-Host ""
    Write-Host "  [OK] Akun '$cleanName' berhasil disimpan!" -ForegroundColor Green
    Write-Host "     Email : $($accountData.email)" -ForegroundColor Gray
    Write-Host "     File  : $accountFile" -ForegroundColor DarkGray

    # Auto sync quota
    Write-Host "     Fetching live quota via agy CLI..." -ForegroundColor DarkGray
    $liveQ = GetLiveAgyQuota
    if ($liveQ.success) {
        $qp = Join-Path $CREDITS_DIR "$($cleanName)_quota.json"
        $liveQ | ConvertTo-Json -Depth 5 | Set-Content -Path $qp -Encoding UTF8
        $g5p = [int]([math]::Round($liveQ.gemini_5h * 100))
        $c5p = [int]([math]::Round($liveQ.claude_5h * 100))
        Write-Host "     Quota : Gemini 5h=$g5p% | Claude 5h=$c5p% | Credits=$($liveQ.credits)" -ForegroundColor Cyan
    }
    Write-Host ""
}

function Use-Account {
    param([string]$Name)

    if (-not $Name) {
        Write-Host "  [ERROR] Harap tentukan nama akun. Contoh: agy-switch use rina" -ForegroundColor Red
        return
    }

    $cleanName = $Name.ToLower().Trim()
    $accountFile = Join-Path $ACCOUNTS_DIR "$cleanName.dat"

    if (-not (Test-Path $accountFile)) {
        Write-Host "  [ERROR] Akun '$cleanName' tidak ditemukan." -ForegroundColor Red
        Write-Host "          Gunakan 'agy-switch list' untuk melihat akun tersimpan." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "  [PERINGATAN] Berpindah ke akun '$cleanName' akan me-restart Antigravity." -ForegroundColor Yellow
    Write-Host "               Pastikan semua subagent dan pekerjaan aktif sudah selesai!" -ForegroundColor Yellow
    $ans = Read-Host "  Apakah Anda yakin ingin me-restart Antigravity sekarang? (y/N)"
    if ($ans -notmatch "^[yY]([eE][sS])?$") {
        Write-Host "  [BATAL] Switch dibatalkan. Antigravity tetap berjalan aman." -ForegroundColor Green
        return
    }

    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  >> Switching ke akun: $cleanName" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray

    $accountData = Get-Content $accountFile -Raw | ConvertFrom-Json
    $plainBlob = $null
    try {
        $plainBlob = Unprotect-String $accountData.credential
    } catch {
        Write-Host "  [ERROR] Gagal mendekripsi credential. Apakah file dibuat di user Windows berbeda?" -ForegroundColor Red
        return
    }

    $user = if ($accountData.user) { $accountData.user } else { "antigravity" }
    $writeSuccess = [AgySwitchCredManager]::WriteCredential($CRED_TARGET, $user, $plainBlob)

    if (-not $writeSuccess) {
        Write-Host "  [ERROR] Gagal menulis ke Windows Credential Manager." -ForegroundColor Red
        return
    }

    $mcpBackup = Join-Path $ACCOUNTS_DIR "$($cleanName)_mcp.dat"
    $mcpTarget = Join-Path $env:USERPROFILE ".gemini\antigravity\mcp_oauth_tokens.json"
    if (Test-Path $mcpBackup) {
        try {
            $mcpPlain = Unprotect-String (Get-Content $mcpBackup -Raw)
            Set-Content -Path $mcpTarget -Value $mcpPlain -Encoding UTF8
        } catch {}
    }

    Set-Content -Path $ACTIVE_FILE -Value $cleanName -Encoding UTF8

    Write-Host "  [OK] Credential untuk '$cleanName' ($($accountData.email)) berhasil di-restore." -ForegroundColor Green

    # Restart Antigravity
    Write-Host ""
    Write-Host "  >> Merestart Antigravity..." -ForegroundColor Yellow
    $agyProcesses = Get-Process -Name "Antigravity*" -ErrorAction SilentlyContinue
    $exePath = $null

    if ($agyProcesses) {
        $exePath = $agyProcesses[0].Path
        $agyProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Host "  [OK] Antigravity dihentikan." -ForegroundColor Green
    }

    if ($exePath -and (Test-Path $exePath)) {
        Start-Process $exePath
        Write-Host "  [OK] Antigravity dijalankan kembali." -ForegroundColor Green
    } else {
        $fallbackPaths = @(
            "$env:LOCALAPPDATA\Programs\Antigravity\Antigravity.exe",
            "$env:LOCALAPPDATA\Antigravity\Antigravity.exe"
        )
        $started = $false
        foreach ($fb in $fallbackPaths) {
            if (Test-Path $fb) {
                Start-Process $fb
                Write-Host "  [OK] Antigravity dijalankan kembali ($fb)." -ForegroundColor Green
                $started = $true
                break
            }
        }
        if (-not $started) {
            Write-Host "  [INFO] Silakan buka Antigravity secara manual." -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "  Switch selesai! Sekarang kamu menggunakan akun '$cleanName'." -ForegroundColor Green
    Write-Host ""
}

function Launch-ParallelAccount {
    param([string]$Name)

    if (-not $Name) {
        Write-Host "  [ERROR] Harap tentukan nama akun untuk profil paralel. Contoh: agy-switch launch aldi" -ForegroundColor Red
        return
    }

    $cleanName = $Name.ToLower().Trim()
    $accountFile = Join-Path $ACCOUNTS_DIR "$cleanName.dat"

    if (-not (Test-Path $accountFile)) {
        Write-Host "  [ERROR] Akun '$cleanName' tidak ditemukan di accounts/." -ForegroundColor Red
        Write-Host "          Gunakan 'agy-switch list' untuk melihat akun tersimpan." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  >> Meluncurkan Profil Paralel: $cleanName" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray

    $accountData = Get-Content $accountFile -Raw | ConvertFrom-Json
    $plainBlob = $null
    try {
        $plainBlob = Unprotect-String $accountData.credential
    } catch {
        Write-Host "  [ERROR] Gagal mendekripsi credential akun." -ForegroundColor Red
        return
    }

    $targetUser = if ($accountData.user) { $accountData.user } else { "antigravity" }

    # Setup profile user data directory
    $profDir = Join-Path $env:USERPROFILE ".gemini\antigravity\profiles\$cleanName"
    $userDir = Join-Path $profDir "userdata"
    if (-not (Test-Path $userDir)) {
        New-Item -ItemType Directory -Path $userDir -Force | Out-Null
        $initStorage = @{ "ide-install-wizard-shown" = "true" } | ConvertTo-Json
        Set-Content -Path (Join-Path $userDir "app_storage.json") -Value $initStorage -Encoding UTF8
        Write-Host "  [OK] Profil direktori baru dibuat: $userDir" -ForegroundColor Green
    }

    # Find Antigravity executable
    $agyProcesses = Get-Process -Name "Antigravity*" -ErrorAction SilentlyContinue
    $exePath = $null
    if ($agyProcesses -and (Test-Path $agyProcesses[0].Path)) { $exePath = $agyProcesses[0].Path }
    if (-not $exePath) {
        $fallbackPaths = @(
            "$env:LOCALAPPDATA\Programs\Antigravity\Antigravity.exe",
            "$env:LOCALAPPDATA\Antigravity\Antigravity.exe"
        )
        foreach ($fb in $fallbackPaths) {
            if (Test-Path $fb) { $exePath = $fb; break }
        }
    }

    if (-not $exePath) {
        Write-Host "  [ERROR] Antigravity.exe tidak ditemukan di direktori instalasi standar." -ForegroundColor Red
        return
    }

    Write-Host "  >> Menginjeksikan credential '$cleanName' ($($accountData.email))..." -ForegroundColor Yellow
    $curBlob = [AgySwitchCredManager]::ReadCredential($CRED_TARGET)
    $curUser = [AgySwitchCredManager]::ReadCredentialUser($CRED_TARGET)

    [AgySwitchCredManager]::WriteCredential($CRED_TARGET, $targetUser, $plainBlob) | Out-Null

    Write-Host "  >> Menjalankan instansi Antigravity paralel..." -ForegroundColor Yellow
    Start-Process $exePath -ArgumentList "--user-data-dir=`"$userDir`""

    # MCP tokens
    $mcpBackup = Join-Path $ACCOUNTS_DIR "$($cleanName)_mcp.dat"
    $mcpTarget = Join-Path $env:USERPROFILE ".gemini\antigravity\mcp_oauth_tokens.json"
    if (Test-Path $mcpBackup) {
        try {
            $mcpPlain = Unprotect-String (Get-Content $mcpBackup -Raw)
            Set-Content -Path $mcpTarget -Value $mcpPlain -Encoding UTF8
        } catch {}
    }

    # Restore credential after delay
    if ($curBlob -and ($curBlob -ne $plainBlob)) {
        Start-Sleep -Seconds 4
        [AgySwitchCredManager]::WriteCredential($CRED_TARGET, $curUser, $curBlob) | Out-Null
        Write-Host "  [OK] Credential primer dipulihkan ke status aktif semula." -ForegroundColor DarkGray
    }

    # Create Desktop shortcut for this profile
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $lnkPath = Join-Path $desktop "Antigravity ($($cleanName.ToUpper())).lnk"
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($lnkPath)
        $sc.TargetPath = $exePath
        $sc.Arguments = "--user-data-dir=`"$userDir`""
        $sc.IconLocation = "$exePath,0"
        $sc.Description = "Antigravity Profile: $($cleanName.ToUpper())"
        $sc.Save()
        Write-Host "  [OK] Shortcut Desktop dibuat: 'Antigravity ($($cleanName.ToUpper())).lnk'" -ForegroundColor Green
    } catch {}

    Write-Host ""
    Write-Host "  [SUKSES] Profil paralel '$cleanName' berhasil berjalan bersamaan!" -ForegroundColor Green
    Write-Host "           Instansi utama Antigravity Anda tetap berjalan tanpa gangguan." -ForegroundColor Cyan
    Write-Host ""
}

function List-Profiles {
    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  >> Multi-Profile Antigravity Status" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray

    $profBase = Join-Path $env:USERPROFILE ".gemini\antigravity\profiles"
    if (-not (Test-Path $profBase)) {
        Write-Host "  Belum ada profil paralel yang dibuat." -ForegroundColor Yellow
        Write-Host "  Gunakan 'agy-switch launch <nama>' untuk membuat & membuka profil paralel." -ForegroundColor Gray
        Write-Host ""
        return
    }

    $dirs = Get-ChildItem $profBase -Directory -ErrorAction SilentlyContinue
    if (-not $dirs -or $dirs.Count -eq 0) {
        Write-Host "  Belum ada profil paralel yang dibuat." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    Write-Host "  Daftar direktori profil terisolasi:" -ForegroundColor White
    foreach ($d in $dirs) {
        $accDat = Join-Path $ACCOUNTS_DIR "$($d.Name).dat"
        $email = "(tidak terhubung ke slot)"
        if (Test-Path $accDat) {
            try {
                $info = Get-Content $accDat -Raw | ConvertFrom-Json
                $email = $info.email
            } catch {}
        }
        Write-Host "    * $($d.Name.ToUpper())" -ForegroundColor Green
        Write-Host "      Email   : $email" -ForegroundColor Cyan
        Write-Host "      Path    : $($d.FullName)\userdata" -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Show-Quota {
    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  >> Live Quota & Limits (Native agy CLI)" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor Cyan

    $activeAccount = ""
    if (Test-Path $ACTIVE_FILE) {
        $activeAccount = (Get-Content $ACTIVE_FILE -Raw).Trim()
    }
    $blob = [AgySwitchCredManager]::ReadCredential($CRED_TARGET)
    $activeEmail = if ($blob) { Extract-EmailFromToken $blob } else { $null }

    if ($activeAccount) {
        Write-Host "  Akun Aktif : $activeAccount" -ForegroundColor White
    }
    if ($activeEmail) {
        Write-Host "  Email      : $activeEmail" -ForegroundColor Cyan
    }

    Write-Host "  Fetching live data from agy CLI..." -ForegroundColor DarkGray
    $q = GetLiveAgyQuota

    if (-not $q.success) {
        Write-Host "  [ERROR] Tidak dapat mengambil quota dari agy CLI." -ForegroundColor Red
        Write-Host "          Pastikan Antigravity CLI ter-autentikasi." -ForegroundColor Yellow
        return
    }

    if ($activeAccount) {
        $qp = Join-Path $CREDITS_DIR "$($activeAccount)_quota.json"
        $q | ConvertTo-Json -Depth 5 | Set-Content -Path $qp -Encoding UTF8
    }

    Write-Host ""
    Write-Host "  [GEMINI MODELS] (Gemini Flash, Gemini Pro)" -ForegroundColor Cyan
    $g5p = [int]([math]::Round($q.gemini_5h * 100))
    $g5Bar = Format-ProgressBar $q.gemini_5h 1.0 20
    $g5Col = if ($q.gemini_5h -gt 0.2) { "Green" } else { "Red" }
    Write-Host "     5-Hour Limit   : [$g5Bar] $g5p% remaining" -ForegroundColor $g5Col
    Write-Host "                      Reset in: $(Format-Countdown $q.gemini_5h_reset)" -ForegroundColor DarkGray

    $gwp = [int]([math]::Round($q.gemini_wk * 100))
    $gwBar = Format-ProgressBar $q.gemini_wk 1.0 20
    $gwCol = if ($q.gemini_wk -gt 0.2) { "Green" } else { "Red" }
    Write-Host "     Weekly Limit   : [$gwBar] $gwp% remaining" -ForegroundColor $gwCol
    Write-Host "                      Reset in: $(Format-Countdown $q.gemini_wk_reset)" -ForegroundColor DarkGray

    Write-Host ""
    Write-Host "  [CLAUDE & GPT MODELS] (Claude Opus, Sonnet, Haiku)" -ForegroundColor Yellow
    $c5p = [int]([math]::Round($q.claude_5h * 100))
    $c5Bar = Format-ProgressBar $q.claude_5h 1.0 20
    $c5Col = if ($q.claude_5h -gt 0.2) { "Green" } else { "Red" }
    Write-Host "     5-Hour Limit   : [$c5Bar] $c5p% remaining" -ForegroundColor $c5Col
    Write-Host "                      Reset in: $(Format-Countdown $q.claude_5h_reset)" -ForegroundColor DarkGray

    $cwp = [int]([math]::Round($q.claude_wk * 100))
    $cwBar = Format-ProgressBar $q.claude_wk 1.0 20
    $cwCol = if ($q.claude_wk -gt 0.2) { "Green" } else { "Red" }
    Write-Host "     Weekly Limit   : [$cwBar] $cwp% remaining" -ForegroundColor $cwCol
    Write-Host "                      Reset in: $(Format-Countdown $q.claude_wk_reset)" -ForegroundColor DarkGray

    Write-Host ""
    Write-Host "  [AI CREDITS]" -ForegroundColor White
    Write-Host "     Extra Credits  : $($q.credits) credits" -ForegroundColor Green
    if ($q.upgrade_uri) {
        Write-Host "     Upgrade URI    : $($q.upgrade_uri)" -ForegroundColor DarkGray
    }

    Write-Host ""
}

function List-Accounts {
    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  >> Daftar Akun Tersimpan" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray

    $blob = [AgySwitchCredManager]::ReadCredential($CRED_TARGET)
    $curEmail = if ($blob) { Extract-EmailFromToken $blob } else { $null }

    $files = Get-ChildItem $ACCOUNTS_DIR -Filter "*.dat" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch "_mcp\.dat$" }

    if (-not $files -or $files.Count -eq 0) {
        Write-Host "  Belum ada akun tersimpan." -ForegroundColor Yellow
        Write-Host "  Gunakan 'agy-switch save <nama>' untuk menyimpan akun aktif." -ForegroundColor Gray
        Write-Host ""
        return
    }

    $index = 1
    foreach ($file in $files) {
        $email = Repair-AccountEmail $file.FullName
        $data = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $isActive = ($curEmail -and $data.email -eq $curEmail)
        $marker = if ($isActive) { "(*)" } else { "   " }
        $suffix = if ($isActive) { " << AKTIF" } else { "" }
        $color = if ($isActive) { "Green" } else { "White" }

        Write-Host "  $marker $index. $($data.name)$suffix" -ForegroundColor $color
        Write-Host "       Email    : $($data.email)" -ForegroundColor Cyan
        Write-Host "       Disimpan : $($data.saved_at)" -ForegroundColor DarkGray

        # Show cached quota snippet
        $qp = Join-Path $CREDITS_DIR "$($data.name)_quota.json"
        if (Test-Path $qp) {
            try {
                $q = Get-Content $qp -Raw | ConvertFrom-Json
                $g5p = [int]([math]::Round($q.gemini_5h * 100))
                $c5p = [int]([math]::Round($q.claude_5h * 100))
                Write-Host "       Quota    : Gemini 5h=$g5p% | Claude 5h=$c5p% | Credits=$($q.credits)" -ForegroundColor Cyan
            } catch {}
        }
        $index++
    }
    Write-Host ""
}

function Delete-Account {
    param([string]$Name)

    if (-not $Name) {
        Write-Host "  [ERROR] Harap tentukan nama akun yang ingin dihapus." -ForegroundColor Red
        return
    }

    $cleanName = $Name.ToLower().Trim()
    $accountFile = Join-Path $ACCOUNTS_DIR "$cleanName.dat"

    if (-not (Test-Path $accountFile)) {
        Write-Host "  [ERROR] Akun '$cleanName' tidak ditemukan." -ForegroundColor Red
        return
    }

    Remove-Item -Path $accountFile -Force
    $mcpBackup = Join-Path $ACCOUNTS_DIR "$($cleanName)_mcp.dat"
    if (Test-Path $mcpBackup) { Remove-Item -Path $mcpBackup -Force }
    $qp = Join-Path $CREDITS_DIR "$($cleanName)_quota.json"
    if (Test-Path $qp) { Remove-Item -Path $qp -Force }

    if (Test-Path $ACTIVE_FILE) {
        $current = (Get-Content $ACTIVE_FILE -Raw).Trim()
        if ($current -eq $cleanName) { Remove-Item -Path $ACTIVE_FILE -Force }
    }

    Write-Host "  [OK] Akun '$cleanName' berhasil dihapus." -ForegroundColor Green
}

function Show-Current {
    $blob = [AgySwitchCredManager]::ReadCredential($CRED_TARGET)
    $activeName = ""
    if (Test-Path $ACTIVE_FILE) {
        $activeName = (Get-Content $ACTIVE_FILE -Raw).Trim()
    }

    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  >> Status Akun Aktif" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray

    if ($blob) {
        $email = Extract-EmailFromToken $blob
        Write-Host "  Nama Tersimpan : $(if ($activeName) { $activeName } else { '(belum disimpan dengan agy-switch)' })" -ForegroundColor White
        Write-Host "  Email Akun     : $(if ($email) { $email } else { '(email tidak terdeteksi)' })" -ForegroundColor White
        Write-Host "  Credential     : Ada di Windows Credential Manager ($CRED_TARGET)" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Tidak ada credential aktif di Credential Manager." -ForegroundColor Yellow
        Write-Host "         Silakan login ke Antigravity terlebih dahulu." -ForegroundColor Yellow
    }

    Show-Quota
}

function StartBrowserGoogleLogin {
    $cid = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    
    $tcp = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $tcp.Start()
    $port = $tcp.LocalEndpoint.Port
    $tcp.Stop()

    $verifierBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($verifierBytes)
    $verifier = [Convert]::ToBase64String($verifierBytes).TrimEnd('=').Replace('+','-').Replace('/','_')

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $challengeBytes = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
    $challenge = [Convert]::ToBase64String($challengeBytes).TrimEnd('=').Replace('+','-').Replace('/','_')

    $redirectUri = "http://127.0.0.1:$port/"

    $http = New-Object System.Net.HttpListener
    $http.Prefixes.Add($redirectUri)
    $http.Start()

    $authUrl = "https://accounts.google.com/o/oauth2/v2/auth?client_id=$cid&redirect_uri=$([System.Uri]::EscapeDataString($redirectUri))&response_type=code&scope=openid%20email%20profile&code_challenge=$challenge&code_challenge_method=S256&prompt=select_account"
    Start-Process $authUrl

    $asyncResult = $http.BeginGetContext($null, $null)
    $waitHandle = $asyncResult.AsyncWaitHandle
    $success = $waitHandle.WaitOne([TimeSpan]::FromSeconds(180))

    if (-not $success) {
        $http.Stop()
        return @{ success = $false; error = "TIMEOUT" }
    }

    $context = $http.EndGetContext($asyncResult)
    $request = $context.Request
    $response = $context.Response

    $code = $request.QueryString["code"]
    $error = $request.QueryString["error"]

    $html = "<html><body style='font-family:Consolas,monospace;text-align:center;padding:50px;background:#161408;color:#FFE633;'><h2>LOGIN BERHASIL!</h2><p style='color:#B3A220;'>Akun Google Anda berhasil terhubung ke Antigravity Switcher.<br>Silakan tutup tab ini dan kembali ke terminal.</p></body></html>"
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
    $response.ContentLength64 = $buffer.Length
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.OutputStream.Close()
    $http.Stop()

    if ($error -or -not $code) {
        return @{ success = $false; error = if ($error) { $error } else { "NO_CODE" } }
    }

    try {
        $tokenBody = @{
            client_id = $cid
            code = $code
            code_verifier = $verifier
            grant_type = "authorization_code"
            redirect_uri = $redirectUri
        }
        $tokenResp = Invoke-RestMethod -Uri "https://oauth2.googleapis.com/token" -Method Post -Body $tokenBody -EA Stop
        
        $credObj = @{
            token = @{
                access_token = $tokenResp.access_token
                token_type = if ($tokenResp.token_type) { $tokenResp.token_type } else { "Bearer" }
                refresh_token = $tokenResp.refresh_token
                expiry = (Get-Date).AddSeconds($tokenResp.expires_in).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.ffffffZ")
            }
            auth_method = "oauth"
            id_token = $tokenResp.id_token
        }
        $credJson = $credObj | ConvertTo-Json -Depth 5
        $email = Extract-EmailFromToken $credJson

        return @{
            success = $true
            email = $email
            credential = $credJson
        }
    } catch {
        return @{ success = $false; error = "EXCHANGE_FAILED: $_" }
    }
}

function Login-NewAccount {
    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  >> Menambah / Login Akun Baru (Tanpa Sign Out Manual)" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "  >> Membuka browser untuk login Google..." -ForegroundColor Yellow
    Write-Host "     (Antigravity TETAP BERJALAN AMAN - tidak akan ditutup/direstart)" -ForegroundColor Green
    Write-Host "     Silakan selesaikan login di browser..." -ForegroundColor DarkGray

    $res = StartBrowserGoogleLogin

    if ($res.success) {
        Write-Host ""
        Write-Host "  [OK] Login berhasil terdeteksi!" -ForegroundColor Green
        Write-Host "       Email: $($res.email)" -ForegroundColor Cyan

        $suggestedName = if ($res.email -and $res.email -match "^([^@]+)") { $matches[1] } else { "akun" }
        Write-Host ""
        $newName = Read-Host "  Beri nama untuk akun baru ini (tekan Enter untuk '$suggestedName')"
        if (-not $newName) { $newName = $suggestedName }

        $cleanName = $newName.ToLower().Trim()
        $encryptedBlob = Protect-String $res.credential

        $accountData = @{
            name        = $cleanName
            user        = "antigravity"
            email       = $res.email
            credential  = $encryptedBlob
            saved_at    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }

        $accountFile = Join-Path $ACCOUNTS_DIR "$cleanName.dat"
        $accountData | ConvertTo-Json -Depth 5 | Set-Content -Path $accountFile -Encoding UTF8

        Write-Host ""
        Write-Host "  [OK] Akun baru '$cleanName' ($($res.email)) berhasil disimpan!" -ForegroundColor Green
        Write-Host "       Tersedia di daftar akun. Untuk menggunakannya nanti, jalankan: agy-switch use $cleanName" -ForegroundColor DarkGray
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "  [WARN] Login dibatalkan atau gagal: $($res.error)" -ForegroundColor Yellow
        Write-Host ""
    }
}

function Open-Gui {
    $guiScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "AgySwitch-GUI.ps1"
    if (Test-Path $guiScript) {
        Start-Process powershell -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-STA","-WindowStyle","Hidden","-File","`"$guiScript`""
        Write-Host "  [OK] GUI HUD diluncurkan!" -ForegroundColor Green
    } else {
        Write-Host "  [ERROR] File GUI tidak ditemukan: $guiScript" -ForegroundColor Red
    }
}

# ============================================================================
# Router
# ============================================================================

switch ($Command.ToLower()) {
    "save"     { Save-Account -Name $TargetName }
    "login"    { Login-NewAccount }
    "add"      { Login-NewAccount }
    "use"      { Use-Account -Name $TargetName }
    "launch"   { Launch-ParallelAccount -Name $TargetName }
    "parallel" { Launch-ParallelAccount -Name $TargetName }
    "profiles" { List-Profiles }
    "list"     { List-Accounts }
    "delete"   { Delete-Account -Name $TargetName }
    "current"  { Show-Current }
    "quota"    { Show-Quota }
    "credits"  { Show-Quota }
    "gui"      { Open-Gui }
    "help"     { Show-Help }
    default    { Show-Help }
}
