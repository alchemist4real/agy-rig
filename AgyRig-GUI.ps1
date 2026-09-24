# ============================================================================
# AGY RIG — Compact HUD Dock for Google Antigravity (AGY)
# Glass Edition: Transparent Acrylic, Adaptive Colors, Responsive Controls
# ============================================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Drawing

# ============================================================================
# BACKEND: Credential Manager + DPAPI + Native AGY Quota Fetcher
# ============================================================================

if (-not ([System.Management.Automation.PSTypeName]'AgyCredMgr').Type) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class AgyCredMgr {
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool CredRead(string t, int ty, int f, out IntPtr c);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool CredWrite(ref CRED c, int f);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool CredDelete(string t, int ty, int f);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern void CredFree(IntPtr c);

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CRED {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int BlobSize; public IntPtr Blob; public int Persist;
        public int AttrCount; public IntPtr Attrs; public string Alias; public string UserName;
    }

    public static string Read(string target) {
        IntPtr p; if (!CredRead(target, 1, 0, out p)) return null;
        CRED c = (CRED)Marshal.PtrToStructure(p, typeof(CRED));
        string b = "";
        if (c.BlobSize > 0 && c.Blob != IntPtr.Zero) {
            byte[] d = new byte[c.BlobSize];
            Marshal.Copy(c.Blob, d, 0, c.BlobSize);
            b = Encoding.UTF8.GetString(d);
        }
        CredFree(p);
        return b;
    }

    public static string ReadUser(string target) {
        IntPtr p; if (!CredRead(target, 1, 0, out p)) return null;
        CRED c = (CRED)Marshal.PtrToStructure(p, typeof(CRED));
        string u = c.UserName;
        CredFree(p);
        return u;
    }

    public static bool Write(string target, string user, string blob) {
        if (string.IsNullOrEmpty(blob)) return false;
        byte[] b = Encoding.UTF8.GetBytes(blob);
        CRED c = new CRED();
        c.Type = 1; c.TargetName = target; c.UserName = user; c.BlobSize = b.Length;
        c.Blob = Marshal.AllocHGlobal(b.Length);
        Marshal.Copy(b, 0, c.Blob, b.Length);
        c.Persist = 2;
        bool r = CredWrite(ref c, 0);
        Marshal.FreeHGlobal(c.Blob);
        return r;
    }

    public static bool Delete(string target) {
        return CredDelete(target, 1, 0);
    }
}

public class Win32WindowHelper {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
"@ -EA SilentlyContinue
}

# Enable Windows acrylic blur behind WPF window
if (-not ([System.Management.Automation.PSTypeName]'AcrylicHelper').Type) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class AcrylicHelper {
    [DllImport("user32.dll")]
    static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttribData data);

    [StructLayout(LayoutKind.Sequential)]
    struct WindowCompositionAttribData {
        public int Attribute;
        public IntPtr Data;
        public int SizeOfData;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct AccentPolicy {
        public int AccentState;
        public int AccentFlags;
        public int GradientColor;
        public int AnimationId;
    }

    public static void EnableBlur(IntPtr hwnd, int tintColor) {
        var accent = new AccentPolicy {
            AccentState = 3,   // ACCENT_ENABLE_BLURBEHIND
            AccentFlags = 2,
            GradientColor = tintColor
        };
        int accentSize = Marshal.SizeOf(accent);
        IntPtr accentPtr = Marshal.AllocHGlobal(accentSize);
        Marshal.StructureToPtr(accent, accentPtr, false);
        var data = new WindowCompositionAttribData {
            Attribute = 19, // WCA_ACCENT_POLICY
            Data = accentPtr,
            SizeOfData = accentSize
        };
        SetWindowCompositionAttribute(hwnd, ref data);
        Marshal.FreeHGlobal(accentPtr);
    }
}
"@ -EA SilentlyContinue
}

$CT = "gemini:antigravity"
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PWD.Path }
$localAppDir = Join-Path $env:LOCALAPPDATA "AgyRig"
if (Test-Path (Join-Path $localAppDir "accounts")) {
    $BD = $localAppDir
} elseif ($scriptDir -and (Test-Path (Join-Path $scriptDir "accounts"))) {
    $BD = $scriptDir
} else {
    $BD = $localAppDir
}
$AD = Join-Path $BD "accounts"
$CD = Join-Path $BD "credits"
$userProf = [Environment]::GetFolderPath("UserProfile")
$PD = Join-Path $userProf ".gemini\antigravity\profiles"
$AF = Join-Path $BD "active_account.txt"
$ICON_PATH = Join-Path $BD "agy-rig.ico"

foreach ($d in @($AD, $CD, $PD)) {
    if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function script:ReadActiveCredBlob {
    $blob = [AgyCredMgr]::Read($CT)
    if (-not $blob) {
        $blob = [AgyCredMgr]::Read("antigravity_google_oauth_credential")
    }
    return $blob
}

function script:ReadActiveCredUser {
    $u = [AgyCredMgr]::ReadUser($CT)
    if (-not $u) {
        $u = [AgyCredMgr]::ReadUser("antigravity_google_oauth_credential")
    }
    if (-not $u) { $u = "antigravity" }
    return $u
}

function script:Find-AntigravityExe {
    $procs = Get-Process -Name "Antigravity*" -ErrorAction SilentlyContinue
    if ($procs) {
        foreach ($p in $procs) {
            try {
                if ($p.Path -and (Test-Path $p.Path)) {
                    return $p.Path
                }
            } catch {}
        }
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Antigravity\Antigravity.exe"),
        (Join-Path $env:LOCALAPPDATA "Antigravity\Antigravity.exe"),
        (Join-Path $env:ProgramFiles "Antigravity\Antigravity.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Antigravity\Antigravity.exe")
    )
    foreach ($cand in $candidates) {
        if ($cand -and (Test-Path $cand)) { return $cand }
    }
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $shell = New-Object -ComObject WScript.Shell
        $lnkCandidates = Get-ChildItem $desktop -Filter "*Antigravity*.lnk" -ErrorAction SilentlyContinue
        foreach ($lnk in $lnkCandidates) {
            $sc = $shell.CreateShortcut($lnk.FullName)
            if ($sc.TargetPath -and (Test-Path $sc.TargetPath) -and ($sc.TargetPath -match "Antigravity\.exe$")) {
                return $sc.TargetPath
            }
        }
    } catch {}
    return $null
}

function script:Find-AgyBin {
    $cmd = Get-Command "agy.cmd" -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command "agy" -ErrorAction SilentlyContinue }
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Antigravity\bin\agy.cmd"),
        (Join-Path $env:LOCALAPPDATA "Antigravity\bin\agy.cmd"),
        (Join-Path $env:USERPROFILE "AppData\Local\Programs\Antigravity\bin\agy.cmd"),
        (Join-Path $env:USERPROFILE ".gemini\antigravity\bin\agy.cmd"),
        (Join-Path $env:ProgramFiles "Antigravity\bin\agy.cmd")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return "agy"
}

function script:Get-ParallelProcesses {
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

function script:Enc([string]$s) {
    [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($s), $null, 'CurrentUser'))
}
function script:Dec([string]$s) {
    [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($s), $null, 'CurrentUser'))
}

function script:GetEmail([string]$j) {
    if (-not $j) { return $null }
    try {
        $o = $j | ConvertFrom-Json -EA SilentlyContinue
        if ($o.email) { return $o.email }

        $idTok = if ($o.id_token) { $o.id_token } elseif ($o.token -and $o.token.id_token) { $o.token.id_token } else { $null }
        if ($idTok) {
            $p = $idTok -split '\.'
            if ($p.Count -ge 2) {
                $pay = $p[1]; $m = $pay.Length % 4
                if ($m) { $pay += '=' * (4 - $m) }
                $pay = $pay.Replace('-','+').Replace('_','/')
                $c = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pay)) | ConvertFrom-Json -EA SilentlyContinue
                if ($c.email) { return $c.email }
            }
        }

        $accTok = if ($o.token -and $o.token.access_token) { $o.token.access_token } elseif ($o.access_token) { $o.access_token } else { $null }
        if ($accTok) {
            try {
                $info = Invoke-RestMethod -Uri "https://oauth2.googleapis.com/tokeninfo?access_token=$accTok" -TimeoutSec 3 -EA SilentlyContinue
                if ($info -and $info.email) { return $info.email }
            } catch {}
        }
    } catch {}
    return $null
}

function script:RepairAccountEmail([string]$path) {
    try {
        $data = Get-Content $path -Raw | ConvertFrom-Json
        if (-not $data.email -or $data.email -like "*(not detected)*") {
            $blob = Dec $data.credential
            $realEmail = GetEmail $blob
            if ($realEmail) {
                $data.email = $realEmail
                $data | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
                return $realEmail
            }
        }
        return $data.email
    } catch { return $null }
}

function script:LoadAccs {
    $r = @()
    Get-ChildItem $AD -Filter "*.dat" -EA SilentlyContinue | Where-Object { $_.Name -notmatch "_mcp" } | ForEach-Object {
        try {
            RepairAccountEmail $_.FullName | Out-Null
            $r += (Get-Content $_.FullName -Raw | ConvertFrom-Json)
        } catch {}
    }
    return $r
}

function script:SaveAccountQuota([string]$name, $quotaObj) {
    if (-not $name -or -not $quotaObj) { return }
    $qp = Join-Path $CD "$($name.ToLower())_quota.json"
    $json = $quotaObj | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($qp, $json, [Text.Encoding]::UTF8)
}

function script:GetAccountQuota([string]$name) {
    $qp = Join-Path $CD "$($name.ToLower())_quota.json"
    if (Test-Path $qp) {
        try { return (Get-Content $qp -Raw | ConvertFrom-Json) } catch {}
    }
    return $null
}

function script:FormatCountdown([string]$isoStr) {
    if (-not $isoStr) { return "--" }
    try {
        $target = [DateTimeOffset]::Parse($isoStr).LocalDateTime
        $diff = $target - (Get-Date)
        if ($diff.TotalSeconds -le 0) { return "Ready" }
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

function script:StartBrowserGoogleLogin {
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
    $authError = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(180)

    try {
        while ([DateTime]::UtcNow -lt $deadline -and -not $code -and -not $authError) {
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
            $authError = $request.QueryString["error"]

            $html = "<html><body style='font-family:Consolas,monospace;text-align:center;padding:50px;background:#0D0D0D;color:#4FC3F7;'><h2>LOGIN SUCCESSFUL</h2><p style='color:#90A4AE;'>Google account connected to AGY RIG.<br>You can close this tab.</p></body></html>"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            $response.OutputStream.Close()
        }
    } finally {
        try { $http.Stop(); $http.Close() } catch {}
    }

    if ($authError -or -not $code) {
        return @{ success = $false; error = if ($authError) { $authError } else { "NO_CODE" } }
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
        $email = GetEmail $credJson

        return @{
            success = $true
            email = $email
            credential = $credJson
        }
    } catch {
        return @{ success = $false; error = "EXCHANGE_FAILED: $_" }
    }
}

function script:SaveCur([string]$n) {
    $b = [AgyCredMgr]::Read($CT)
    $u = [AgyCredMgr]::ReadUser($CT)
    if (!$b) { return "NO_CRED" }
    $em = GetEmail $b
    if (!$em) { $em = "(not detected)" }
    $d = @{
        name = $n.ToLower()
        user = $u
        email = $em
        credential = (Enc $b)
        saved_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $AD "$($n.ToLower()).dat"), $d, [Text.Encoding]::UTF8)

    $mp = Join-Path $env:USERPROFILE ".gemini\antigravity\mcp_oauth_tokens.json"
    if (Test-Path $mp) {
        [IO.File]::WriteAllText((Join-Path $AD "$($n.ToLower())_mcp.dat"), (Enc(Get-Content $mp -Raw)), [Text.Encoding]::UTF8)
    }
    [IO.File]::WriteAllText($AF, $n.ToLower(), [Text.Encoding]::UTF8)

    return "OK:$em"
}

function script:SwitchTo([string]$n) {
    $ap = Join-Path $AD "$($n.ToLower()).dat"
    if (!(Test-Path $ap)) { return "NOT_FOUND" }
    $ac = Get-Content $ap -Raw | ConvertFrom-Json
    try { $b = Dec $ac.credential } catch { return "FAIL" }
    $u = if ($ac.user) { $ac.user } else { "antigravity" }
    if (!([AgyCredMgr]::Write($CT, $u, $b))) { return "FAIL" }

    $mb = Join-Path $AD "$($n.ToLower())_mcp.dat"
    $mt = Join-Path $env:USERPROFILE ".gemini\antigravity\mcp_oauth_tokens.json"
    if (Test-Path $mb) {
        try { [IO.File]::WriteAllText($mt, (Dec(Get-Content $mb -Raw)), [Text.Encoding]::UTF8) } catch {}
    }
    [IO.File]::WriteAllText($AF, $n.ToLower(), [Text.Encoding]::UTF8)

    # Restart ONLY primary Antigravity (protect running parallel instances)
    $activeProcs = Get-ParallelProcesses
    $mainProc = $activeProcs | Where-Object { -not $_.IsParallel }
    if ($mainProc) {
        Stop-Process -Id $mainProc.ProcessId -Force -EA SilentlyContinue
        Start-Sleep -Seconds 2
    }
    $exe = Find-AntigravityExe
    if ($exe -and (Test-Path $exe)) {
        Start-Process $exe
    }
    return "OK"
}

function script:LaunchParallel([string]$n) {
    $cleanName = $n.ToLower().Trim()
    $ap = Join-Path $AD "$cleanName.dat"
    if (!(Test-Path $ap)) { return "NOT_FOUND" }
    $ac = Get-Content $ap -Raw | ConvertFrom-Json
    try { $targetBlob = Dec $ac.credential } catch { return "FAIL" }
    $targetUser = if ($ac.user) { $ac.user } else { "antigravity" }

    $profDir = Join-Path $env:USERPROFILE ".gemini\antigravity\profiles\$cleanName"
    $userDir = Join-Path $profDir "userdata"
    if (!(Test-Path $userDir)) {
        New-Item -ItemType Directory -Path $userDir -Force | Out-Null
        $initStorage = @{ "ide-install-wizard-shown" = "true" } | ConvertTo-Json
        [IO.File]::WriteAllText((Join-Path $userDir "app_storage.json"), $initStorage, [Text.Encoding]::UTF8)
    }

    $exe = Find-AntigravityExe
    if (!$exe) { return "NO_EXE" }

    $curBlob = ReadActiveCredBlob
    $curUser = ReadActiveCredUser

    [AgyCredMgr]::Write($CT, $targetUser, $targetBlob) | Out-Null

    Start-Process $exe -ArgumentList "--user-data-dir=`"$userDir`""

    $mb = Join-Path $AD "$($cleanName)_mcp.dat"
    $mt = Join-Path $env:USERPROFILE ".gemini\antigravity\mcp_oauth_tokens.json"
    if (Test-Path $mb) {
        try { [IO.File]::WriteAllText($mt, (Dec(Get-Content $mb -Raw)), [Text.Encoding]::UTF8) } catch {}
    }

    # Restore original credential after 4 seconds via dispatcher timer
    if ($curBlob -and ($curBlob -ne $targetBlob)) {
        $restoreTimer = New-Object Windows.Threading.DispatcherTimer
        $restoreTimer.Interval = [TimeSpan]::FromSeconds(4)
        $capturedCurBlob = $curBlob
        $capturedCurUser = $curUser
        $capturedCT = $CT
        $capturedTimer = $restoreTimer
        $restoreTimer.Add_Tick({
            $capturedTimer.Stop()
            [AgyCredMgr]::Write($capturedCT, $capturedCurUser, $capturedCurBlob) | Out-Null
        }.GetNewClosure())
        $restoreTimer.Start()
    }

    # Create desktop shortcut for this parallel profile
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $lnkPath = Join-Path $desktop "Antigravity ($($cleanName.ToUpper())).lnk"
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnkPath)
        $sc.TargetPath = $exe
        $sc.Arguments = "--user-data-dir=`"$userDir`""
        $sc.IconLocation = "$ICON_PATH,0"
        $sc.Description = "Antigravity Profile: $($cleanName.ToUpper())"
        $sc.Save()
    } catch {}

    return "OK"
}

function script:FocusOrLaunchParallel([string]$n) {
    $cleanName = $n.ToLower().Trim()
    if ($cleanName -eq "utama" -or $cleanName -eq "main" -or $cleanName -eq "default") {
        $mainProc = Get-ParallelProcesses | Where-Object { -not $_.IsParallel }
        if ($mainProc -and $mainProc.ProcessObj -and $mainProc.ProcessObj.MainWindowHandle -ne [IntPtr]::Zero) {
            [Win32WindowHelper]::ShowWindowAsync($mainProc.ProcessObj.MainWindowHandle, 9) | Out-Null
            [Win32WindowHelper]::SetForegroundWindow($mainProc.ProcessObj.MainWindowHandle) | Out-Null
            return "FOCUSED_MAIN"
        }
    }

    $activeProcs = Get-ParallelProcesses
    $running = $activeProcs | Where-Object { $_.IsParallel -and ($_.ProfileName -eq $cleanName) }
    if ($running -and $running.ProcessObj -and $running.ProcessObj.MainWindowHandle -ne [IntPtr]::Zero) {
        [Win32WindowHelper]::ShowWindowAsync($running.ProcessObj.MainWindowHandle, 9) | Out-Null
        [Win32WindowHelper]::SetForegroundWindow($running.ProcessObj.MainWindowHandle) | Out-Null
        return "FOCUSED"
    }

    return (LaunchParallel $cleanName)
}

function script:DelAcc([string]$n) {
    $ap = Join-Path $AD "$($n.ToLower()).dat"
    if (Test-Path $ap) { Remove-Item $ap -Force }
    $mp = Join-Path $AD "$($n.ToLower())_mcp.dat"
    if (Test-Path $mp) { Remove-Item $mp -Force }
    $qp = Join-Path $CD "$($n.ToLower())_quota.json"
    if (Test-Path $qp) { Remove-Item $qp -Force }
    if ((Test-Path $AF) -and ((Get-Content $AF -Raw).Trim() -eq $n.ToLower())) { Remove-Item $AF -Force }
}

# ============================================================================
# GUI — GLASS TRANSPARENT DOCK (Frosted Acrylic + Adaptive Colors)
# ============================================================================

$xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  Title="AGY RIG" Width="390" Height="230"
  WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
  Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="True" Topmost="False"
  TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType"
  RenderOptions.BitmapScalingMode="HighQuality" RenderOptions.ClearTypeHint="Enabled"
  SnapsToDevicePixels="True" UseLayoutRounding="True">

  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bdr" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter Property="Opacity" Value="0.65"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ToggleButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="tbdr" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Opacity" Value="0.85"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <!-- Outer Glass Border -->
  <Border CornerRadius="14" Background="#C8181818" BorderBrush="#60FFFFFF" BorderThickness="1"
          Margin="8" Padding="14,10" SnapsToDevicePixels="True" UseLayoutRounding="True">
    <Border.Effect>
      <DropShadowEffect Color="#000000" BlurRadius="16" ShadowDepth="3" Opacity="0.50" Direction="315"/>
    </Border.Effect>

    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="22"/>   <!-- 0: Header -->
        <RowDefinition Height="5"/>    <!-- 1: Spacer -->
        <RowDefinition Height="28"/>   <!-- 2: Selector + Buttons -->
        <RowDefinition Height="4"/>    <!-- 3: Spacer -->
        <RowDefinition Height="16"/>   <!-- 4: Email + Credits -->
        <RowDefinition Height="6"/>    <!-- 5: Spacer -->
        <RowDefinition Height="40"/>   <!-- 6: Quota Bars (2x20) -->
        <RowDefinition Height="6"/>    <!-- 7: Spacer -->
        <RowDefinition Height="26"/>   <!-- 8: Action Buttons -->
        <RowDefinition Height="5"/>    <!-- 9: Spacer -->
        <RowDefinition Height="22"/>   <!-- 10: Status Bar -->
      </Grid.RowDefinitions>

      <!-- ROW 0: HEADER -->
      <Grid x:Name="hdrDrag" Grid.Row="0" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="16" Height="16" Background="#30FFFFFF" BorderBrush="#40FFFFFF" BorderThickness="1" CornerRadius="4" Margin="0,0,6,0">
            <TextBlock Text="&#x25B2;" Foreground="#FFE633" FontSize="8" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,1,0,0"/>
          </Border>
          <TextBlock Text="AGY RIG" Foreground="#E0E0E0" FontSize="11" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
          <Ellipse x:Name="ledStatus" Width="6" Height="6" Fill="#4FC3F7" Margin="0,0,4,0"/>
          <TextBlock x:Name="txtStatus" Text="ONLINE" Foreground="#4FC3F7" FontSize="8" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
        </StackPanel>
        <!-- Pin Toggle -->
        <ToggleButton x:Name="chkPin" Grid.Column="2" VerticalAlignment="Center" Margin="0,0,4,0" ToolTip="Toggle Always on Top (Pin)">
          <Border x:Name="pinBorder" CornerRadius="8" Background="#30FFFFFF" BorderBrush="#40FFFFFF" BorderThickness="1"
                  Width="40" Height="16" SnapsToDevicePixels="True">
            <Grid Margin="3,0">
              <Ellipse x:Name="dotPin" Width="10" Height="10" Fill="#80FFFFFF" HorizontalAlignment="Left" VerticalAlignment="Center"/>
              <TextBlock x:Name="txtPin" Text="PIN" FontSize="6.5" FontWeight="Bold" FontFamily="Consolas" Foreground="#80FFFFFF"
                         HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
          </Border>
        </ToggleButton>
        <Button x:Name="btnMin" Grid.Column="3" Width="20" Height="16" Margin="0,0,4,0" ToolTip="Minimize">
          <Border CornerRadius="4" Background="#30FFFFFF" BorderBrush="#40FFFFFF" BorderThickness="1">
            <TextBlock Text="&#x2014;" FontSize="8" Foreground="#B0B0B0" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/>
          </Border>
        </Button>
        <Button x:Name="btnClose" Grid.Column="4" Width="20" Height="16" ToolTip="Close">
          <Border CornerRadius="4" Background="#40EF5350" BorderBrush="#60EF5350" BorderThickness="1">
            <TextBlock Text="&#x2715;" FontSize="7.5" Foreground="#FFCDD2" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </Button>
      </Grid>

      <!-- ROW 2: ACCOUNT SELECTOR + SWITCH + PARALLEL -->
      <Grid Grid.Row="2">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border x:Name="accSelector" Grid.Column="0" CornerRadius="6" Background="#25FFFFFF"
                BorderBrush="#35FFFFFF" BorderThickness="1" Padding="8,4" Cursor="Hand" ToolTip="Select profile"
                Height="28" SnapsToDevicePixels="True">
          <Grid>
            <TextBlock x:Name="txtAccName" Text="(select profile)" Foreground="#E0E0E0"
                       FontFamily="Consolas" FontSize="9.5" FontWeight="Bold" VerticalAlignment="Center"
                       TextTrimming="CharacterEllipsis" Margin="0,0,16,0"/>
            <TextBlock x:Name="txtArrow" Text="&#x25BC;" Foreground="#80FFFFFF" FontSize="8.5"
                       HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
        </Border>
        <Popup x:Name="popAcc" Placement="Bottom" StaysOpen="True" AllowsTransparency="True">
          <Border Background="#E8202020" BorderBrush="#50FFFFFF" BorderThickness="1" CornerRadius="8"
                  Padding="4" MinWidth="280" MaxHeight="180" SnapsToDevicePixels="True">
            <Border.Effect>
              <DropShadowEffect BlurRadius="16" ShadowDepth="4" Opacity="0.50"/>
            </Border.Effect>
            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="pnlAccList"/>
            </ScrollViewer>
          </Border>
        </Popup>
        <Button x:Name="btnSwitch" Grid.Column="1" Margin="4,0,0,0" ToolTip="Switch primary instance to selected profile" Height="28">
          <Border CornerRadius="6" Background="#D0E65100" Padding="10,4">
            <TextBlock Text="SWITCH" Foreground="#FFFFFF" FontSize="8.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          </Border>
        </Button>
        <Button x:Name="btnParalel" Grid.Column="2" Margin="4,0,0,0" ToolTip="Launch or focus parallel instance" Height="28" MinWidth="72">
          <Border x:Name="brdParalel" CornerRadius="6" Background="#D000838F" Padding="10,4">
            <TextBlock x:Name="txtParalelBtn" Text="PARALLEL" Foreground="#FFFFFF" FontSize="8.5" FontWeight="Bold" FontFamily="Consolas" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </Button>
      </Grid>

      <!-- ROW 4: EMAIL + CREDITS -->
      <Grid Grid.Row="4">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="txtEmail" Grid.Column="0" Text="..." Foreground="#90A4AE" FontSize="8.5" FontFamily="Consolas"
                   VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,8,0"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="txtCredits" Text="0" Foreground="#4FC3F7" FontSize="9.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          <TextBlock Text=" CR" Foreground="#4FC3F7" FontSize="7.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" Opacity="0.7"/>
          <Button x:Name="btnUpgrade" Margin="4,0,0,0" ToolTip="Purchase credits / open AI Studio" VerticalAlignment="Center">
            <Border CornerRadius="4" Background="#4029B6F6" Padding="5,2">
              <TextBlock Text="&#x2197;" Foreground="#4FC3F7" FontSize="8" FontWeight="Bold" VerticalAlignment="Center"/>
            </Border>
          </Button>
        </StackPanel>
      </Grid>

      <!-- ROW 6: QUOTA BARS -->
      <Grid Grid.Row="6">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="12"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="20"/>
          <RowDefinition Height="20"/>
        </Grid.RowDefinitions>

        <!-- G-5H -->
        <Grid Grid.Row="0" Grid.Column="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="28"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="26"/>
            <ColumnDefinition Width="42"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="G-5H" Foreground="#FF7043" FontSize="7.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          <Grid Grid.Column="1" Margin="2,4" ToolTip="Gemini 5-hour quota">
            <Border Background="#30FFFFFF" CornerRadius="3"/>
            <Border x:Name="barG5h" Background="#FF7043" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
          </Grid>
          <TextBlock x:Name="txtG5hVal" Grid.Column="2" Text="--%" Foreground="#B0BEC5" FontSize="8" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
          <TextBlock x:Name="txtRstG5h" Grid.Column="3" Text="--" Foreground="#78909C" FontSize="7.5" FontWeight="SemiBold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
        </Grid>

        <!-- C-5H -->
        <Grid Grid.Row="0" Grid.Column="2">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="28"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="26"/>
            <ColumnDefinition Width="42"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="C-5H" Foreground="#4FC3F7" FontSize="7.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          <Grid Grid.Column="1" Margin="2,4" ToolTip="Claude 5-hour quota">
            <Border Background="#30FFFFFF" CornerRadius="3"/>
            <Border x:Name="barC5h" Background="#4FC3F7" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
          </Grid>
          <TextBlock x:Name="txtC5hVal" Grid.Column="2" Text="--%" Foreground="#B0BEC5" FontSize="8" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
          <TextBlock x:Name="txtRstC5h" Grid.Column="3" Text="--" Foreground="#78909C" FontSize="7.5" FontWeight="SemiBold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
        </Grid>

        <!-- G-WK -->
        <Grid Grid.Row="1" Grid.Column="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="28"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="26"/>
            <ColumnDefinition Width="42"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="G-WK" Foreground="#FF7043" FontSize="7.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          <Grid Grid.Column="1" Margin="2,4" ToolTip="Gemini weekly quota">
            <Border Background="#30FFFFFF" CornerRadius="3"/>
            <Border x:Name="barGWk" Background="#FFA726" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
          </Grid>
          <TextBlock x:Name="txtGWkVal" Grid.Column="2" Text="--%" Foreground="#B0BEC5" FontSize="8" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
          <TextBlock x:Name="txtRstGWk" Grid.Column="3" Text="--" Foreground="#78909C" FontSize="7.5" FontWeight="SemiBold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
        </Grid>

        <!-- C-WK -->
        <Grid Grid.Row="1" Grid.Column="2">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="28"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="26"/>
            <ColumnDefinition Width="42"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="C-WK" Foreground="#4FC3F7" FontSize="7.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          <Grid Grid.Column="1" Margin="2,4" ToolTip="Claude weekly quota">
            <Border Background="#30FFFFFF" CornerRadius="3"/>
            <Border x:Name="barCWk" Background="#4DD0E1" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
          </Grid>
          <TextBlock x:Name="txtCWkVal" Grid.Column="2" Text="--%" Foreground="#B0BEC5" FontSize="8" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
          <TextBlock x:Name="txtRstCWk" Grid.Column="3" Text="--" Foreground="#78909C" FontSize="7.5" FontWeight="SemiBold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
        </Grid>
      </Grid>

      <!-- ROW 8: ACTION BUTTONS (1:1:1 symmetry) -->
      <Grid Grid.Row="8">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="4"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="4"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="btnLoginNew" Grid.Column="0" ToolTip="Log in new Google account via browser">
          <Border CornerRadius="6" Background="#D000838F" Padding="2,4">
            <TextBlock Text="+ LOGIN" Foreground="#E0F7FA" FontSize="8.5" FontWeight="Bold" FontFamily="Consolas" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </Button>
        <Button x:Name="btnSave" Grid.Column="2" ToolTip="Save active session to profile">
          <Border CornerRadius="6" Background="#D0E65100" Padding="2,4">
            <TextBlock Text="+ SAVE" Foreground="#FFF3E0" FontSize="8.5" FontWeight="Bold" FontFamily="Consolas" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </Button>
        <Button x:Name="btnRef" Grid.Column="4" ToolTip="Refresh telemetry">
          <Border CornerRadius="6" Background="#30FFFFFF" Padding="2,4">
            <TextBlock Text="&#x21BB; SYNC" Foreground="#B0BEC5" FontSize="8.5" FontWeight="Bold" FontFamily="Consolas" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </Button>
      </Grid>

      <!-- ROW 10: STATUS BAR -->
      <Border Grid.Row="10" Background="#20FFFFFF" CornerRadius="5" Padding="8,2">
        <TextBlock x:Name="txSt" Text="READY" Foreground="#4FC3F7" FontSize="7.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </Border>

    </Grid>
  </Border>
</Window>
'@

[xml]$xaml = $xamlStr
$r = New-Object Xml.XmlNodeReader $xaml
$w = [Windows.Markup.XamlReader]::Load($r)

# Apply icon
if (Test-Path $ICON_PATH) {
    try { $w.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($ICON_PATH)) } catch {}
}

# Wire named elements
$ns = New-Object Xml.XmlNamespaceManager $xaml.NameTable
$ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
$nodes = $xaml.SelectNodes('//*[@x:Name]', $ns)
$e = @{}
foreach ($node in $nodes) {
    $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    $e[$name] = $w.FindName($name)
}

# ============================================================================
# HELPERS & BRUSH CACHE
# ============================================================================

$script:bc = [Windows.Media.BrushConverter]::new()
$script:BrushCache = @{}
function Br([string]$hex) {
    if (-not $script:BrushCache.ContainsKey($hex)) {
        $b = $script:bc.ConvertFromString($hex)
        if ($b.CanFreeze) { $b.Freeze() }
        $script:BrushCache[$hex] = $b
    }
    return $script:BrushCache[$hex]
}

# Quota bar color thresholds (adapted for dark glass)
$brushGreen  = Br "#66BB6A"
$brushOrange = Br "#FFA726"
$brushRed    = Br "#EF5350"

function GetBarBrush([double]$f) {
    if ($f -gt 0.5) { $brushGreen } elseif ($f -gt 0.2) { $brushOrange } else { $brushRed }
}

$script:lastUpgradeUri = $null
$script:selectedAccount = $null
$script:isFetchingQuota = $false
$script:dropdownOpen = $false

# Wire popup placement
$e.popAcc.PlacementTarget = $e.accSelector

function ApplyQuotaToBars($q) {
    if (-not $q) { return }
    $setBars = {
        param($barEl, $txtVal, $txtRst, $frac, $reset)
        $f = if ($frac -ne $null) { [double]$frac } else { 0.0 }
        $pct = [int]([math]::Round($f * 100))
        $txtVal.Text = "$pct%"
        $txtRst.Text = FormatCountdown $reset

        $parentW = if ($barEl.Parent -and $barEl.Parent.ActualWidth -gt 10) { $barEl.Parent.ActualWidth } else { 64.0 }
        $barEl.Width = [math]::Max(2, $parentW * [math]::Min($f, 1.0))
        $barEl.Background = GetBarBrush $f
    }

    & $setBars $e.barG5h $e.txtG5hVal $e.txtRstG5h $q.gemini_5h $q.gemini_5h_reset
    & $setBars $e.barGWk $e.txtGWkVal $e.txtRstGWk $q.gemini_wk $q.gemini_wk_reset
    & $setBars $e.barC5h $e.txtC5hVal $e.txtRstC5h $q.claude_5h $q.claude_5h_reset
    & $setBars $e.barCWk $e.txtCWkVal $e.txtRstCWk $q.claude_wk $q.claude_wk_reset

    if ($q.credits -ne $null) { $e.txtCredits.Text = "$($q.credits)" }
    if ($q.upgrade_uri) { $script:lastUpgradeUri = $q.upgrade_uri }
}

# ============================================================================
# NON-BLOCKING ASYNC QUOTA FETCHER
# ============================================================================

function FetchLiveQuotaAsync {
    if ($script:isFetchingQuota) { return }
    $script:isFetchingQuota = $true

    $e.txSt.Text = "SYNCING..."
    $e.txSt.Foreground = Br "#FFA726"

    $cliBin = Find-AgyBin
    $bgPs = [powershell]::Create()
    $bgPs.AddScript({
        param([string]$cliPath)
        $q = @{
            success = $false
            gemini_5h = 0.0; gemini_5h_reset = ""
            gemini_wk = 0.0; gemini_wk_reset = ""
            claude_5h = 0.0; claude_5h_reset = ""
            claude_wk = 0.0; claude_wk_reset = ""
            credits = 0; upgrade_uri = ""
            timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
        try {
            $uRaw = & $cliPath -p "/usage" --output-format json 2>$null
            if ($uRaw) {
                $uJson = $uRaw | ConvertFrom-Json -EA SilentlyContinue
                if ($uJson.command.data.groups) {
                    foreach ($g in $uJson.command.data.groups) {
                        if ($g.name -match "Gemini") {
                            foreach ($b in $g.buckets) {
                                if ($b.window -eq "5h") { $q.gemini_5h = [double]$b.remaining_fraction; $q.gemini_5h_reset = $b.reset_time }
                                elseif ($b.window -eq "weekly") { $q.gemini_wk = [double]$b.remaining_fraction; $q.gemini_wk_reset = $b.reset_time }
                            }
                        } elseif ($g.name -match "Claude") {
                            foreach ($b in $g.buckets) {
                                if ($b.window -eq "5h") { $q.claude_5h = [double]$b.remaining_fraction; $q.claude_5h_reset = $b.reset_time }
                                elseif ($b.window -eq "weekly") { $q.claude_wk = [double]$b.remaining_fraction; $q.claude_wk_reset = $b.reset_time }
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
    }) | Out-Null
    $bgPs.AddArgument($cliBin) | Out-Null

    $asyncHandle = $bgPs.BeginInvoke()

    $ticks = 0
    $script:pollTimer = New-Object Windows.Threading.DispatcherTimer
    $script:pollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $capturedBgPs = $bgPs
    $capturedHandle = $asyncHandle
    $pollHandler = {
        $ticks++
        if ($capturedHandle.IsCompleted -or $ticks -ge 75) {
            $script:pollTimer.Stop()
            try {
                if ($capturedHandle.IsCompleted) {
                    $res = $capturedBgPs.EndInvoke($capturedHandle)
                    if ($res -and $res.Count -gt 0) {
                        $liveQ = $res[0]
                        if ($liveQ.success) {
                            ApplyQuotaToBars $liveQ
                            if ($script:selectedAccount -and $script:selectedAccount.active) {
                                SaveAccountQuota $script:selectedAccount.name $liveQ
                            }
                            $e.txSt.Text = "SYNCED // $(Get-Date -Format 'HH:mm:ss')"
                            $e.txSt.Foreground = Br "#4FC3F7"
                        } else {
                            $e.txSt.Text = "OFFLINE // Check CLI"
                            $e.txSt.Foreground = Br "#FFA726"
                        }
                    }
                } else {
                    $capturedBgPs.Stop()
                    $e.txSt.Text = "SYNC TIMEOUT"
                    $e.txSt.Foreground = Br "#FFA726"
                }
            } catch {
                $e.txSt.Text = "SYNC ERROR"
                $e.txSt.Foreground = Br "#EF5350"
            } finally {
                try { if ($capturedHandle.AsyncWaitHandle) { $capturedHandle.AsyncWaitHandle.Close() } } catch {}
                $capturedBgPs.Dispose()
                $script:isFetchingQuota = $false
            }
        }
    }.GetNewClosure()
    $script:pollTimer.Add_Tick($pollHandler)
    $script:pollTimer.Start()
}

# ============================================================================
# ACTION BUTTONS STATE HELPER
# ============================================================================

function script:Update-ActionButtons($acc, $preloadedProcs = $null) {
    if (-not $acc) { return }
    $activeProcs = if ($preloadedProcs -ne $null) { $preloadedProcs } else { Get-ParallelProcesses }
    $isParallelRunning = [bool]($activeProcs | Where-Object { $_.IsParallel -and ($_.ProfileName -eq $acc.name.ToLower()) })

    if ($e.txtParalelBtn -and $e.brdParalel) {
        if ($acc.active) {
            # Active/Primary account: focus the main window
            $e.txtParalelBtn.Text = "FOCUS"
            $e.brdParalel.Background = Br "#D066BB6A"
            $e.btnParalel.ToolTip = "Focus primary Antigravity window"
        } elseif ($isParallelRunning) {
            $e.txtParalelBtn.Text = "FOCUS"
            $e.brdParalel.Background = Br "#D04FC3F7"
            $e.btnParalel.ToolTip = "Focus parallel window for '$($acc.name)'"
        } else {
            $e.txtParalelBtn.Text = "PARALLEL"
            $e.brdParalel.Background = Br "#D000838F"
            $e.btnParalel.ToolTip = "Launch parallel session for '$($acc.name)'"
        }
    }
}

# ============================================================================
# REFRESH-WIDGET
# ============================================================================

function Refresh-Widget {
    $cred = ReadActiveCredBlob
    $curEmail = if ($cred) { GetEmail $cred } else { "" }
    $curName = ""
    if ($curEmail -and (Test-Path $AF)) { $curName = (Get-Content $AF -Raw).Trim() }

    $activeProcs = Get-ParallelProcesses

    $allAccs = @()
    if ($curEmail) {
        $dn = if ($curName) { $curName } else { $curEmail.Split('@')[0] }
        $allAccs += @{ name=$dn; email=$curEmail; active=$true; status="PRIMARY" }
    }
    $saved = LoadAccs
    foreach ($a in $saved) {
        if ($a.email -eq $curEmail) { continue }
        $isRun = [bool]($activeProcs | Where-Object { $_.IsParallel -and ($_.ProfileName -eq $a.name.ToLower()) })
        $st = if ($isRun) { "RUNNING" } else { "IDLE" }
        $allAccs += @{ name=$a.name; email=$a.email; active=$false; status=$st }
    }

    # Populate dropdown panel
    $e.pnlAccList.Children.Clear()
    foreach ($acc in $allAccs) {
        $row = New-Object Windows.Controls.Border
        $row.CornerRadius = [Windows.CornerRadius]::new(5)
        $row.Padding = [Windows.Thickness]::new(8,5,8,5)
        $row.Margin = [Windows.Thickness]::new(0,0,0,2)
        $row.Cursor = 'Hand'
        $bgNormal = if ($acc.active) { "#30FFFFFF" } elseif ($acc.status -eq "RUNNING") { "#204FC3F7" } else { "#15FFFFFF" }
        $row.Background = Br $bgNormal

        $gridRow = New-Object Windows.Controls.Grid
        $cDot   = New-Object Windows.Controls.ColumnDefinition; $cDot.Width   = [Windows.GridLength]::Auto
        $cName  = New-Object Windows.Controls.ColumnDefinition; $cName.Width  = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $cBadge = New-Object Windows.Controls.ColumnDefinition; $cBadge.Width = [Windows.GridLength]::Auto
        $cDel   = New-Object Windows.Controls.ColumnDefinition; $cDel.Width   = [Windows.GridLength]::Auto
        $gridRow.ColumnDefinitions.Add($cDot)
        $gridRow.ColumnDefinitions.Add($cName)
        $gridRow.ColumnDefinitions.Add($cBadge)
        $gridRow.ColumnDefinitions.Add($cDel)

        # Col 0: Dot
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 6; $dot.Height = 6
        $dot.Fill = if ($acc.active) { Br "#66BB6A" } elseif ($acc.status -eq "RUNNING") { Br "#4FC3F7" } else { Br "#607D8B" }
        $dot.Margin = [Windows.Thickness]::new(0,0,6,0)
        $dot.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($dot, 0)
        $gridRow.Children.Add($dot) | Out-Null

        # Col 1: Label
        $lbl = New-Object Windows.Controls.TextBlock
        $lbl.Text = "$($acc.name.ToUpper())  $($acc.email)"
        $lbl.Foreground = Br "#E0E0E0"
        $lbl.FontFamily = [Windows.Media.FontFamily]::new("Consolas")
        $lbl.FontSize = 9; $lbl.FontWeight = 'Bold'; $lbl.VerticalAlignment = 'Center'
        $lbl.TextTrimming = 'CharacterEllipsis'
        $lbl.Margin = [Windows.Thickness]::new(0,0,6,0)
        [Windows.Controls.Grid]::SetColumn($lbl, 1)
        $gridRow.Children.Add($lbl) | Out-Null

        # Col 2: Badge
        $badge = New-Object Windows.Controls.Border
        $badge.CornerRadius = [Windows.CornerRadius]::new(3)
        $badge.Padding = [Windows.Thickness]::new(5,1,5,1)
        $badge.VerticalAlignment = 'Center'
        $bt = New-Object Windows.Controls.TextBlock
        $bt.Foreground = Br "#FFFFFF"; $bt.FontSize = 6.5
        $bt.FontFamily = [Windows.Media.FontFamily]::new("Consolas"); $bt.FontWeight = 'Bold'

        if ($acc.active) {
            $badge.Background = Br "#8066BB6A"; $bt.Text = "PRIMARY"
        } elseif ($acc.status -eq "RUNNING") {
            $badge.Background = Br "#804FC3F7"; $bt.Text = "RUNNING"
        } else {
            $badge.Background = Br "#40607D8B"; $bt.Text = "IDLE"
        }
        $badge.Child = $bt
        [Windows.Controls.Grid]::SetColumn($badge, 2)
        $gridRow.Children.Add($badge) | Out-Null

        # Col 3: Delete button for non-active accounts
        if (-not $acc.active) {
            $btnDel = New-Object Windows.Controls.Border
            $btnDel.Width = 20; $btnDel.Height = 20
            $btnDel.CornerRadius = [Windows.CornerRadius]::new(4)
            $btnDel.Background = Br "#20FFFFFF"
            $btnDel.Margin = [Windows.Thickness]::new(6,0,0,0)
            $btnDel.Cursor = 'Hand'
            $btnDel.VerticalAlignment = 'Center'
            $btnDel.ToolTip = "Delete profile '$($acc.name)'"
            $delTxt = New-Object Windows.Controls.TextBlock
            $delTxt.Text = [char]0x2715
            $delTxt.FontSize = 8; $delTxt.Foreground = Br "#78909C"
            $delTxt.HorizontalAlignment = 'Center'; $delTxt.VerticalAlignment = 'Center'
            $btnDel.Child = $delTxt

            $btnDel.Add_MouseEnter({ $this.Background = Br "#40EF5350"; $this.Child.Foreground = Br "#EF5350" }.GetNewClosure())
            $btnDel.Add_MouseLeave({ $this.Background = Br "#20FFFFFF"; $this.Child.Foreground = Br "#78909C" }.GetNewClosure())

            $delTargetName = $acc.name
            $btnDel.Add_PreviewMouseLeftButtonDown({
                $_.Handled = $true
                $conf = [Windows.MessageBox]::Show(
                    "Delete profile '$delTargetName'?",
                    "Confirm Delete",
                    [Windows.MessageBoxButton]::YesNo,
                    [Windows.MessageBoxImage]::Warning
                )
                if ($conf -eq [Windows.MessageBoxResult]::Yes) {
                    DelAcc $delTargetName
                    $script:dropdownOpen = $false
                    $e.popAcc.IsOpen = $false
                    $e.txSt.Text = "DELETED: $delTargetName"
                    $e.txSt.Foreground = Br "#FF7043"
                    Refresh-Widget
                }
            }.GetNewClosure())
            [Windows.Controls.Grid]::SetColumn($btnDel, 3)
            $gridRow.Children.Add($btnDel) | Out-Null
        }

        $row.Child = $gridRow

        # Click handler — select account
        $capturedAcc = $acc
        $row.Add_PreviewMouseLeftButtonDown({
            $script:selectedAccount = $capturedAcc
            $e.txtAccName.Text = "$($capturedAcc.name.ToUpper())  $($capturedAcc.email)"
            $e.txtEmail.Text = $capturedAcc.email
            $script:dropdownOpen = $false
            $e.popAcc.IsOpen = $false
            $_.Handled = $true

            Update-ActionButtons $capturedAcc

            $cachedQ = GetAccountQuota $capturedAcc.name
            if ($cachedQ) {
                ApplyQuotaToBars $cachedQ
                $e.txSt.Text = "SELECTED: $($capturedAcc.name.ToUpper())"
                $e.txSt.Foreground = Br "#4FC3F7"
            }
        }.GetNewClosure())

        # Hover effects
        $capturedBg = $bgNormal
        $row.Add_MouseEnter({ $this.Background = Br "#35FFFFFF" }.GetNewClosure())
        $row.Add_MouseLeave({ $this.Background = Br $capturedBg }.GetNewClosure())

        $e.pnlAccList.Children.Add($row) | Out-Null
    }

    # Set initial selection to active account
    if ($allAccs.Count -gt 0) {
        $first = $allAccs[0]
        $script:selectedAccount = $first
        $e.txtAccName.Text = "$($first.name.ToUpper())  $($first.email)"
        Update-ActionButtons $first $activeProcs
    } else {
        $e.txtAccName.Text = "(not logged in)"
    }

    # Email display
    $e.txtEmail.Text = if ($curEmail) { $curEmail } else { "(not logged in)" }

    # Status LED
    $e.ledStatus.Fill = if ($curEmail) { Br "#4FC3F7" } else { Br "#FFA726" }
    $e.txtStatus.Text = if ($curEmail) { "ONLINE" } else { "OFFLINE" }
    $e.txtStatus.Foreground = if ($curEmail) { Br "#4FC3F7" } else { Br "#FFA726" }

    # Load local cached quota immediately
    if ($curName) {
        $localQ = GetAccountQuota $curName
        if ($localQ) { ApplyQuotaToBars $localQ }
    }

    # Trigger non-blocking async quota fetch
    FetchLiveQuotaAsync
}

# ============================================================================
# ASK-NAME DIALOG (Glass themed)
# ============================================================================

function AskName([string]$def) {
    $d = New-Object Windows.Window
    $d.Title = "AGY RIG // Profile Name"; $d.Width = 300; $d.Height = 150
    $d.WindowStartupLocation = 'CenterOwner'; $d.Owner = $w
    $d.WindowStyle = 'ToolWindow'; $d.ResizeMode = 'NoResize'
    $d.Background = Br "#FF1E1E1E"

    $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = [Windows.Thickness]::new(14,10,14,10)
    $lbl = New-Object Windows.Controls.TextBlock
    $lbl.Text = "Enter profile name:"; $lbl.FontFamily = [Windows.Media.FontFamily]::new("Consolas"); $lbl.FontSize = 10; $lbl.FontWeight = 'Bold'; $lbl.Foreground = Br "#E0E0E0"

    $tb = New-Object Windows.Controls.TextBox
    $tb.Text = $def; $tb.FontFamily = [Windows.Media.FontFamily]::new("Consolas"); $tb.FontSize = 11
    $tb.Background = Br "#FF2D2D2D"; $tb.Foreground = Br "#E0E0E0"; $tb.BorderBrush = Br "#404040"; $tb.Padding = [Windows.Thickness]::new(4,2,4,2)
    $tb.Margin = [Windows.Thickness]::new(0,6,0,10)
    $tb.CaretBrush = Br "#4FC3F7"

    $spBtn = New-Object Windows.Controls.StackPanel; $spBtn.Orientation = 'Horizontal'; $spBtn.HorizontalAlignment = 'Right'
    $btnCancel = New-Object Windows.Controls.Button; $btnCancel.Content = "Cancel"; $btnCancel.Width = 60; $btnCancel.Height = 24
    $btnCancel.Margin = [Windows.Thickness]::new(0,0,6,0); $btnCancel.IsCancel = $true
    $btnCancel.Foreground = Br "#B0BEC5"
    $btnCancel.Add_Click({ $d.DialogResult = $false; $d.Close() })

    $btnOk = New-Object Windows.Controls.Button; $btnOk.Content = "OK"; $btnOk.Width = 60; $btnOk.Height = 24
    $btnOk.IsDefault = $true; $btnOk.FontWeight = 'Bold'
    $btnOk.Foreground = Br "#4FC3F7"
    $btnOk.Add_Click({ $d.DialogResult = $true; $d.Close() })

    $spBtn.Children.Add($btnCancel) | Out-Null
    $spBtn.Children.Add($btnOk) | Out-Null
    $sp.Children.Add($lbl) | Out-Null
    $sp.Children.Add($tb) | Out-Null
    $sp.Children.Add($spBtn) | Out-Null
    $d.Content = $sp

    $d.Add_Loaded({ $tb.Focus(); $tb.SelectAll() })
    if ($d.ShowDialog()) { return $tb.Text.Trim() }
    return $null
}

# ============================================================================
# EVENT HANDLERS
# ============================================================================

# Drag from header row only
$e.hdrDrag.Add_MouseLeftButtonDown({
    if ($_.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
        try { $w.DragMove() } catch {}
    }
})

# Window controls
$e.btnMin.Add_Click({ $w.WindowState = 'Minimized' })
$e.btnClose.Add_Click({ $w.Close() })

# Pin toggle
$e.chkPin.Add_Checked({
    $w.Topmost = $true
    $e.pinBorder.Background = Br "#D04FC3F7"
    $e.pinBorder.BorderBrush = Br "#804FC3F7"
    $e.dotPin.Fill = Br "#FFFFFF"
    $e.dotPin.HorizontalAlignment = 'Right'
    $e.txtPin.HorizontalAlignment = 'Left'
    $e.txtPin.Text = "ON"
    $e.txtPin.Foreground = Br "#FFFFFF"
})
$e.chkPin.Add_Unchecked({
    $w.Topmost = $false
    $e.pinBorder.Background = Br "#30FFFFFF"
    $e.pinBorder.BorderBrush = Br "#40FFFFFF"
    $e.dotPin.Fill = Br "#80FFFFFF"
    $e.dotPin.HorizontalAlignment = 'Left'
    $e.txtPin.HorizontalAlignment = 'Right'
    $e.txtPin.Text = "PIN"
    $e.txtPin.Foreground = Br "#80FFFFFF"
})

# Upgrade credits
$e.btnUpgrade.Add_Click({
    $uri = if ($script:lastUpgradeUri) { $script:lastUpgradeUri } else { "https://aistudio.google.com/apikey" }
    Start-Process $uri
})

# Open/close account dropdown (toggle, not fighting with StaysOpen)
$e.accSelector.Add_PreviewMouseLeftButtonDown({
    $script:dropdownOpen = -not $script:dropdownOpen
    $e.popAcc.IsOpen = $script:dropdownOpen
    $_.Handled = $true
})

# Close dropdown when clicking outside (only on the window itself, not on popup children)
$w.Add_MouseLeftButtonDown({
    if ($script:dropdownOpen) {
        $script:dropdownOpen = $false
        $e.popAcc.IsOpen = $false
    }
})

# Arrow indicator
$e.popAcc.Add_Opened({ if ($e.txtArrow) { $e.txtArrow.Text = [char]0x25B2 } })
$e.popAcc.Add_Closed({
    if ($e.txtArrow) { $e.txtArrow.Text = [char]0x25BC }
    $script:dropdownOpen = $false
})

# Close popup if window moves
$w.Add_LocationChanged({
    if ($script:dropdownOpen) {
        $script:dropdownOpen = $false
        $e.popAcc.IsOpen = $false
    }
})

# SWITCH
$e.btnSwitch.Add_Click({
    $tag = $script:selectedAccount
    if (-not $tag) { $e.txSt.Text = "Select profile first"; $e.txSt.Foreground = Br "#FFA726"; return }
    if ($tag.active) {
        $e.txSt.Text = "Already active"; $e.txSt.Foreground = Br "#FFA726"
        return
    }
    $e.txSt.Text = "SWITCHING..."; $e.txSt.Foreground = Br "#FFA726"
    $w.Dispatcher.Invoke([Action]{}, 'Render')
    SwitchTo $tag.name
    $e.txSt.Text = "SWITCHED: $($tag.name.ToUpper())"
    $e.txSt.Foreground = Br "#4FC3F7"
    Refresh-Widget
})

# PARALLEL / FOCUS
$e.btnParalel.Add_Click({
    $tag = $script:selectedAccount
    if (-not $tag) { $e.txSt.Text = "Select profile first"; $e.txSt.Foreground = Br "#FFA726"; return }
    $res = FocusOrLaunchParallel $tag.name
    if ($res -eq "FOCUSED") {
        $e.txSt.Text = "FOCUSED: $($tag.name.ToUpper())"
        $e.txSt.Foreground = Br "#4FC3F7"
    } elseif ($res -eq "FOCUSED_MAIN") {
        $e.txSt.Text = "FOCUSED: PRIMARY"
        $e.txSt.Foreground = Br "#4FC3F7"
    } elseif ($res -eq "OK") {
        $e.txSt.Text = "PARALLEL LAUNCHED: $($tag.name.ToUpper())"
        $e.txSt.Foreground = Br "#66BB6A"
    } else {
        $e.txSt.Text = "PARALLEL ERROR: $res"
        $e.txSt.Foreground = Br "#EF5350"
    }
    Refresh-Widget
})

# LOGIN
$e.btnLoginNew.Add_Click({
    $e.txSt.Text = "BROWSER LOGIN..."; $e.txSt.Foreground = Br "#FFA726"
    $w.Dispatcher.Invoke([Action]{}, 'Render')
    try {
        $res = StartBrowserGoogleLogin
        if ($res.success) {
            $defaultName = if ($res.email) { $res.email.Split('@')[0] } else { "user" }
            $name = AskName $defaultName
            if ($name) {
                $cleanName = $name.ToLower().Trim()
                $accountData = @{
                    name = $cleanName
                    user = "antigravity"
                    email = if ($res.email) { $res.email } else { "(not detected)" }
                    credential = (Enc $res.credential)
                    saved_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                } | ConvertTo-Json -Depth 5
                [IO.File]::WriteAllText((Join-Path $AD "$cleanName.dat"), $accountData, [Text.Encoding]::UTF8)

                $ans = [Windows.MessageBox]::Show(
                    "Profile '$cleanName' ($($res.email)) saved.`n`nSwitch to this profile now?",
                    "Sign-in Successful",
                    [Windows.MessageBoxButton]::YesNo,
                    [Windows.MessageBoxImage]::Question
                )
                if ($ans -eq [Windows.MessageBoxResult]::Yes) {
                    SwitchTo $cleanName
                    $e.txSt.Text = "SWITCHED: $cleanName"
                } else {
                    $e.txSt.Text = "SAVED: $cleanName"
                }
                $e.txSt.Foreground = Br "#4FC3F7"
                Refresh-Widget
            }
        } else {
            $e.txSt.Text = "LOGIN CANCELLED"
            $e.txSt.Foreground = Br "#FFA726"
        }
    } catch {
        $e.txSt.Text = "LOGIN ERROR: $($_.Exception.Message)"
        $e.txSt.Foreground = Br "#EF5350"
    }
})

# SAVE
$e.btnSave.Add_Click({
    $cred = ReadActiveCredBlob
    if (-not $cred) {
        $e.txSt.Text = "No active session"; $e.txSt.Foreground = Br "#EF5350"
        return
    }
    $email = GetEmail $cred
    $name = AskName ($email.Split('@')[0])
    if ($name) {
        SaveCur $name
        $e.txSt.Text = "SAVED: $name"
        $e.txSt.Foreground = Br "#4FC3F7"
        Refresh-Widget
    }
})

# SYNC
$e.btnRef.Add_Click({
    FetchLiveQuotaAsync
})

# Auto-refresh timer every 3 minutes
$autoSyncTimer = New-Object Windows.Threading.DispatcherTimer
$autoSyncTimer.Interval = [TimeSpan]::FromMinutes(3)
$autoSyncTimer.Add_Tick({
    FetchLiveQuotaAsync
})
$autoSyncTimer.Start()

# Cleanup on close
$w.Add_Closing({
    try { $autoSyncTimer.Stop() } catch {}
    try { if ($script:pollTimer) { $script:pollTimer.Stop() } } catch {}
})

# Enable acrylic blur after window loads
$w.Add_SourceInitialized({
    try {
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper $w).Handle
        # Tint: AABBGGRR format, semi-transparent dark
        [AcrylicHelper]::EnableBlur($hwnd, 0x99181818)
    } catch {}
})

# Initial render
$w.Add_ContentRendered({
    Refresh-Widget
})

# ============================================================================
# LAUNCH
# ============================================================================

$w.ShowDialog() | Out-Null
