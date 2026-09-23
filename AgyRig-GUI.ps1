# ============================================================================
# AGY RIG - Super-Compact Dock & Account Manager for Google Antigravity (AGY)
# Fully Polished Edition: 100% Functional, Asymmetric-Safe, Symmetric-Layout,
# Non-Blocking Async Telemetry, Hardware Saklar, and Inline Profile Management.
# ============================================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Drawing

# ============================================================================
# BACKEND: Credential Manager + DPAPI + Native AGY Quota Fetcher
# ============================================================================

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
"@ -EA SilentlyContinue

$CT = "gemini:antigravity"
$BD = Join-Path $env:USERPROFILE ".gemini\antigravity\scratch\agy-switch"
$AD = Join-Path $BD "accounts"
$CD = Join-Path $BD "credits"
$PD = Join-Path $env:USERPROFILE ".gemini\antigravity\profiles"
$AF = Join-Path $BD "active_account.txt"
$ICON_PATH = Join-Path $BD "agy-rig.ico"

foreach ($d in @($AD, $CD, $PD)) {
    if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
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
        if (-not $data.email -or $data.email -like "*(tidak terdeteksi)*") {
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

    $html = "<html><body style='font-family:Consolas,monospace;text-align:center;padding:50px;background:#161408;color:#FFE633;'><h2>LOGIN BERHASIL!</h2><p style='color:#B3A220;'>Akun Google Anda berhasil terhubung ke AGY RIG.<br>Silakan tutup tab ini dan kembali ke widget.</p></body></html>"
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
    if (!$em) { $em = "(tidak terdeteksi)" }
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

    # Restart primary Antigravity
    $pr = Get-Process -Name "Antigravity*" -EA SilentlyContinue
    $exe = $null
    if ($pr) {
        try { $exe = $pr[0].Path } catch {}
        $pr | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep -Seconds 2
    }
    if ($exe -and (Test-Path $exe)) {
        Start-Process $exe
    } else {
        @("$env:LOCALAPPDATA\Programs\Antigravity\Antigravity.exe","$env:LOCALAPPDATA\Antigravity\Antigravity.exe") | ForEach-Object {
            if ((Test-Path $_) -and !$exe) { Start-Process $_; $exe = $_ }
        }
    }
    return "OK"
}

function script:LaunchParallel([string]$n) {
    $ap = Join-Path $AD "$($n.ToLower()).dat"
    if (!(Test-Path $ap)) { return "NOT_FOUND" }
    $ac = Get-Content $ap -Raw | ConvertFrom-Json
    try { $targetBlob = Dec $ac.credential } catch { return "FAIL" }
    $targetUser = if ($ac.user) { $ac.user } else { "antigravity" }

    # Setup profile user data directory
    $profDir = Join-Path $env:USERPROFILE ".gemini\antigravity\profiles\$($n.ToLower())"
    $userDir = Join-Path $profDir "userdata"
    if (!(Test-Path $userDir)) {
        New-Item -ItemType Directory -Path $userDir -Force | Out-Null
        $initStorage = @{ "ide-install-wizard-shown" = "true" } | ConvertTo-Json
        [IO.File]::WriteAllText((Join-Path $userDir "app_storage.json"), $initStorage, [Text.Encoding]::UTF8)
    }

    # Find Antigravity executable
    $pr = Get-Process -Name "Antigravity*" -EA SilentlyContinue
    $exe = $null
    if ($pr) { try { if (Test-Path $pr[0].Path) { $exe = $pr[0].Path } } catch {} }
    if (!$exe) {
        @("$env:LOCALAPPDATA\Programs\Antigravity\Antigravity.exe","$env:LOCALAPPDATA\Antigravity\Antigravity.exe") | ForEach-Object {
            if ((Test-Path $_) -and !$exe) { $exe = $_ }
        }
    }
    if (!$exe) { return "NO_EXE" }

    # Read current active credential so we can restore it
    $curBlob = [AgyCredMgr]::Read($CT)
    $curUser = [AgyCredMgr]::ReadUser($CT)

    # Temporarily set target credential so the new instance loads this account
    [AgyCredMgr]::Write($CT, $targetUser, $targetBlob) | Out-Null

    # Launch parallel Antigravity instance with custom --user-data-dir
    Start-Process $exe -ArgumentList "--user-data-dir=`"$userDir`""

    # Also copy MCP tokens if present for this profile
    $mb = Join-Path $AD "$($n.ToLower())_mcp.dat"
    $mt = Join-Path $env:USERPROFILE ".gemini\antigravity\mcp_oauth_tokens.json"
    if (Test-Path $mb) {
        try { [IO.File]::WriteAllText($mt, (Dec(Get-Content $mb -Raw)), [Text.Encoding]::UTF8) } catch {}
    }

    # Thread-safe DispatcherTimer to restore previous credential after 4 seconds
    if ($curBlob -and ($curBlob -ne $targetBlob)) {
        $restoreTimer = New-Object Windows.Threading.DispatcherTimer
        $restoreTimer.Interval = [TimeSpan]::FromSeconds(4)
        $restoreTimer.Add_Tick({
            $restoreTimer.Stop()
            [AgyCredMgr]::Write($CT, $curUser, $curBlob) | Out-Null
        })
        $restoreTimer.Start()
    }

    # Create/update desktop shortcut for this parallel profile
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $lnkPath = Join-Path $desktop "Antigravity ($($n.ToUpper())).lnk"
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnkPath)
        $sc.TargetPath = $exe
        $sc.Arguments = "--user-data-dir=`"$userDir`""
        $sc.IconLocation = "$ICON_PATH,0"
        $sc.Description = "Antigravity Profile: $($n.ToUpper())"
        $sc.Save()
    } catch {}

    return "OK"
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
# GUI — COMPACT DOCK (PERFECT SYMMETRY & CRISP HD LAYOUT)
# ============================================================================

$xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  Title="AGY RIG" Width="380" Height="216"
  WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
  Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="True" Topmost="False"
  TextOptions.TextFormattingMode="Display"
  TextOptions.TextRenderingMode="ClearType"
  RenderOptions.BitmapScalingMode="HighQuality"
  RenderOptions.ClearTypeHint="Enabled"
  SnapsToDevicePixels="True"
  UseLayoutRounding="True">

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
                <Setter Property="Opacity" Value="0.6"/>
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

  <Border CornerRadius="14" Background="#E7E2D1" BorderBrush="#B5AD96" BorderThickness="1.5"
          Margin="6" Padding="12,8" SnapsToDevicePixels="True" UseLayoutRounding="True"
          RenderOptions.ClearTypeHint="Enabled">
    <Border.Effect>
      <DropShadowEffect Color="#000000" BlurRadius="16" ShadowDepth="3" Opacity="0.35" Direction="315"/>
    </Border.Effect>

    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="24"/>
        <RowDefinition Height="28"/>
        <RowDefinition Height="18"/>
        <RowDefinition Height="6"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="8"/>
        <RowDefinition Height="26"/>
        <RowDefinition Height="6"/>
        <RowDefinition Height="20"/>
      </Grid.RowDefinitions>

      <!-- ROW 0: HEADER (DRAGGABLE) -->
      <Grid x:Name="hdrDrag" Grid.Row="0" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="15" Height="15" Background="#26241D" CornerRadius="7.5" Margin="0,0,5,0">
            <TextBlock Text="&#x25B2;" Foreground="#FFE633" FontSize="7.5" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="AGY RIG" Foreground="#2E2B23" FontSize="10.5" FontWeight="Black" FontFamily="Consolas" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
          <Ellipse x:Name="ledStatus" Width="6" Height="6" Fill="#00E676" Margin="0,0,3,0"/>
          <TextBlock x:Name="txtStatus" Text="ONLINE" Foreground="#388E3C" FontSize="7" FontWeight="Bold" FontFamily="Consolas"/>
        </StackPanel>
        <!-- SAKLAR PIN -->
        <ToggleButton x:Name="chkPin" Grid.Column="2" VerticalAlignment="Center" Margin="0,0,4,0"
                      ToolTip="Saklar: Selalu di atas (Pin)">
          <Border x:Name="pinBorder" CornerRadius="7.5" Background="#C8C2B0" BorderBrush="#9E9682" BorderThickness="1"
                  Width="40" Height="15" SnapsToDevicePixels="True">
            <Grid Margin="3,0">
              <TextBlock x:Name="txtPin" Text="PIN" FontSize="6" FontWeight="Bold" FontFamily="Consolas" Foreground="#423E33"
                         HorizontalAlignment="Left" VerticalAlignment="Center"/>
              <Ellipse x:Name="dotPin" Width="9" Height="9" Fill="#787263" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
          </Border>
        </ToggleButton>
        <Button x:Name="btnMin" Grid.Column="3" Width="20" Height="16" Margin="0,0,4,0" Cursor="Hand"
                Background="Transparent" BorderThickness="0" ToolTip="Minimize"
                HorizontalContentAlignment="Stretch" VerticalContentAlignment="Stretch">
          <Border CornerRadius="3" Background="#C8C2B0" BorderBrush="#9E9682" BorderThickness="1">
            <TextBlock Text="&#x2014;" FontSize="8" Foreground="#423E33" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/>
          </Border>
        </Button>
        <Button x:Name="btnClose" Grid.Column="4" Width="20" Height="16" Cursor="Hand"
                Background="Transparent" BorderThickness="0" ToolTip="Tutup"
                HorizontalContentAlignment="Stretch" VerticalContentAlignment="Stretch">
          <Border CornerRadius="3" Background="#D32F2F" BorderBrush="#8E0000" BorderThickness="1">
            <TextBlock Text="&#x2715;" FontSize="7.5" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </Button>
      </Grid>

      <!-- ROW 1: ACCOUNT SELECTOR + SWITCH + PARALEL -->
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border x:Name="accSelector" Grid.Column="0" CornerRadius="4" Background="#DCD6C4"
                BorderBrush="#ABA28D" BorderThickness="1" Padding="7,3" Cursor="Hand" ToolTip="Klik untuk pilih akun"
                SnapsToDevicePixels="True" Height="26">
          <Grid>
            <TextBlock x:Name="txtAccName" Text="(pilih akun)" Foreground="#2E2B23"
                       FontFamily="Consolas" FontSize="9.5" FontWeight="Bold" VerticalAlignment="Center"
                       TextTrimming="CharacterEllipsis" Margin="0,0,16,0"/>
            <TextBlock x:Name="txtArrow" Text="&#x25BC;" Foreground="#787263" FontSize="8"
                       HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
        </Border>
        <Popup x:Name="popAcc" Placement="Bottom" StaysOpen="True" AllowsTransparency="True">
          <Border Background="#F5F2E8" BorderBrush="#ABA28D" BorderThickness="1.5" CornerRadius="6"
                  Padding="4" MinWidth="260" MaxHeight="160" SnapsToDevicePixels="True">
            <Border.Effect>
              <DropShadowEffect BlurRadius="10" ShadowDepth="3" Opacity="0.35"/>
            </Border.Effect>
            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="pnlAccList"/>
            </ScrollViewer>
          </Border>
        </Popup>
        <Button x:Name="btnSwitch" Grid.Column="1" Cursor="Hand" Margin="4,0,0,0" VerticalAlignment="Center"
                Background="Transparent" BorderThickness="0" ToolTip="Switch ke akun terpilih" Height="26"
                HorizontalContentAlignment="Stretch" VerticalContentAlignment="Stretch">
          <Border CornerRadius="4" Background="#E65100" Padding="8,4">
            <TextBlock Text="SWITCH" Foreground="#FFFFFF" FontSize="8" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          </Border>
        </Button>
        <Button x:Name="btnParalel" Grid.Column="2" Cursor="Hand" Margin="3,0,0,0" VerticalAlignment="Center"
                Background="Transparent" BorderThickness="0" ToolTip="Buka paralel instance" Height="26"
                HorizontalContentAlignment="Stretch" VerticalContentAlignment="Stretch">
          <Border CornerRadius="4" Background="#00838F" Padding="8,4">
            <TextBlock Text="PARALEL" Foreground="#FFFFFF" FontSize="8" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          </Border>
        </Button>
      </Grid>

      <!-- ROW 2: EMAIL + CREDITS -->
      <Grid Grid.Row="2">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="txtEmail" Grid.Column="0" Text="..." Foreground="#787263" FontSize="8" FontFamily="Consolas"
                   VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="txtCredits" Text="0" Foreground="#1B5E20" FontSize="9" FontWeight="Bold" FontFamily="Consolas"/>
          <TextBlock Text=" CR" Foreground="#388E3C" FontSize="7" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          <Button x:Name="btnUpgrade" Cursor="Hand" Margin="4,0,0,0" Background="Transparent" BorderThickness="0" ToolTip="Beli credits / buka AI Studio"
                  HorizontalContentAlignment="Stretch" VerticalContentAlignment="Stretch">
            <Border CornerRadius="3" Background="#2E7D32" Padding="4,1">
              <TextBlock Text="&#x2197;" Foreground="#FFFFFF" FontSize="8" FontWeight="Bold"/>
            </Border>
          </Button>
        </StackPanel>
      </Grid>

      <!-- ROW 4: QUOTA BARS (2x2 grid with exact symmetry) -->
      <Grid Grid.Row="4">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="16"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="18"/>
          <RowDefinition Height="18"/>
        </Grid.RowDefinitions>

        <!-- GEM-5H -->
        <Grid Grid.Row="0" Grid.Column="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="34"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="28"/>
            <ColumnDefinition Width="32"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="G-5H" Foreground="#544F43" FontSize="7" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          <Grid Grid.Column="1" Margin="2,3" ToolTip="Gemini 5-hour quota">
            <Border Background="#3D3A33" CornerRadius="3"/>
            <Border x:Name="barG5h" Background="#E65100" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
          </Grid>
          <TextBlock x:Name="txtG5hVal" Grid.Column="2" Text="--%" Foreground="#2E2B23" FontSize="7" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
          <TextBlock x:Name="txtRstG5h" Grid.Column="3" Text="--" Foreground="#787263" FontSize="6.5" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
        </Grid>

        <!-- CLD-5H -->
        <Grid Grid.Row="0" Grid.Column="2">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="34"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="28"/>
            <ColumnDefinition Width="32"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="C-5H" Foreground="#544F43" FontSize="7" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          <Grid Grid.Column="1" Margin="2,3" ToolTip="Claude 5-hour quota">
            <Border Background="#3D3A33" CornerRadius="3"/>
            <Border x:Name="barC5h" Background="#00897B" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
          </Grid>
          <TextBlock x:Name="txtC5hVal" Grid.Column="2" Text="--%" Foreground="#2E2B23" FontSize="7" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
          <TextBlock x:Name="txtRstC5h" Grid.Column="3" Text="--" Foreground="#787263" FontSize="6.5" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
        </Grid>

        <!-- GEM-WK -->
        <Grid Grid.Row="1" Grid.Column="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="34"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="28"/>
            <ColumnDefinition Width="32"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="G-WK" Foreground="#544F43" FontSize="7" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          <Grid Grid.Column="1" Margin="2,3" ToolTip="Gemini weekly quota">
            <Border Background="#3D3A33" CornerRadius="3"/>
            <Border x:Name="barGWk" Background="#EF6C00" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
          </Grid>
          <TextBlock x:Name="txtGWkVal" Grid.Column="2" Text="--%" Foreground="#2E2B23" FontSize="7" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
          <TextBlock x:Name="txtRstGWk" Grid.Column="3" Text="--" Foreground="#787263" FontSize="6.5" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
        </Grid>

        <!-- CLD-WK -->
        <Grid Grid.Row="1" Grid.Column="2">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="34"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="28"/>
            <ColumnDefinition Width="32"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="C-WK" Foreground="#544F43" FontSize="7" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          <Grid Grid.Column="1" Margin="2,3" ToolTip="Claude weekly quota">
            <Border Background="#3D3A33" CornerRadius="3"/>
            <Border x:Name="barCWk" Background="#00897B" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
          </Grid>
          <TextBlock x:Name="txtCWkVal" Grid.Column="2" Text="--%" Foreground="#2E2B23" FontSize="7" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
          <TextBlock x:Name="txtRstCWk" Grid.Column="3" Text="--" Foreground="#787263" FontSize="6.5" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
        </Grid>
      </Grid>

      <!-- ROW 6: ACTION BUTTONS (Exact 1:1:1 symmetry with 4px gap) -->
      <Grid Grid.Row="6">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="btnLoginNew" Grid.Column="0" Cursor="Hand" Margin="0,0,3,0"
                Background="Transparent" BorderThickness="0" ToolTip="Login akun Google baru via browser"
                HorizontalContentAlignment="Stretch" VerticalContentAlignment="Stretch">
          <Border CornerRadius="4" Background="#00838F" Padding="2,4">
            <TextBlock Text="+ LOGIN" Foreground="#FFFFFF" FontSize="8" FontWeight="Bold" FontFamily="Consolas" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </Button>
        <Button x:Name="btnSave" Grid.Column="1" Cursor="Hand" Margin="1.5,0,1.5,0"
                Background="Transparent" BorderThickness="0" ToolTip="Simpan sesi aktif ke slot"
                HorizontalContentAlignment="Stretch" VerticalContentAlignment="Stretch">
          <Border CornerRadius="4" Background="#E65100" Padding="2,4">
            <TextBlock Text="+ SIMPAN" Foreground="#FFFFFF" FontSize="8" FontWeight="Bold" FontFamily="Consolas" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </Button>
        <Button x:Name="btnRef" Grid.Column="2" Cursor="Hand" Margin="3,0,0,0"
                Background="Transparent" BorderThickness="0" ToolTip="Refresh telemetri"
                HorizontalContentAlignment="Stretch" VerticalContentAlignment="Stretch">
          <Border CornerRadius="4" Background="#546E7A" Padding="2,4">
            <TextBlock Text="&#x21BB; SYNC" Foreground="#FFFFFF" FontSize="8" FontWeight="Bold" FontFamily="Consolas" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </Button>
      </Grid>

      <!-- ROW 8: STATUS BAR -->
      <Border Grid.Row="8" Background="#26241D" CornerRadius="4" Padding="6,2">
        <TextBlock x:Name="txSt" Text="READY" Foreground="#00E676" FontSize="7" FontWeight="Bold" FontFamily="Consolas" TextTrimming="CharacterEllipsis"/>
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

# Wire named elements reliably
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

$bc = [Windows.Media.BrushConverter]::new()
function Br([string]$hex) { $bc.ConvertFromString($hex) }

$brushGreen  = Br "#2E7D32"
$brushOrange = Br "#EF6C00"
$brushRed    = Br "#C62828"

function GetBarBrush([double]$f) {
    if ($f -gt 0.5) { $brushGreen } elseif ($f -gt 0.2) { $brushOrange } else { $brushRed }
}

$script:lastUpgradeUri = $null
$script:selectedAccount = $null
$script:isFetchingQuota = $false

# Wire popup placement
$e.popAcc.PlacementTarget = $e.accSelector

function ApplyQuotaToBars($q) {
    if (-not $q) { return }
    $tw = 55
    $setBars = {
        param($barEl, $txtVal, $txtRst, $frac, $reset)
        $f = if ($frac -ne $null) { [double]$frac } else { 0.0 }
        $pct = [int]([math]::Round($f * 100))
        $txtVal.Text = "$pct%"
        $txtRst.Text = FormatCountdown $reset
        $barEl.Width = [math]::Max(2, $tw * [math]::Min($f, 1.0))
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
# NON-BLOCKING ASYNC QUOTA FETCHER (Zero UI Freezes)
# ============================================================================

function FetchLiveQuotaAsync {
    if ($script:isFetchingQuota) { return }
    $script:isFetchingQuota = $true

    $e.txSt.Text = "SYNCING..."
    $e.txSt.Foreground = Br "#FFA000"

    $bgPs = [powershell]::Create()
    $bgPs.AddScript({
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
            $uRaw = & agy -p "/usage" --output-format json 2>$null
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
    }) | Out-Null

    $asyncHandle = $bgPs.BeginInvoke()

    $pollTimer = New-Object Windows.Threading.DispatcherTimer
    $pollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $pollTimer.Add_Tick({
        if ($asyncHandle.IsCompleted) {
            $pollTimer.Stop()
            try {
                $res = $bgPs.EndInvoke($asyncHandle)
                if ($res -and $res.Count -gt 0) {
                    $liveQ = $res[0]
                    if ($liveQ.success) {
                        ApplyQuotaToBars $liveQ
                        # Save quota for active account
                        if ($script:selectedAccount -and $script:selectedAccount.active) {
                            SaveAccountQuota $script:selectedAccount.name $liveQ
                        }
                        $e.txSt.Text = "SYNCED // $(Get-Date -Format 'HH:mm:ss')"
                        $e.txSt.Foreground = Br "#00E676"
                    } else {
                        $e.txSt.Text = "OFFLINE // Check CLI"
                        $e.txSt.Foreground = Br "#FFA000"
                    }
                }
            } catch {
                $e.txSt.Text = "SYNC ERROR"
                $e.txSt.Foreground = Br "#C62828"
            } finally {
                $bgPs.Dispose()
                $script:isFetchingQuota = $false
            }
        }
    })
    $pollTimer.Start()
}

# ============================================================================
# REFRESH-WIDGET (Instant Local Render + Async Live Telemetry)
# ============================================================================

function Refresh-Widget {
    # Current active credential
    $cred = $null
    try { $cred = [AgyCredMgr]::Read("antigravity_google_oauth_credential") } catch {}
    $curEmail = if ($cred) { GetEmail $cred } else { "" }
    $curName = ""
    if ($curEmail -and (Test-Path $AF)) { $curName = (Get-Content $AF -Raw).Trim() }

    # Build account list
    $allAccs = @()
    if ($curEmail) {
        $dn = if ($curName) { $curName } else { $curEmail.Split('@')[0] }
        $allAccs += @{ name=$dn; email=$curEmail; active=$true }
    }
    $saved = LoadAccs
    foreach ($a in $saved) {
        if ($a.email -eq $curEmail) { continue }
        $allAccs += @{ name=$a.name; email=$a.email; active=$false }
    }

    # Populate dropdown panel
    $e.pnlAccList.Children.Clear()
    foreach ($acc in $allAccs) {
        $row = New-Object Windows.Controls.Border
        $row.CornerRadius = [Windows.CornerRadius]::new(4)
        $row.Padding = [Windows.Thickness]::new(6,4,6,4)
        $row.Margin = [Windows.Thickness]::new(0,0,0,2)
        $row.Cursor = 'Hand'
        $bgNormal = if ($acc.active) { "#E0F2E0" } else { "#EDE9DD" }
        $row.Background = Br $bgNormal

        $gridRow = New-Object Windows.Controls.Grid
        $col0 = New-Object Windows.Controls.ColumnDefinition; $col0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $col1 = New-Object Windows.Controls.ColumnDefinition; $col1.Width = [Windows.GridLength]::Auto
        $gridRow.ColumnDefinitions.Add($col0) | Out-Null
        $gridRow.ColumnDefinitions.Add($col1) | Out-Null

        $spLeft = New-Object Windows.Controls.StackPanel
        $spLeft.Orientation = 'Horizontal'
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 6; $dot.Height = 6
        $dot.Fill = if ($acc.active) { Br "#00E676" } else { Br "#FFA000" }
        $dot.Margin = [Windows.Thickness]::new(0,0,5,0)
        $dot.VerticalAlignment = 'Center'
        $spLeft.Children.Add($dot) | Out-Null

        $lbl = New-Object Windows.Controls.TextBlock
        $lbl.Text = "$($acc.name.ToUpper())  [$($acc.email)]"
        $lbl.Foreground = Br "#2E2B23"
        $lbl.FontFamily = [Windows.Media.FontFamily]::new("Consolas")
        $lbl.FontSize = 9
        $lbl.FontWeight = 'Bold'
        $lbl.VerticalAlignment = 'Center'
        $spLeft.Children.Add($lbl) | Out-Null

        if ($acc.active) {
            $badge = New-Object Windows.Controls.Border
            $badge.CornerRadius = [Windows.CornerRadius]::new(2)
            $badge.Background = Br "#2E7D32"
            $badge.Padding = [Windows.Thickness]::new(3,0,3,0)
            $badge.Margin = [Windows.Thickness]::new(6,0,0,0)
            $badge.VerticalAlignment = 'Center'
            $bt = New-Object Windows.Controls.TextBlock
            $bt.Text = "ACTIVE"; $bt.Foreground = Br "#FFFFFF"; $bt.FontSize = 6.5
            $bt.FontFamily = [Windows.Media.FontFamily]::new("Consolas"); $bt.FontWeight = 'Bold'
            $badge.Child = $bt
            $spLeft.Children.Add($badge) | Out-Null
        }
        [Windows.Controls.Grid]::SetColumn($spLeft, 0)
        $gridRow.Children.Add($spLeft) | Out-Null

        # Delete button for non-active accounts
        if (-not $acc.active) {
            $btnDel = New-Object Windows.Controls.Border
            $btnDel.Width = 16; $btnDel.Height = 16
            $btnDel.CornerRadius = [Windows.CornerRadius]::new(3)
            $btnDel.Background = Br "#DCD6C4"
            $btnDel.Margin = [Windows.Thickness]::new(4,0,0,0)
            $btnDel.Cursor = 'Hand'
            $btnDel.ToolTip = "Hapus akun '$($acc.name)'"
            $delTxt = New-Object Windows.Controls.TextBlock
            $delTxt.Text = [char]0x2715
            $delTxt.FontSize = 8; $delTxt.Foreground = Br "#8E8878"
            $delTxt.HorizontalAlignment = 'Center'; $delTxt.VerticalAlignment = 'Center'
            $btnDel.Child = $delTxt

            $btnDel.Add_MouseEnter({ $this.Background = Br "#FFCDD2"; $this.Child.Foreground = Br "#D32F2F" }.GetNewClosure())
            $btnDel.Add_MouseLeave({ $this.Background = Br "#DCD6C4"; $this.Child.Foreground = Br "#8E8878" }.GetNewClosure())

            $delTargetName = $acc.name
            $btnDel.Add_PreviewMouseLeftButtonDown({
                $_.Handled = $true
                $conf = [Windows.MessageBox]::Show(
                    "Hapus akun '$delTargetName' dari AGY RIG?",
                    "Konfirmasi Hapus",
                    [Windows.MessageBoxButton]::YesNo,
                    [Windows.MessageBoxImage]::Warning
                )
                if ($conf -eq [Windows.MessageBoxResult]::Yes) {
                    DelAcc $delTargetName
                    $e.popAcc.IsOpen = $false
                    $e.txSt.Text = "DIHAPUS: $delTargetName"
                    $e.txSt.Foreground = Br "#E65100"
                    Refresh-Widget
                }
            }.GetNewClosure())
            [Windows.Controls.Grid]::SetColumn($btnDel, 1)
            $gridRow.Children.Add($btnDel) | Out-Null
        }

        $row.Child = $gridRow

        # Click handler — select account
        $capturedAcc = $acc
        $row.Add_PreviewMouseLeftButtonDown({
            $script:selectedAccount = $capturedAcc
            $e.txtAccName.Text = "$($capturedAcc.name.ToUpper())  [$($capturedAcc.email)]"
            $e.txtEmail.Text = $capturedAcc.email
            $e.popAcc.IsOpen = $false
            $_.Handled = $true

            # Load cached quota if selecting another account
            $cachedQ = GetAccountQuota $capturedAcc.name
            if ($cachedQ) {
                ApplyQuotaToBars $cachedQ
                $e.txSt.Text = "SELECTED: $($capturedAcc.name.ToUpper())"
                $e.txSt.Foreground = Br "#00838F"
            }
        }.GetNewClosure())

        # Hover effects
        $capturedBg = $bgNormal
        $row.Add_MouseEnter({ $this.Background = Br "#FFE633" }.GetNewClosure())
        $row.Add_MouseLeave({ $this.Background = Br $capturedBg }.GetNewClosure())

        $e.pnlAccList.Children.Add($row) | Out-Null
    }

    # Set initial selection to active account
    if ($allAccs.Count -gt 0) {
        $first = $allAccs[0]
        $script:selectedAccount = $first
        $e.txtAccName.Text = "$($first.name.ToUpper())  [$($first.email)]"
    } else {
        $e.txtAccName.Text = "(belum login)"
    }

    # Email display
    $e.txtEmail.Text = if ($curEmail) { $curEmail } else { "(belum login)" }

    # Status LED
    $e.ledStatus.Fill = if ($curEmail) { Br "#00E676" } else { Br "#FFA000" }
    $e.txtStatus.Text = if ($curEmail) { "ONLINE" } else { "OFFLINE" }
    $e.txtStatus.Foreground = if ($curEmail) { Br "#388E3C" } else { Br "#E65100" }

    # Load local cached quota immediately (< 2ms)
    if ($curName) {
        $localQ = GetAccountQuota $curName
        if ($localQ) { ApplyQuotaToBars $localQ }
    }

    # Trigger non-blocking async quota fetch
    FetchLiveQuotaAsync
}

# ============================================================================
# ASK-NAME DIALOG
# ============================================================================

function AskName([string]$def) {
    $d = New-Object Windows.Window
    $d.Title = "Nama Akun"; $d.Width = 280; $d.Height = 130
    $d.WindowStartupLocation = 'CenterOwner'; $d.Owner = $w
    $d.WindowStyle = 'ToolWindow'; $d.ResizeMode = 'NoResize'
    $d.Background = Br "#E7E2D1"
    $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = [Windows.Thickness]::new(12)
    $lbl = New-Object Windows.Controls.TextBlock; $lbl.Text = "Nama label untuk akun ini:"; $lbl.FontFamily = [Windows.Media.FontFamily]::new("Consolas"); $lbl.FontSize = 10
    $tb = New-Object Windows.Controls.TextBox; $tb.Text = $def; $tb.FontFamily = [Windows.Media.FontFamily]::new("Consolas"); $tb.FontSize = 11; $tb.Margin = [Windows.Thickness]::new(0,6,0,8)
    $btn = New-Object Windows.Controls.Button; $btn.Content = "OK"; $btn.Width = 60; $btn.HorizontalAlignment = 'Right'; $btn.Cursor = 'Hand'
    $btn.Add_Click({ $d.DialogResult = $true; $d.Close() })
    $sp.Children.Add($lbl) | Out-Null; $sp.Children.Add($tb) | Out-Null; $sp.Children.Add($btn) | Out-Null
    $d.Content = $sp
    if ($d.ShowDialog()) { return $tb.Text.Trim() }
    return $null
}

# ============================================================================
# EVENT HANDLERS
# ============================================================================

# Drag ONLY from header row (never blocks buttons or dropdown clicks)
$e.hdrDrag.Add_MouseLeftButtonDown({
    if ($_.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
        try { $w.DragMove() } catch {}
    }
})

# Window controls
$e.btnMin.Add_Click({ $w.WindowState = 'Minimized' })
$e.btnClose.Add_Click({ $w.Close() })

# Pin toggle (Hardware Saklar always-on-top)
$e.chkPin.Add_Checked({
    $w.Topmost = $true
    $e.pinBorder.Background = Br "#FFE633"
    $e.pinBorder.BorderBrush = Br "#B3A220"
    $e.dotPin.Fill = Br "#2E7D32"
    $e.dotPin.HorizontalAlignment = 'Left'
    $e.txtPin.HorizontalAlignment = 'Right'
    $e.txtPin.Text = "ON"
    $e.txtPin.Foreground = Br "#1B5E20"
})
$e.chkPin.Add_Unchecked({
    $w.Topmost = $false
    $e.pinBorder.Background = Br "#C8C2B0"
    $e.pinBorder.BorderBrush = Br "#9E9682"
    $e.dotPin.Fill = Br "#787263"
    $e.dotPin.HorizontalAlignment = 'Right'
    $e.txtPin.HorizontalAlignment = 'Left'
    $e.txtPin.Text = "PIN"
    $e.txtPin.Foreground = Br "#423E33"
})

# Upgrade credits launcher
$openCreditsAction = {
    $uri = if ($script:lastUpgradeUri) { $script:lastUpgradeUri } else { "https://aistudio.google.com/apikey" }
    Start-Process $uri
}
$e.btnUpgrade.Add_Click($openCreditsAction)

# Open/close account dropdown
$e.accSelector.Add_PreviewMouseLeftButtonDown({
    $e.popAcc.IsOpen = -not $e.popAcc.IsOpen
    $_.Handled = $true
})

# Close dropdown when clicking outside
$w.Add_PreviewMouseLeftButtonDown({
    if ($e.popAcc.IsOpen) {
        $pt = $_.GetPosition($e.accSelector)
        $inSel = ($pt.X -ge 0 -and $pt.X -le $e.accSelector.ActualWidth -and
                  $pt.Y -ge 0 -and $pt.Y -le $e.accSelector.ActualHeight)
        if (-not $inSel) {
            $e.popAcc.IsOpen = $false
        }
    }
})

# Arrow indicator on open/close
$e.popAcc.Add_Opened({ if ($e.txtArrow) { $e.txtArrow.Text = [char]0x25B2 } })
$e.popAcc.Add_Closed({ if ($e.txtArrow) { $e.txtArrow.Text = [char]0x25BC } })

# Close popup if window moves
$w.Add_LocationChanged({ if ($e.popAcc.IsOpen) { $e.popAcc.IsOpen = $false } })

# SWITCH — switch primary credential to selected account
$e.btnSwitch.Add_Click({
    $tag = $script:selectedAccount
    if (-not $tag) { $e.txSt.Text = "Pilih akun dulu"; $e.txSt.Foreground = Br "#FFA000"; return }
    if ($tag.active) {
        $e.txSt.Text = "Sudah aktif"; $e.txSt.Foreground = Br "#FFA000"
        return
    }
    $e.txSt.Text = "SWITCHING..."; $e.txSt.Foreground = Br "#FFA000"
    $w.Dispatcher.Invoke([Action]{}, 'Render')
    SwitchTo $tag.name
    $e.txSt.Text = "SWITCHED! Restart AGY untuk efek penuh."
    $e.txSt.Foreground = Br "#00E676"
    Refresh-Widget
})

# PARALEL — launch parallel instance of selected account
$e.btnParalel.Add_Click({
    $tag = $script:selectedAccount
    if (-not $tag) { $e.txSt.Text = "Pilih akun dulu"; $e.txSt.Foreground = Br "#FFA000"; return }
    $e.txSt.Text = "LAUNCHING PARALEL..."; $e.txSt.Foreground = Br "#00838F"
    $w.Dispatcher.Invoke([Action]{}, 'Render')
    LaunchParallel $tag.name
    $e.txSt.Text = "PARALEL LAUNCHED: $($tag.name)"
    $e.txSt.Foreground = Br "#00E676"
})

# LOGIN — OAuth browser login (Fixed & Robust)
$e.btnLoginNew.Add_Click({
    $e.txSt.Text = "BROWSER LOGIN..."; $e.txSt.Foreground = Br "#FFA000"
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
                    email = if ($res.email) { $res.email } else { "(tidak terdeteksi)" }
                    credential = (Enc $res.credential)
                    saved_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                } | ConvertTo-Json -Depth 5
                [IO.File]::WriteAllText((Join-Path $AD "$cleanName.dat"), $accountData, [Text.Encoding]::UTF8)

                $ans = [Windows.MessageBox]::Show(
                    "Akun '$cleanName' ($($res.email)) berhasil disimpan!`n`nApakah ingin langsung SWITCH ke akun ini sekarang?",
                    "Login Berhasil",
                    [Windows.MessageBoxButton]::YesNo,
                    [Windows.MessageBoxImage]::Question
                )
                if ($ans -eq [Windows.MessageBoxResult]::Yes) {
                    SwitchTo $cleanName
                    $e.txSt.Text = "SWITCHED: $cleanName"
                } else {
                    $e.txSt.Text = "SAVED: $cleanName"
                }
                $e.txSt.Foreground = Br "#00E676"
                Refresh-Widget
            }
        } else {
            $e.txSt.Text = "LOGIN CANCELLED / $($res.error)"
            $e.txSt.Foreground = Br "#FFA000"
        }
    } catch {
        $e.txSt.Text = "LOGIN ERROR: $($_.Exception.Message)"
        $e.txSt.Foreground = Br "#C62828"
    }
})

# SIMPAN — save current active session
$e.btnSave.Add_Click({
    $cred = $null
    try { $cred = [AgyCredMgr]::Read("antigravity_google_oauth_credential") } catch {}
    if (-not $cred) {
        $e.txSt.Text = "ERROR: Tidak ada sesi aktif"; $e.txSt.Foreground = Br "#C62828"
        return
    }
    $email = GetEmail $cred
    $name = AskName ($email.Split('@')[0])
    if ($name) {
        SaveCur $name
        $e.txSt.Text = "SAVED: $name"
        $e.txSt.Foreground = Br "#00E676"
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

# Window closing cleanup
$w.Add_Closing({
    try { $autoSyncTimer.Stop() } catch {}
})

# Initial render
$w.Add_ContentRendered({
    Refresh-Widget
})

# ============================================================================
# LAUNCH
# ============================================================================

$w.ShowDialog() | Out-Null
