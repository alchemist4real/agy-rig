# agy-rig.ps1 - AGY RIG // Multi-Account Manager & Quota Telemetry CLI
# Commands: save, use, list, delete, current, quota (or credits), launch, login, gui, help

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
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
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
        if (string.IsNullOrEmpty(blob)) return false;
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

public class Win32WindowHelper {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}

public class AgyVaultCrypto {
    private const int SaltSize = 16;
    private const int IvSize = 16;
    private const int HmacSize = 32;
    private const int Iterations = 100000;

    public static string Encrypt(string plainText, string passphrase) {
        byte[] salt = new byte[SaltSize];
        using (var rng = RandomNumberGenerator.Create()) {
            rng.GetBytes(salt);
        }

        byte[] key;
        byte[] iv;
        using (var derive = new Rfc2898DeriveBytes(passphrase, salt, Iterations)) {
            key = derive.GetBytes(32);
            iv = derive.GetBytes(IvSize);
        }

        byte[] plainBytes = Encoding.UTF8.GetBytes(plainText);
        byte[] cipherBytes;

        using (var aes = Aes.Create()) {
            aes.Key = key;
            aes.IV = iv;
            aes.Mode = CipherMode.CBC;
            aes.Padding = PaddingMode.PKCS7;

            using (var ms = new MemoryStream()) {
                using (var cs = new CryptoStream(ms, aes.CreateEncryptor(), CryptoStreamMode.Write)) {
                    cs.Write(plainBytes, 0, plainBytes.Length);
                    cs.FlushFinalBlock();
                }
                cipherBytes = ms.ToArray();
            }
        }

        byte[] hmacTag;
        using (var hmac = new HMACSHA256(key)) {
            hmacTag = hmac.ComputeHash(cipherBytes);
        }

        using (var outMs = new MemoryStream()) {
            outMs.Write(salt, 0, salt.Length);
            outMs.Write(iv, 0, iv.Length);
            outMs.Write(hmacTag, 0, hmacTag.Length);
            outMs.Write(cipherBytes, 0, cipherBytes.Length);
            return Convert.ToBase64String(outMs.ToArray());
        }
    }

    public static string Decrypt(string encBase64, string passphrase) {
        byte[] rawBytes = Convert.FromBase64String(encBase64);
        if (rawBytes.Length < (SaltSize + IvSize + HmacSize)) {
            throw new Exception("Vault payload is truncated or invalid.");
        }

        byte[] salt = new byte[SaltSize];
        byte[] iv = new byte[IvSize];
        byte[] hmacTag = new byte[HmacSize];

        Buffer.BlockCopy(rawBytes, 0, salt, 0, SaltSize);
        Buffer.BlockCopy(rawBytes, SaltSize, iv, 0, IvSize);
        Buffer.BlockCopy(rawBytes, SaltSize + IvSize, hmacTag, 0, HmacSize);

        int cipherLen = rawBytes.Length - (SaltSize + IvSize + HmacSize);
        byte[] cipherBytes = new byte[cipherLen];
        Buffer.BlockCopy(rawBytes, SaltSize + IvSize + HmacSize, cipherBytes, 0, cipherLen);

        byte[] key;
        using (var derive = new Rfc2898DeriveBytes(passphrase, salt, Iterations)) {
            key = derive.GetBytes(32);
        }

        using (var hmac = new HMACSHA256(key)) {
            byte[] calcTag = hmac.ComputeHash(cipherBytes);
            int diff = 0;
            for (int i = 0; i < HmacSize; i++) {
                diff |= calcTag[i] ^ hmacTag[i];
            }
            if (diff != 0) {
                throw new Exception("HMAC verification failed: corrupted vault or incorrect passphrase.");
            }
        }

        using (var aes = Aes.Create()) {
            aes.Key = key;
            aes.IV = iv;
            aes.Mode = CipherMode.CBC;
            aes.Padding = PaddingMode.PKCS7;

            using (var ms = new MemoryStream()) {
                using (var cs = new CryptoStream(ms, aes.CreateDecryptor(), CryptoStreamMode.Write)) {
                    cs.Write(cipherBytes, 0, cipherBytes.Length);
                    cs.FlushFinalBlock();
                }
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }
    }
}
"@ -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Security

# ============================================================================
# Dynamic Path Resolution (Zero Hardcoded Usernames or Paths)
# ============================================================================

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PWD.Path }
$appDataDir = Join-Path $env:LOCALAPPDATA "AgyRig"
$legacyScratch = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".gemini\antigravity\scratch\agy-switch"

if (Test-Path (Join-Path $appDataDir "accounts")) {
    $BASE_DIR = $appDataDir
} elseif (Test-Path (Join-Path $scriptDir "accounts")) {
    $BASE_DIR = $scriptDir
} elseif (Test-Path (Join-Path $legacyScratch "accounts")) {
    $BASE_DIR = $legacyScratch
} else {
    $BASE_DIR = $appDataDir
}

$CRED_TARGET  = "gemini:antigravity"
$ACCOUNTS_DIR = Join-Path $BASE_DIR "accounts"
$CREDITS_DIR  = Join-Path $BASE_DIR "credits"
$ACTIVE_FILE  = Join-Path $BASE_DIR "active_account.txt"
$userProf     = [Environment]::GetFolderPath("UserProfile")
$PROFILES_DIR = Join-Path $userProf ".gemini\antigravity\profiles"

# Resolve icon path dynamically
$ICON_PATH = Join-Path $BASE_DIR "agy-rig.ico"
if (-not (Test-Path $ICON_PATH)) {
    if (Test-Path (Join-Path $appDataDir "agy-rig.ico")) { $ICON_PATH = Join-Path $appDataDir "agy-rig.ico" }
    elseif (Test-Path (Join-Path $scriptDir "agy-rig.ico")) { $ICON_PATH = Join-Path $scriptDir "agy-rig.ico" }
}

foreach ($dir in @($ACCOUNTS_DIR, $CREDITS_DIR, $PROFILES_DIR)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# Auto-migrate accounts to AppData if needed
if ($BASE_DIR -eq $appDataDir -and (Get-ChildItem $ACCOUNTS_DIR -Filter "*.dat" -EA SilentlyContinue).Count -eq 0) {
    if (Test-Path (Join-Path $legacyScratch "accounts")) {
        Copy-Item (Join-Path $legacyScratch "accounts\*.dat") $ACCOUNTS_DIR -Force -EA SilentlyContinue
        Copy-Item (Join-Path $legacyScratch "credits\*.json") $CREDITS_DIR -Force -EA SilentlyContinue
        if (Test-Path (Join-Path $legacyScratch "active_account.txt")) {
            Copy-Item (Join-Path $legacyScratch "active_account.txt") $ACTIVE_FILE -Force -EA SilentlyContinue
        }
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
        if (-not $data.email -or $data.email -like "*(not detected)*" -or $data.email -like "*(tidak terdeteksi)*") {
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

function Find-AntigravityExe {
    $pr = Get-Process -Name "Antigravity*" -ErrorAction SilentlyContinue
    if ($pr) {
        try {
            $p = $pr[0].Path
            if ($p -and (Test-Path $p)) { return $p }
        } catch {}
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Antigravity\Antigravity.exe"),
        (Join-Path $env:LOCALAPPDATA "Antigravity\Antigravity.exe"),
        (Join-Path $env:ProgramFiles "Antigravity\Antigravity.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Antigravity\Antigravity.exe"),
        (Join-Path $env:USERPROFILE ".gemini\antigravity\bin\Antigravity.exe")
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $cmd = Get-Command antigravity -ErrorAction SilentlyContinue
    if ($cmd -and (Test-Path $cmd.Source)) { return $cmd.Source }
    return $null
}

function Find-AgyBin {
    $cmd = Get-Command agy -ErrorAction SilentlyContinue
    if ($cmd -and (Test-Path $cmd.Source)) { return $cmd.Source }
    $defaultAgy = Join-Path $env:USERPROFILE ".gemini\antigravity\bin\agy.exe"
    if (Test-Path $defaultAgy) { return $defaultAgy }
    return "agy"
}

function ReadActiveCredentialBlob {
    $b = [AgySwitchCredManager]::ReadCredential($CRED_TARGET)
    if (-not $b) {
        $b = [AgySwitchCredManager]::ReadCredential("antigravity_google_oauth_credential")
    }
    return $b
}

function ReadActiveCredentialUser {
    $u = [AgySwitchCredManager]::ReadCredentialUser($CRED_TARGET)
    if (-not $u) {
        $u = [AgySwitchCredManager]::ReadCredentialUser("antigravity_google_oauth_credential")
    }
    if (-not $u) { $u = "antigravity" }
    return $u
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

    $cliPath = Find-AgyBin

    try {
        $uRaw = & $cliPath -p "/usage" --output-format json 2>$null
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

        $cRaw = & $cliPath -p "/credits" --output-format json 2>$null
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
    Write-Host "  ================================================================" -ForegroundColor DarkYellow
    Write-Host "  >> AGY RIG // Multi-Account Manager, Parallel Engine & Vault" -ForegroundColor Yellow
    Write-Host "  ================================================================" -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "  == PRIMARY INSTANCE & ACCOUNTS ==" -ForegroundColor White
    Write-Host "    scan                        Scan active login credentials in Antigravity" -ForegroundColor Gray
    Write-Host "    save <name>                 Save active session into named account slot" -ForegroundColor Gray
    Write-Host "    login                       Log into a new Google account via browser" -ForegroundColor Gray
    Write-Host "    use <name>                  Switch primary Antigravity session to account" -ForegroundColor Gray
    Write-Host "    switch <name>               Alias for 'use'" -ForegroundColor Gray
    Write-Host "    list                        List all saved accounts and cached quota status" -ForegroundColor Gray
    Write-Host "    delete <name>               Delete a saved account slot" -ForegroundColor Gray
    Write-Host "    current                     Display active account and current live quota" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  == PARALLEL SESSIONS (1-TO-UNLIMITED) ==" -ForegroundColor White
    Write-Host "    parallel list               List running sessions (PID, status, title)" -ForegroundColor Gray
    Write-Host "    parallel switch <name>      Focus profile window if running, or launch if idle" -ForegroundColor Gray
    Write-Host "    parallel launch <name>      Launch new isolated parallel instance" -ForegroundColor Gray
    Write-Host "    parallel close <name|all>   Stop specific or all parallel instances" -ForegroundColor Gray
    Write-Host "    launch <name>               Quick alias for 'parallel launch'" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  == PRIVATE GITHUB VAULT (BACKUP & RESTORE) ==" -ForegroundColor White
    Write-Host "    vault backup [repo]         Encrypt (AES-256) & push credentials to private GitHub" -ForegroundColor Gray
    Write-Host "    vault import [repo]         Pull & decrypt credentials from private GitHub repo" -ForegroundColor Gray
    Write-Host "    backup                      Quick alias for 'vault backup'" -ForegroundColor Gray
    Write-Host "    import                      Quick alias for 'vault import'" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  == QUOTA & HUD DOCK ==" -ForegroundColor White
    Write-Host "    quota                       Fetch real-time quota telemetry from agy CLI" -ForegroundColor Gray
    Write-Host "    credits                     Alias for 'quota'" -ForegroundColor Gray
    Write-Host "    gui                         Launch compact visual HUD dock" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  == EXAMPLES ==" -ForegroundColor White
    Write-Host "    agy-rig scan" -ForegroundColor Cyan
    Write-Host "    agy-rig switch alchemist" -ForegroundColor Cyan
    Write-Host "    agy-rig parallel list" -ForegroundColor Cyan
    Write-Host "    agy-rig parallel switch muqorroben" -ForegroundColor Cyan
    Write-Host "    agy-rig vault backup" -ForegroundColor Cyan
    Write-Host "    agy-rig vault import" -ForegroundColor Cyan
    Write-Host ""
}

function Save-Account {
    param([string]$Name)

    if (-not $Name) {
        Write-Host "  [ERROR] Please specify account name. Example: agy-rig save work" -ForegroundColor Red
        return
    }

    $cleanName = $Name.ToLower().Trim()

    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  >> Saving Account: $cleanName" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray

    $blob = ReadActiveCredentialBlob
    $user = ReadActiveCredentialUser

    if (-not $blob) {
        Write-Host "  [ERROR] No credential found for '$CRED_TARGET' in Credential Manager." -ForegroundColor Red
        Write-Host "          Please log into Antigravity first." -ForegroundColor Yellow
        return
    }

    $email = Extract-EmailFromToken $blob
    $encryptedBlob = Protect-String $blob

    $accountData = @{
        name        = $cleanName
        user        = $user
        email       = if ($email) { $email } else { "(email not detected)" }
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
    Write-Host "  [OK] Account '$cleanName' saved successfully." -ForegroundColor Green
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
        Write-Host "  [ERROR] Please specify account name. Example: agy-rig use alchemist" -ForegroundColor Red
        return
    }

    $cleanName = $Name.ToLower().Trim()
    $accountFile = Join-Path $ACCOUNTS_DIR "$cleanName.dat"

    if (-not (Test-Path $accountFile)) {
        Write-Host "  [ERROR] Account '$cleanName' not found." -ForegroundColor Red
        Write-Host "          Use 'agy-rig list' to view saved accounts." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "  [WARNING] Switching to '$cleanName' will restart primary Antigravity." -ForegroundColor Yellow
    Write-Host "            Please ensure any unsaved work in primary instance is saved." -ForegroundColor Yellow
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        $ans = Read-Host "  Restart primary Antigravity now? (y/N)"
        if ($ans -notmatch "^[yY]([eE][sS])?$") {
            Write-Host "  [CANCELLED] Switch cancelled. Primary instance is unchanged." -ForegroundColor Green
            return
        }
    }

    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  >> Switching to account: $cleanName" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray

    $accountData = Get-Content $accountFile -Raw | ConvertFrom-Json
    $plainBlob = $null
    try {
        $plainBlob = Unprotect-String $accountData.credential
    } catch {
        Write-Host "  [ERROR] Failed to decrypt credential." -ForegroundColor Red
        return
    }

    $user = if ($accountData.user) { $accountData.user } else { "antigravity" }
    $writeSuccess = [AgySwitchCredManager]::WriteCredential($CRED_TARGET, $user, $plainBlob)

    if (-not $writeSuccess) {
        Write-Host "  [ERROR] Failed to write credential to Credential Manager." -ForegroundColor Red
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

    Write-Host "  [OK] Credentials for '$cleanName' ($($accountData.email)) restored." -ForegroundColor Green

    # Restart ONLY primary Antigravity (protect running parallel instances!)
    Write-Host ""
    Write-Host "  >> Restarting primary Antigravity..." -ForegroundColor Yellow
    $activeProcs = Get-ParallelProcesses
    $mainProc = $activeProcs | Where-Object { -not $_.IsParallel }

    if ($mainProc) {
        Stop-Process -Id $mainProc.ProcessId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Host "  [OK] Primary Antigravity stopped." -ForegroundColor Green
    }

    $exePath = Find-AntigravityExe
    if ($exePath -and (Test-Path $exePath)) {
        Start-Process $exePath
        Write-Host "  [OK] Primary Antigravity started ($exePath)." -ForegroundColor Green
    } else {
        Write-Host "  [INFO] Please open Antigravity manually." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  Switch complete. Active account is now '$cleanName'." -ForegroundColor Green
    Write-Host ""
}

function Launch-ParallelAccount {
    param([string]$Name)

    if (-not $Name) {
        Write-Host "  [ERROR] Please specify account name for parallel profile. Example: agy-rig launch alchemist" -ForegroundColor Red
        return
    }

    $cleanName = $Name.ToLower().Trim()
    $accountFile = Join-Path $ACCOUNTS_DIR "$cleanName.dat"

    if (-not (Test-Path $accountFile)) {
        Write-Host "  [ERROR] Account '$cleanName' not found in accounts/." -ForegroundColor Red
        Write-Host "          Use 'agy-rig list' to view saved accounts." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  >> Launching Parallel Profile: $cleanName" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray

    $accountData = Get-Content $accountFile -Raw | ConvertFrom-Json
    $plainBlob = $null
    try {
        $plainBlob = Unprotect-String $accountData.credential
    } catch {
        Write-Host "  [ERROR] Failed to decrypt account credential." -ForegroundColor Red
        return
    }

    $targetUser = if ($accountData.user) { $accountData.user } else { "antigravity" }

    # Setup profile user data directory
    $profDir = Join-Path $PROFILES_DIR $cleanName
    $userDir = Join-Path $profDir "userdata"
    if (-not (Test-Path $userDir)) {
        New-Item -ItemType Directory -Path $userDir -Force | Out-Null
        $initStorage = @{ "ide-install-wizard-shown" = "true" } | ConvertTo-Json
        Set-Content -Path (Join-Path $userDir "app_storage.json") -Value $initStorage -Encoding UTF8
        Write-Host "  [OK] New profile directory created: $userDir" -ForegroundColor Green
    }

    # Find Antigravity executable dynamically
    $exePath = Find-AntigravityExe
    if (-not $exePath) {
        Write-Host "  [ERROR] Antigravity executable not found." -ForegroundColor Red
        return
    }

    Write-Host "  >> Injecting credentials for '$cleanName' ($($accountData.email))..." -ForegroundColor Yellow
    $curBlob = ReadActiveCredentialBlob
    $curUser = ReadActiveCredentialUser

    [AgySwitchCredManager]::WriteCredential($CRED_TARGET, $targetUser, $plainBlob) | Out-Null

    Write-Host "  >> Starting parallel Antigravity instance..." -ForegroundColor Yellow
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
        Write-Host "  [OK] Primary credentials restored to active state." -ForegroundColor DarkGray
    }

    # Create Desktop shortcut for this profile with rounded icon
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $lnkPath = Join-Path $desktop "Antigravity ($($cleanName.ToUpper())).lnk"
        $shell = New-Object -ComObject WScript.Shell
        try {
            $sc = $shell.CreateShortcut($lnkPath)
            $sc.TargetPath = $exePath
            $sc.Arguments = "--user-data-dir=`"$userDir`""
            $sc.IconLocation = "$ICON_PATH,0"
            $sc.Description = "Antigravity Profile: $($cleanName.ToUpper())"
            $sc.Save()
            Write-Host "  [OK] Desktop shortcut created: 'Antigravity ($($cleanName.ToUpper())).lnk'" -ForegroundColor Green
        } finally {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        }
    } catch {}

    Write-Host ""
    Write-Host "  [SUCCESS] Parallel profile '$cleanName' is running concurrently." -ForegroundColor Green
    Write-Host "            Your primary Antigravity instance continues running undisturbed." -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================================
# CREDENTIAL SCANNER (Main Antigravity Ecosystem)
# ============================================================================

function Scan-AntigravityCredentials {
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor DarkYellow
    Write-Host "  >> SCANNING ANTIGRAVITY CREDENTIAL ECOSYSTEM" -ForegroundColor Yellow
    Write-Host "  ================================================================" -ForegroundColor DarkYellow
    Write-Host ""

    $activeBlob = ReadActiveCredentialBlob
    $activeUser = ReadActiveCredentialUser
    $activeEmail = Extract-EmailFromToken $activeBlob

    # 1. Primary Windows Credential Manager
    Write-Host "  [1/4] Windows Credential Manager" -ForegroundColor Cyan
    if ($activeBlob) {
        Write-Host "        Status       : [CONNECTED]" -ForegroundColor Green
        Write-Host "        Target       : $CRED_TARGET" -ForegroundColor Gray
        Write-Host "        User         : $activeUser" -ForegroundColor Gray
        Write-Host "        Account Email: $activeEmail" -ForegroundColor White
        
        # Check token expiry
        try {
            $tokObj = $activeBlob | ConvertFrom-Json -EA SilentlyContinue
            $exp = if ($tokObj.token -and $tokObj.token.expiry) { $tokObj.token.expiry } else { $null }
            if ($exp) {
                Write-Host "        Token Expiry : $exp" -ForegroundColor DarkGray
            }
        } catch {}
    } else {
        Write-Host "        Status       : [NOT FOUND]" -ForegroundColor Red
        Write-Host "        Note         : No active Google login session in Antigravity" -ForegroundColor Yellow
    }

    # 2. MCP OAuth Tokens
    Write-Host "`n  [2/4] MCP OAuth Tokens (mcp_oauth_tokens.json)" -ForegroundColor Cyan
    $mcpPath = Join-Path $env:USERPROFILE ".gemini\antigravity\mcp_oauth_tokens.json"
    if (Test-Path $mcpPath) {
        $mcpLen = (Get-Item $mcpPath).Length
        Write-Host "        File         : $mcpPath ($mcpLen bytes)" -ForegroundColor Gray
        Write-Host "        Status       : [ACTIVE]" -ForegroundColor Green
    } else {
        Write-Host "        Status       : [NOT PRESENT] (Normal if no OAuth MCP configured)" -ForegroundColor DarkGray
    }

    # 3. CLI State / Identity
    Write-Host "`n  [3/4] AGY CLI State (jetski_state.pbtxt)" -ForegroundColor Cyan
    $jetskiPath = Join-Path $env:USERPROFILE ".gemini\antigravity-cli\jetski_state.pbtxt"
    if (Test-Path $jetskiPath) {
        Write-Host "        File         : $jetskiPath" -ForegroundColor Gray
        Write-Host "        Status       : [INITIALIZED]" -ForegroundColor Green
    } else {
        Write-Host "        Status       : [NOT INITIALIZED]" -ForegroundColor DarkGray
    }

    # 4. Compare with Saved Accounts
    Write-Host "`n  [4/4] AGY RIG Account Synchronization" -ForegroundColor Cyan
    $savedAccounts = Get-ChildItem $ACCOUNTS_DIR -Filter "*.dat" -EA SilentlyContinue | Where-Object { $_.Name -notmatch "_mcp" }
    $matchedAccount = $null

    foreach ($sa in $savedAccounts) {
        try {
            $data = Get-Content $sa.FullName -Raw | ConvertFrom-Json
            if ($data.email -and $activeEmail -and ($data.email.ToLower() -eq $activeEmail.ToLower())) {
                $matchedAccount = $data
                break
            }
        } catch {}
    }

    if ($matchedAccount) {
        Write-Host "        Saved Slot   : $($matchedAccount.name) [$($matchedAccount.email)]" -ForegroundColor Green
        Write-Host "        Sync Status  : [REGISTERED IN AGY RIG]" -ForegroundColor Green
    } elseif ($activeEmail) {
        Write-Host "        Warning      : Active Google account '$activeEmail' is NOT saved in AGY RIG slots!" -ForegroundColor Yellow
        Write-Host ""
        if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
            $defName = ($activeEmail.Split('@')[0]).ToLower()
            $saveAns = Read-Host "        Would you like to save this active session as slot [$defName]? (Y/n)"
            if ($saveAns -match "^[nN]") {
                Write-Host "        [SKIPPED] Account not saved." -ForegroundColor DarkGray
            } else {
                $chosenName = Read-Host "        Enter slot name (press Enter for '$defName')"
                if (-not $chosenName) { $chosenName = $defName }
                Save-Account -Name $chosenName
            }
        } else {
            Write-Host "        Suggestion   : Save this account with: agy-rig save <name>" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "        Note         : No active account to synchronize." -ForegroundColor DarkGray
    }

    Write-Host ""
}

# ============================================================================
# PARALEL ENGINE (1-to-Unlimited Sessions, Focus & Management)
# ============================================================================

function Get-ParallelProcesses {
    $results = @()
    $rootProcs = Get-CimInstance Win32_Process -Filter "Name like 'Antigravity%'" -EA SilentlyContinue | Where-Object {
        $_.CommandLine -notmatch "--type="
    }

    foreach ($p in $rootProcs) {
        $isParallel = $p.CommandLine -match '--user-data-dir=[^"''\s]*[\\/]profiles[\\/]([^\\/''"\s]+)'
        $profName = if ($isParallel) { $matches[1] } else { "(PRIMARY)" }
        $proc = Get-Process -Id $p.ProcessId -EA SilentlyContinue
        $results += [PSCustomObject]@{
            ProcessId   = $p.ProcessId
            ProfileName = $profName.ToLower()
            IsParallel  = [bool]$isParallel
            Title       = if ($proc) { $proc.MainWindowTitle } else { "" }
            ProcessObj  = $proc
            CommandLine = $p.CommandLine
        }
    }
    return $results
}

function List-ParallelSessions {
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host "  >> ANTIGRAVITY SESSIONS & PROFILES (1-UNLIMITED)" -ForegroundColor Cyan
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host ""

    $activeProcs = Get-ParallelProcesses
    $savedAccounts = Get-ChildItem $ACCOUNTS_DIR -Filter "*.dat" -EA SilentlyContinue | Where-Object { $_.Name -notmatch "_mcp" }

    Write-Host "  --------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  STATUS    #  SLOT/PROFILE     EMAIL                                  PID     TITLE / INFO" -ForegroundColor White
    Write-Host "  --------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray

    # 1. Main instance
    $mainProc = $activeProcs | Where-Object { -not $_.IsParallel }
    $mainStatus = if ($mainProc) { "[RUNNING]" } else { "[STOPPED]" }
    $mainColor  = if ($mainProc) { "Green" } else { "DarkGray" }
    $activeBlob = ReadActiveCredentialBlob
    $activeEmail = if ($activeBlob) { Extract-EmailFromToken $activeBlob } else { "(not logged in)" }
    $mainPid = if ($mainProc) { $mainProc.ProcessId } else { "--" }
    Write-Host "  $mainStatus " -ForegroundColor $mainColor -NoNewline
    Write-Host "0  PRIMARY (DEFAULT)" -ForegroundColor Yellow -NoNewline
    Write-Host ("{0,-38} " -f $activeEmail) -ForegroundColor Gray -NoNewline
    Write-Host ("{0,-7}" -f $mainPid) -ForegroundColor Cyan -NoNewline
    Write-Host "Primary Antigravity Window" -ForegroundColor DarkGray

    # 2. Parallel profiles / saved accounts
    $index = 1
    foreach ($sa in $savedAccounts) {
        $accName = $sa.BaseName.ToLower()
        $accData = $null
        try { $accData = Get-Content $sa.FullName -Raw | ConvertFrom-Json } catch {}
        $email = if ($accData -and $accData.email) { $accData.email } else { "--" }

        # Check if running in parallel
        $runProc = $activeProcs | Where-Object { $_.IsParallel -and ($_.ProfileName -eq $accName) }
        $statusStr = if ($runProc) { "[RUNNING]" } else { "[IDLE]   " }
        $statusColor = if ($runProc) { "Green" } else { "Gray" }
        $pidStr = if ($runProc) { $runProc.ProcessId } else { "--" }
        $titleStr = if ($runProc -and $runProc.Title) { $runProc.Title } else { if ($runProc) { "Active Parallel Session" } else { "Ready to launch" } }

        Write-Host "  $statusStr " -ForegroundColor $statusColor -NoNewline
        Write-Host ("{0,-2} {1,-16} " -f $index, $accName.ToUpper()) -ForegroundColor White -NoNewline
        Write-Host ("{0,-38} " -f $email) -ForegroundColor Gray -NoNewline
        Write-Host ("{0,-7}" -f $pidStr) -ForegroundColor Cyan -NoNewline
        Write-Host "$titleStr" -ForegroundColor DarkGray

        $index++
    }

    Write-Host "  --------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  Quick Commands:" -ForegroundColor DarkYellow
    Write-Host "    agy-rig parallel switch <name>  # Focus window if running, or launch if idle" -ForegroundColor Gray
    Write-Host "    agy-rig parallel launch <name>  # Launch new parallel instance" -ForegroundColor Gray
    Write-Host "    agy-rig parallel close <name>   # Stop specific parallel instance" -ForegroundColor Gray
    Write-Host ""
}

function Switch-ParallelSession {
    param([string]$Name)

    if (-not $Name) {
        Write-Host "  [ERROR] Please specify profile/account name. Example: agy-rig parallel switch alchemist" -ForegroundColor Red
        return
    }

    $cleanName = $Name.ToLower().Trim()

    # If user wants to switch to main instance
    if ($cleanName -eq "utama" -or $cleanName -eq "main" -or $cleanName -eq "default") {
        $mainProc = Get-ParallelProcesses | Where-Object { -not $_.IsParallel }
        if ($mainProc -and $mainProc.ProcessObj -and $mainProc.ProcessObj.MainWindowHandle -ne [IntPtr]::Zero) {
            [Win32WindowHelper]::ShowWindowAsync($mainProc.ProcessObj.MainWindowHandle, 9) | Out-Null
            [Win32WindowHelper]::SetForegroundWindow($mainProc.ProcessObj.MainWindowHandle) | Out-Null
            Write-Host "  [OK] Primary Antigravity window brought to front." -ForegroundColor Green
            return
        }
    }

    # Check if already running in parallel
    $activeProcs = Get-ParallelProcesses
    $running = $activeProcs | Where-Object { $_.IsParallel -and ($_.ProfileName -eq $cleanName) }

    if ($running -and $running.ProcessObj -and $running.ProcessObj.MainWindowHandle -ne [IntPtr]::Zero) {
        Write-Host "  [OK] Profile '$cleanName' is already running (PID: $($running.ProcessId)). Bringing window to front..." -ForegroundColor Green
        [Win32WindowHelper]::ShowWindowAsync($running.ProcessObj.MainWindowHandle, 9) | Out-Null
        [Win32WindowHelper]::SetForegroundWindow($running.ProcessObj.MainWindowHandle) | Out-Null
        return
    }

    # If not running, launch it!
    Write-Host "  [INFO] Profile '$cleanName' is not running. Launching parallel instance..." -ForegroundColor Cyan
    Launch-ParallelAccount -Name $cleanName
}

function Close-ParallelSession {
    param([string]$Name)

    if (-not $Name) {
        Write-Host "  [ERROR] Specify profile name to close, or 'all' to close all parallel sessions." -ForegroundColor Red
        return
    }

    $cleanName = $Name.ToLower().Trim()
    $activeProcs = Get-ParallelProcesses

    if ($cleanName -eq "all") {
        $targets = $activeProcs | Where-Object { $_.IsParallel }
        if (-not $targets) {
            Write-Host "  [INFO] No parallel sessions are currently running." -ForegroundColor Yellow
            return
        }
        foreach ($t in $targets) {
            Write-Host "  Stopping parallel session: $($t.ProfileName) (PID: $($t.ProcessId))..." -ForegroundColor DarkGray
            Stop-Process -Id $t.ProcessId -Force -EA SilentlyContinue
        }
        Write-Host "  [OK] All ($($targets.Count)) parallel sessions stopped." -ForegroundColor Green
        return
    }

    $target = $activeProcs | Where-Object { $_.IsParallel -and ($_.ProfileName -eq $cleanName) }
    if (-not $target) {
        Write-Host "  [WARN] Parallel session '$cleanName' is not currently running." -ForegroundColor Yellow
        return
    }

    Stop-Process -Id $target.ProcessId -Force -EA SilentlyContinue
    Write-Host "  [OK] Parallel session '$cleanName' (PID: $($target.ProcessId)) stopped." -ForegroundColor Green
}

# ============================================================================
# PRIVATE GITHUB VAULT (Encrypted Backup & Import via gh CLI)
# ============================================================================

function Backup-VaultToGitHub {
    param(
        [string]$Repo = "agy-rig-vault",
        [string]$Passphrase = ""
    )

    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor DarkYellow
    Write-Host "  >> AGY RIG // PRIVATE GITHUB VAULT BACKUP" -ForegroundColor Yellow
    Write-Host "  ================================================================" -ForegroundColor DarkYellow
    Write-Host ""

    # 1. Check gh CLI
    $ghStatus = & gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [ERROR] GitHub CLI ('gh') is not authenticated." -ForegroundColor Red
        Write-Host "          Run 'gh auth login' first." -ForegroundColor Yellow
        return
    }

    # 2. Get passphrase
    $pass = $Passphrase
    if (-not $pass) {
        if (-not ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)) {
            Write-Host "  [ERROR] Passphrase required in non-interactive environment." -ForegroundColor Red
            return
        }
        $secPass = Read-Host -Prompt "  Enter Master Passphrase to encrypt vault" -AsSecureString
        $pass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
        )
        if (-not $pass -or $pass.Length -lt 6) {
            Write-Host "  [ERROR] Passphrase must be at least 6 characters." -ForegroundColor Red
            return
        }
        $secPass2 = Read-Host -Prompt "  Confirm Master Passphrase" -AsSecureString
        $pass2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass2)
        )
        if ($pass -ne $pass2) {
            Write-Host "  [ERROR] Passphrase confirmation does not match." -ForegroundColor Red
            return
        }
    }

    # 3. Gather all accounts and decrypt tokens in memory
    Write-Host "  [1/4] Collecting local accounts..." -ForegroundColor Cyan
    $accounts = @()
    $savedFiles = Get-ChildItem $ACCOUNTS_DIR -Filter "*.dat" -EA SilentlyContinue | Where-Object { $_.Name -notmatch "_mcp" }
    
    foreach ($sf in $savedFiles) {
        try {
            $data = Get-Content $sf.FullName -Raw | ConvertFrom-Json
            $plainBlob = Unprotect-String $data.credential
            $mcpBackup = Join-Path $ACCOUNTS_DIR "$($data.name)_mcp.dat"
            $plainMcp = $null
            if (Test-Path $mcpBackup) {
                try { $plainMcp = Unprotect-String (Get-Content $mcpBackup -Raw) } catch {}
            }

            $accounts += @{
                name = $data.name
                user = $data.user
                email = $data.email
                credential = $plainBlob
                mcp = $plainMcp
                saved_at = $data.saved_at
            }
        } catch {
            Write-Host "      [WARN] Failed to read account $($sf.Name): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($accounts.Count -eq 0) {
        Write-Host "  [ERROR] No saved accounts found to backup." -ForegroundColor Red
        return
    }

    Write-Host "        Found $($accounts.Count) account(s) to backup." -ForegroundColor Green

    # 4. Build payload and encrypt with AES-256
    Write-Host "  [2/4] Encrypting payload with AES-256 PBKDF2 (100,000 iterations)..." -ForegroundColor Cyan
    $payloadObj = @{
        version = "1.0"
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        machine_export = $env:COMPUTERNAME
        accounts = $accounts
    }
    $plainJson = $payloadObj | ConvertTo-Json -Depth 10
    $encryptedVault = [AgyVaultCrypto]::Encrypt($plainJson, $pass)

    # 5. Safe manifest
    $manifestObj = @{
        version = "1.0"
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        total_accounts = $accounts.Count
        account_names = @($accounts | ForEach-Object { $_.name })
        cipher = "AES-256-CBC-PBKDF2-HMAC-SHA256"
    }
    $manifestJson = $manifestObj | ConvertTo-Json -Depth 5

    # 6. Push to private GitHub repo via gh CLI
    Write-Host "  [3/4] Connecting to GitHub private repository '$Repo'..." -ForegroundColor Cyan

    $repoCheck = & gh repo view $Repo --json isPrivate -q .isPrivate 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "        Creating private repository '$Repo' via gh CLI..." -ForegroundColor Yellow
        & gh repo create $Repo --private --description "AGY RIG Encrypted Credential Vault" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [ERROR] Failed to create private repository on GitHub." -ForegroundColor Red
            return
        }
        Write-Host "        [OK] Private repository '$Repo' created." -ForegroundColor Green
    }

    Write-Host "  [4/4] Uploading encrypted vault to GitHub..." -ForegroundColor Cyan
    $tempDir = Join-Path $env:TEMP ("agyrig-vault-" + [Guid]::NewGuid().ToString().Substring(0,8))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        Set-Location $tempDir
        & git init -b main 2>&1 | Out-Null
        & git config user.name "AGY RIG Vault"
        & git config user.email "agy-rig@local"

        [IO.File]::WriteAllText((Join-Path $tempDir "vault.enc"), $encryptedVault, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $tempDir "manifest.json"), $manifestJson, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $tempDir "README.md"), "# AGY RIG Encrypted Credential Vault`n`nThis repository contains client-side encrypted credentials managed by AGY RIG.`nEncrypted with AES-256 + PBKDF2 (100,000 iterations) + HMAC-SHA256.`n`nDO NOT SHARE YOUR MASTER PASSPHRASE.", [Text.Encoding]::UTF8)

        & git add -A
        & git commit -m "chore(vault): update encrypted vault backup [$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]" 2>&1 | Out-Null
        
        $remoteUrl = (& gh repo view $Repo --json url -q .url) + ".git"
        & git remote add origin $remoteUrl
        & git push -f origin main 2>&1 | Out-Null

        Write-Host ""
        Write-Host "  ================================================================" -ForegroundColor Green
        Write-Host "  [OK] ENCRYPTED VAULT BACKED UP TO GITHUB SUCCESSFULLY" -ForegroundColor Green
        Write-Host "  ================================================================" -ForegroundColor Green
        Write-Host "  Repository : $remoteUrl (PRIVATE)" -ForegroundColor White
        Write-Host "  Total      : $($accounts.Count) account(s) saved" -ForegroundColor Gray
        Write-Host "  Security   : AES-256-CBC + HMAC-SHA256 (client-side encrypted)" -ForegroundColor Gray
        Write-Host "  Note       : Keep your Master Passphrase safe to restore on other devices." -ForegroundColor Yellow
        Write-Host ""
    } finally {
        Set-Location $BASE_DIR
        Remove-Item $tempDir -Recurse -Force -EA SilentlyContinue
    }
}

function Import-VaultFromGitHub {
    param(
        [string]$Repo = "agy-rig-vault",
        [string]$Passphrase = ""
    )

    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor DarkYellow
    Write-Host "  >> AGY RIG // RESTORE CREDENTIALS FROM PRIVATE GITHUB VAULT" -ForegroundColor Yellow
    Write-Host "  ================================================================" -ForegroundColor DarkYellow
    Write-Host ""

    # 1. Check gh CLI
    $ghStatus = & gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [ERROR] GitHub CLI ('gh') is not authenticated. Run 'gh auth login' first." -ForegroundColor Red
        return
    }

    # 2. Pull vault.enc content
    Write-Host "  [1/3] Downloading vault.enc from private repository '$Repo'..." -ForegroundColor Cyan
    $encContent = $null
    $tempDir = Join-Path $env:TEMP ("agyrig-restore-" + [Guid]::NewGuid().ToString().Substring(0,8))
    & gh repo clone $Repo $tempDir -- --depth 1 2>&1 | Out-Null
    $encFile = Join-Path $tempDir "vault.enc"
    if (Test-Path $encFile) {
        $encContent = Get-Content $encFile -Raw
    }
    Remove-Item $tempDir -Recurse -Force -EA SilentlyContinue

    if (-not $encContent) {
        Write-Host "  [ERROR] Failed to download vault.enc from repository '$Repo'." -ForegroundColor Red
        Write-Host "          Ensure repository exists and your GitHub token has access." -ForegroundColor Yellow
        return
    }

    # 3. Prompt for master passphrase
    $pass = $Passphrase
    if (-not $pass) {
        if (-not ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)) {
            Write-Host "  [ERROR] Passphrase required in non-interactive environment." -ForegroundColor Red
            return
        }
        $secPass = Read-Host -Prompt "  Enter Master Passphrase to decrypt vault" -AsSecureString
        $pass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
        )
    }

    # 4. Decrypt with AES-256
    Write-Host "  [2/3] Decrypting and verifying HMAC integrity..." -ForegroundColor Cyan
    $plainJson = $null
    try {
        $plainJson = [AgyVaultCrypto]::Decrypt($encContent.Trim(), $pass)
    } catch {
        Write-Host "  [ERROR] Decryption failed: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    $payload = $null
    try {
        $payload = $plainJson | ConvertFrom-Json
    } catch {
        Write-Host "  [ERROR] Invalid JSON payload in vault." -ForegroundColor Red
        return
    }

    # 5. Import and re-encrypt with local DPAPI
    Write-Host "  [3/3] Saving accounts to local storage with DPAPI protection..." -ForegroundColor Cyan
    $importedCount = 0
    foreach ($acc in $payload.accounts) {
        try {
            $cleanName = $acc.name.ToLower().Trim()
            $encCred = Protect-String $acc.credential
            $accData = @{
                name = $cleanName
                user = if ($acc.user) { $acc.user } else { "antigravity" }
                email = $acc.email
                credential = $encCred
                saved_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            } | ConvertTo-Json -Depth 5

            $accFile = Join-Path $ACCOUNTS_DIR "$cleanName.dat"
            Set-Content -Path $accFile -Value $accData -Encoding UTF8

            # Restore MCP tokens if present
            if ($acc.mcp) {
                $mcpEnc = Protect-String $acc.mcp
                Set-Content -Path (Join-Path $ACCOUNTS_DIR "$($cleanName)_mcp.dat") -Value $mcpEnc -Encoding UTF8
            }

            Write-Host "        [+] Imported: $($cleanName.ToUpper()) [$($acc.email)]" -ForegroundColor Green
            $importedCount++
        } catch {
            Write-Host "        [-] Failed to import $($acc.name): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Green
    Write-Host "  [OK] Successfully imported $importedCount account(s) from GitHub Vault." -ForegroundColor Green
    Write-Host "  ================================================================" -ForegroundColor Green
    Write-Host "  Use 'agy-rig list' to view accounts, or 'agy-rig use <name>' to switch." -ForegroundColor DarkGray
    Write-Host ""
}

function Handle-ParallelCommand {
    param([string]$SubCommand, [string]$Name)
    switch ($SubCommand.ToLower()) {
        "switch" { Switch-ParallelSession -Name $Name }
        "focus"  { Switch-ParallelSession -Name $Name }
        "launch" { Launch-ParallelAccount -Name $Name }
        "close"  { Close-ParallelSession -Name $Name }
        "kill"   { Close-ParallelSession -Name $Name }
        "list"   { List-ParallelSessions }
        "ls"     { List-ParallelSessions }
        default  {
            if ($SubCommand) {
                Switch-ParallelSession -Name $SubCommand
            } else {
                List-ParallelSessions
            }
        }
    }
}

function Handle-VaultCommand {
    param([string]$SubCommand, [string]$Param)
    switch ($SubCommand.ToLower()) {
        "backup"  { Backup-VaultToGitHub -Repo (if ($Param) { $Param } else { "agy-rig-vault" }) }
        "export"  { Backup-VaultToGitHub -Repo (if ($Param) { $Param } else { "agy-rig-vault" }) }
        "import"  { Import-VaultFromGitHub -Repo (if ($Param) { $Param } else { "agy-rig-vault" }) }
        "restore" { Import-VaultFromGitHub -Repo (if ($Param) { $Param } else { "agy-rig-vault" }) }
        default   {
            Write-Host "  Vault Usage:" -ForegroundColor Yellow
            Write-Host "    agy-rig vault backup [repo]   # Encrypt and push credentials to private repo" -ForegroundColor Gray
            Write-Host "    agy-rig vault import [repo]   # Download and restore credentials from private repo" -ForegroundColor Gray
        }
    }
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
        Write-Host "  Active Profile : $activeAccount" -ForegroundColor White
    }
    if ($activeEmail) {
        Write-Host "  Email          : $activeEmail" -ForegroundColor Cyan
    }

    Write-Host "  Fetching live data from agy CLI..." -ForegroundColor DarkGray
    $q = GetLiveAgyQuota

    if (-not $q.success) {
        Write-Host "  [ERROR] Unable to retrieve quota from agy CLI." -ForegroundColor Red
        Write-Host "          Ensure Antigravity CLI is authenticated." -ForegroundColor Yellow
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
    Write-Host "  >> Saved Accounts" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray

    $blob = [AgySwitchCredManager]::ReadCredential($CRED_TARGET)
    $curEmail = if ($blob) { Extract-EmailFromToken $blob } else { $null }

    $files = Get-ChildItem $ACCOUNTS_DIR -Filter "*.dat" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch "_mcp\.dat$" }

    if (-not $files -or $files.Count -eq 0) {
        Write-Host "  No saved accounts found." -ForegroundColor Yellow
        Write-Host "  Run 'agy-rig save <name>' to save current active credentials." -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    $index = 1
    foreach ($file in $files) {
        $email = Repair-AccountEmail $file.FullName
        $data = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $isActive = ($curEmail -and $data.email -eq $curEmail)
        $marker = if ($isActive) { "(*)" } else { "   " }
        $suffix = if ($isActive) { " [ACTIVE]" } else { "" }
        $color = if ($isActive) { "Green" } else { "White" }

        Write-Host "  $marker $index. $($data.name)$suffix" -ForegroundColor $color
        Write-Host "       Email    : $($data.email)" -ForegroundColor Cyan
        Write-Host "       Saved    : $($data.saved_at)" -ForegroundColor DarkGray

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
        Write-Host "  [ERROR] Specify the account name to delete." -ForegroundColor Red
        return
    }

    $cleanName = $Name.ToLower().Trim()
    $accountFile = Join-Path $ACCOUNTS_DIR "$cleanName.dat"

    if (-not (Test-Path $accountFile)) {
        Write-Host "  [ERROR] Account '$cleanName' not found." -ForegroundColor Red
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

    Write-Host "  [OK] Account '$cleanName' deleted successfully." -ForegroundColor Green
}

function Show-Current {
    $blob = [AgySwitchCredManager]::ReadCredential($CRED_TARGET)
    $activeName = ""
    if (Test-Path $ACTIVE_FILE) {
        $activeName = (Get-Content $ACTIVE_FILE -Raw).Trim()
    }

    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  >> Active Account Status" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor DarkGray

    if ($blob) {
        $email = Extract-EmailFromToken $blob
        Write-Host "  Saved Name     : $(if ($activeName) { $activeName } else { '(not yet saved in agy-rig)' })" -ForegroundColor White
        Write-Host "  Account Email  : $(if ($email) { $email } else { '(not detected)' })" -ForegroundColor White
        Write-Host "  Credential     : Stored in Windows Credential Manager ($CRED_TARGET)" -ForegroundColor Green

        $quotaFile = Join-Path $CREDITS_DIR "$($activeName.ToLower())_quota.json"
        if ($activeName -and (Test-Path $quotaFile)) {
            try {
                $q = Get-Content $quotaFile -Raw | ConvertFrom-Json
                Write-Host ""
                Write-Host "  Cached Quota Telemetry ($($q.timestamp)):" -ForegroundColor DarkGray
                $g5 = [int]([math]::Round($q.gemini_5h * 100))
                $gw = [int]([math]::Round($q.gemini_wk * 100))
                $c5 = [int]([math]::Round($q.claude_5h * 100))
                $cw = [int]([math]::Round($q.claude_wk * 100))
                Write-Host "    Gemini Limit : 5H: $g5% | Week: $gw%" -ForegroundColor Cyan
                Write-Host "    Claude Limit : 5H: $c5% | Week: $cw%" -ForegroundColor Yellow
                Write-Host "    Credits      : $($q.credits) CR" -ForegroundColor Green
                Write-Host ""
                Write-Host "  (Run 'agy-rig quota' to refresh live telemetry from CLI)" -ForegroundColor DarkGray
            } catch {
                Show-Quota
            }
        } else {
            Show-Quota
        }
    } else {
        Write-Host "  [WARN] No active credential found in Credential Manager." -ForegroundColor Yellow
        Write-Host "         Please log in to Antigravity first." -ForegroundColor Yellow
    }
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

    $code = $null
    $error = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(180)

    try {
        while ([DateTime]::UtcNow -lt $deadline -and -not $code -and -not $error) {
            $asyncResult = $http.BeginGetContext($null, $null)
            $waitHandle = $asyncResult.AsyncWaitHandle
            $remMs = [math]::Max(100, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $success = $waitHandle.WaitOne([TimeSpan]::FromMilliseconds($remMs))
            try { $waitHandle.Close() } catch {}

            if (-not $success) { break }

            $context = $http.EndGetContext($asyncResult)
            $request = $context.Request
            $response = $context.Response

            if ($request.Url.AbsolutePath -eq "/favicon.ico") {
                $response.StatusCode = 204
                $response.Close()
                continue
            }

            $code = $request.QueryString["code"]
            $error = $request.QueryString["error"]

            $html = "<html><body style='font-family:Consolas,monospace;text-align:center;padding:50px;background:#161408;color:#FFE633;'><h2>LOGIN SUCCESSFUL!</h2><p style='color:#B3A220;'>Your Google account has been connected to AGY RIG.<br>You may close this tab and return to the terminal.</p></body></html>"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            $response.OutputStream.Close()
        }
    } finally {
        try { $http.Stop(); $http.Close() } catch {}
    }

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
    Write-Host "  >> Add / Login New Account (Direct OAuth PKCE)" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "  >> Opening browser for Google login..." -ForegroundColor Yellow
    Write-Host "     (Primary Antigravity remains running uninterrupted)" -ForegroundColor Green
    Write-Host "     Please complete sign-in in your browser..." -ForegroundColor DarkGray

    $res = StartBrowserGoogleLogin

    if ($res.success) {
        Write-Host ""
        Write-Host "  [OK] Sign-in detected successfully." -ForegroundColor Green
        Write-Host "       Email: $($res.email)" -ForegroundColor Cyan

        $suggestedName = if ($res.email -and $res.email -match "^([^@]+)") { $matches[1] } else { "account" }
        Write-Host ""
        $newName = ""
        if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
            $newName = Read-Host "  Enter name for this account (press Enter for '$suggestedName')"
        }
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
        Write-Host "  [OK] Account '$cleanName' ($($res.email)) saved successfully." -ForegroundColor Green
        Write-Host "       To switch to this account, run: agy-rig use $cleanName" -ForegroundColor DarkGray
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "  [WARN] Sign-in cancelled or failed: $($res.error)" -ForegroundColor Yellow
        Write-Host ""
    }
}

function Open-Gui {
    $guiScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "AgyRig-GUI.ps1"
    if (-not (Test-Path $guiScript)) {
        $guiScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "AgySwitch-GUI.ps1"
    }
    if (Test-Path $guiScript) {
        Start-Process powershell -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-STA","-WindowStyle","Hidden","-File","`"$guiScript`""
        Write-Host "  [OK] HUD GUI launched." -ForegroundColor Green
    } else {
        Write-Host "  [ERROR] GUI script not found: $guiScript" -ForegroundColor Red
    }
}

# ============================================================================
# Router
# ============================================================================

switch ($Command.ToLower()) {
    "scan"     { Scan-AntigravityCredentials }
    "save"     { Save-Account -Name $TargetName }
    "login"    { Login-NewAccount }
    "add"      { Login-NewAccount }
    "use"      { Use-Account -Name $TargetName }
    "switch"   { Use-Account -Name $TargetName }
    "paralel"  { Handle-ParallelCommand -SubCommand $TargetName -Name $ExtraParam }
    "parallel" { Handle-ParallelCommand -SubCommand $TargetName -Name $ExtraParam }
    "p"        { Handle-ParallelCommand -SubCommand $TargetName -Name $ExtraParam }
    "launch"   { Launch-ParallelAccount -Name $TargetName }
    "profiles" { List-ParallelSessions }
    "vault"    { Handle-VaultCommand -SubCommand $TargetName -Param $ExtraParam }
    "backup"   { Backup-VaultToGitHub -Repo (if ($TargetName) { $TargetName } else { "agy-rig-vault" }) }
    "import"   { Import-VaultFromGitHub -Repo (if ($TargetName) { $TargetName } else { "agy-rig-vault" }) }
    "restore"  { Import-VaultFromGitHub -Repo (if ($TargetName) { $TargetName } else { "agy-rig-vault" }) }
    "list"     { List-Accounts }
    "delete"   { Delete-Account -Name $TargetName }
    "current"  { Show-Current }
    "quota"    { Show-Quota }
    "credits"  { Show-Quota }
    "gui"      { Open-Gui }
    "help"     { Show-Help }
    default    { Show-Help }
}
