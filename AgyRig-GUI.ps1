# ============================================================================
# AGY RIG — Compact HUD Dock for Google Antigravity (AGY)
# Crystal Glass Edition: Pre-Launch Live Sync Loading Screen,
# In-Window Pinned Dropdown ("Ketahan"), Transparent Glass & Quota Engine.
# ============================================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Drawing

# ============================================================================
# BACKEND: Credential Manager + DPAPI + Native AGY Quota Fetcher
# ============================================================================

if (-not ([System.Management.Automation.PSTypeName]'AgySwitchCredManager').Type) {
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
        if (!CredRead(target, 1, 0, out credPtr)) return null;
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
        if (!CredRead(target, 1, 0, out credPtr)) return null;
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

    public static bool DeleteCredential(string target) {
        return CredDelete(target, 1, 0);
    }
}

public class Win32WindowHelper {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
"@ -EA Stop
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
    $blob = [AgySwitchCredManager]::ReadCredential($CT)
    if (-not $blob) {
        $blob = [AgySwitchCredManager]::ReadCredential("antigravity_google_oauth_credential")
    }
    return $blob
}

function script:ReadActiveCredUser {
    $u = [AgySwitchCredManager]::ReadCredentialUser($CT)
    if (-not $u) {
        $u = [AgySwitchCredManager]::ReadCredentialUser("antigravity_google_oauth_credential")
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
                $target = $sc.TargetPath
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
                return $target
            }
        }
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
    } catch {}
    return $null
}

function script:Find-AgyBin {
    $cmd = Get-Command "agy.exe" -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command "agy.cmd" -ErrorAction SilentlyContinue }
    if (-not $cmd) { $cmd = Get-Command "agy" -ErrorAction SilentlyContinue }
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:USERPROFILE ".gemini\antigravity\bin\agy.exe"),
        (Join-Path $env:USERPROFILE ".gemini\antigravity-ide\bin\agy.exe"),
        (Join-Path $env:LOCALAPPDATA "agy\bin\agy.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Antigravity\bin\agy.cmd"),
        (Join-Path $env:LOCALAPPDATA "Antigravity\bin\agy.cmd"),
        (Join-Path $env:USERPROFILE "AppData\Local\Programs\Antigravity\bin\agy.cmd")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return "agy.exe"
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
    $qp = Join-Path $CD "$($name.ToLower().Trim())_quota.json"
    $json = $quotaObj | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($qp, $json, [Text.Encoding]::UTF8)
}

function script:GetAccountQuota([string]$name) {
    $qp = Join-Path $CD "$($name.ToLower().Trim())_quota.json"
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

function script:SaveCur([string]$n) {
    $b = ReadActiveCredBlob
    $u = ReadActiveCredUser
    if (!$b) { return "NO_CRED" }
    $em = GetEmail $b
    if (!$em) { $em = "(not detected)" }
    $d = @{
        name = $n.ToLower().Trim()
        user = $u
        email = $em
        credential = (Enc $b)
        saved_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $AD "$($n.ToLower().Trim()).dat"), $d, [Text.Encoding]::UTF8)

    $mp = Join-Path $env:USERPROFILE ".gemini\antigravity\mcp_oauth_tokens.json"
    if (Test-Path $mp) {
        [IO.File]::WriteAllText((Join-Path $AD "$($n.ToLower().Trim())_mcp.dat"), (Enc(Get-Content $mp -Raw)), [Text.Encoding]::UTF8)
    }
    [IO.File]::WriteAllText($AF, $n.ToLower().Trim(), [Text.Encoding]::UTF8)

    return "OK:$em"
}

function script:SwitchTo([string]$n) {
    $cleanName = $n.ToLower().Trim()
    $ap = Join-Path $AD "$cleanName.dat"
    if (!(Test-Path $ap)) { return "NOT_FOUND" }
    $ac = Get-Content $ap -Raw | ConvertFrom-Json
    try { $b = Dec $ac.credential } catch { return "FAIL" }
    $u = if ($ac.user) { $ac.user } else { "antigravity" }
    if (!([AgySwitchCredManager]::WriteCredential($CT, $u, $b))) { return "FAIL" }

    $mb = Join-Path $AD "$($cleanName)_mcp.dat"
    $mt = Join-Path $env:USERPROFILE ".gemini\antigravity\mcp_oauth_tokens.json"
    if (Test-Path $mb) {
        try { [IO.File]::WriteAllText($mt, (Dec(Get-Content $mb -Raw)), [Text.Encoding]::UTF8) } catch {}
    }
    [IO.File]::WriteAllText($AF, $cleanName, [Text.Encoding]::UTF8)

    # Restart primary Antigravity
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

    # Auto-save active account if missing .dat file
    if (!(Test-Path $ap)) {
        $curBlob = ReadActiveCredBlob
        if ($curBlob) {
            SaveCur $cleanName | Out-Null
        }
    }

    if (!(Test-Path $ap)) { return "NOT_FOUND" }
    $ac = Get-Content $ap -Raw | ConvertFrom-Json
    try { $targetBlob = Dec $ac.credential } catch { return "FAIL_DECRYPT" }
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

    [AgySwitchCredManager]::WriteCredential($CT, $targetUser, $targetBlob) | Out-Null

    Start-Process $exe -ArgumentList "--user-data-dir=`"$userDir`""

    $mb = Join-Path $AD "$($cleanName)_mcp.dat"
    $mt = Join-Path $env:USERPROFILE ".gemini\antigravity\mcp_oauth_tokens.json"
    if (Test-Path $mb) {
        try { [IO.File]::WriteAllText($mt, (Dec(Get-Content $mb -Raw)), [Text.Encoding]::UTF8) } catch {}
    }

    # Restore original credential after 5 seconds via DispatcherTimer
    if ($curBlob -and ($curBlob -ne $targetBlob)) {
        $restoreTimer = New-Object Windows.Threading.DispatcherTimer
        $restoreTimer.Interval = [TimeSpan]::FromSeconds(5)
        $restoreTimer.Add_Tick({
            $restoreTimer.Stop()
            [AgySwitchCredManager]::WriteCredential($CT, $curUser, $curBlob) | Out-Null
        })
        $restoreTimer.Start()
    }

    # Desktop shortcut
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
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($sh) | Out-Null
    } catch {}

    return "OK"
}

function script:DelAcc([string]$n) {
    $cleanName = $n.ToLower().Trim()
    $ap = Join-Path $AD "$cleanName.dat"
    if (Test-Path $ap) { Remove-Item $ap -Force }
    $mp = Join-Path $AD "$($cleanName)_mcp.dat"
    if (Test-Path $mp) { Remove-Item $mp -Force }
    $qp = Join-Path $CD "$($cleanName)_quota.json"
    if (Test-Path $qp) { Remove-Item $qp -Force }
    if ((Test-Path $AF) -and ((Get-Content $AF -Raw).Trim() -eq $cleanName)) { Remove-Item $AF -Force }
}

# ============================================================================
# GUI XAML (CRYSTAL GLASS + SPLASH LOADING SCREEN + PINNED IN-WINDOW DROPDOWN)
# ============================================================================

$xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  Title="AGY RIG" Width="388" Height="228"
  WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
  Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="True" Topmost="False"
  TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType"
  RenderOptions.BitmapScalingMode="HighQuality" RenderOptions.ClearTypeHint="Enabled"
  SnapsToDevicePixels="True" UseLayoutRounding="True">

  <Window.Resources>
    <!-- Completely transparent button style - Stretches contents to fill column with zero default white boxes! -->
    <Style TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Margin" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="VerticalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}"
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
                <Setter Property="Opacity" Value="0.60"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ToggleButton">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border Background="Transparent" SnapsToDevicePixels="True">
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

  <!-- Outer Glass Frame: Translucent Dark Slate with Subtle Ice-Blue Luminous Edge -->
  <Border CornerRadius="14" Background="#500A0F1A" BorderBrush="#607898B8" BorderThickness="1.2"
          Margin="10" Padding="14,11" SnapsToDevicePixels="True" UseLayoutRounding="True">
    <Border.Effect>
      <DropShadowEffect Color="#000000" BlurRadius="22" ShadowDepth="4" Opacity="0.60" Direction="270"/>
    </Border.Effect>

    <Grid>
      <!-- ======================================================== -->
      <!-- VIEW 1: PRE-LAUNCH LOADING SPLASH (SYNCING TELEMETRY)   -->
      <!-- ======================================================== -->
      <Grid x:Name="viewLoading" Visibility="Visible">
        <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,10">
            <Border Width="22" Height="22" Background="#35FFFFFF" BorderBrush="#60FFFFFF" BorderThickness="1" CornerRadius="5" Margin="0,0,8,0">
              <TextBlock Text="&#x25B2;" Foreground="#FFE633" FontSize="11" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,1,0,0"/>
            </Border>
            <TextBlock Text="AGY RIG" Foreground="#FFFFFF" FontSize="16" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          </StackPanel>

          <TextBlock x:Name="txtLoadingStep" Text="Synchronizing accounts &amp; model quotas..." Foreground="#00E5FF" FontSize="9.5" FontWeight="Bold" FontFamily="Consolas" HorizontalAlignment="Center" Margin="0,0,0,12"/>

          <!-- Animated Loading Progress Bar -->
          <Border Width="260" Height="6" Background="#25FFFFFF" CornerRadius="3" BorderBrush="#40FFFFFF" BorderThickness="1" SnapsToDevicePixels="True">
            <Border x:Name="barLoading" Width="30" Height="4" Background="#00E5FF" CornerRadius="2" HorizontalAlignment="Left"/>
          </Border>

          <TextBlock x:Name="txtLoadingSub" Text="CONNECTING TO ANTIGRAVITY ENGINE..." Foreground="#90A4AE" FontSize="7.5" FontWeight="SemiBold" FontFamily="Consolas" HorizontalAlignment="Center" Margin="0,10,0,0"/>
        </StackPanel>
      </Grid>

      <!-- ======================================================== -->
      <!-- VIEW 2: MAIN DASHBOARD HUD                              -->
      <!-- ======================================================== -->
      <Grid x:Name="viewMain" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="22"/>   <!-- 0: Header -->
          <RowDefinition Height="5"/>    <!-- 1: Spacer -->
          <RowDefinition Height="28"/>   <!-- 2: Selector + Buttons -->
          <RowDefinition Height="4"/>    <!-- 3: Spacer -->
          <RowDefinition Height="16"/>   <!-- 4: Email + Credits -->
          <RowDefinition Height="5"/>    <!-- 5: Spacer -->
          <RowDefinition Height="42"/>   <!-- 6: Quota Bars -->
          <RowDefinition Height="5"/>    <!-- 7: Spacer -->
          <RowDefinition Height="26"/>   <!-- 8: Action Buttons -->
          <RowDefinition Height="5"/>    <!-- 9: Spacer -->
          <RowDefinition Height="20"/>   <!-- 10: Status Bar -->
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

          <!-- Brand Title -->
          <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
            <Border Width="16" Height="16" Background="#35FFFFFF" BorderBrush="#60FFFFFF" BorderThickness="1" CornerRadius="4" Margin="0,0,6,0">
              <TextBlock Text="&#x25B2;" Foreground="#FFE633" FontSize="8" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,1,0,0"/>
            </Border>
            <TextBlock Text="AGY RIG" Foreground="#FFFFFF" FontSize="11" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          </StackPanel>

          <!-- Center Status -->
          <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
            <Ellipse x:Name="ledStatus" Width="6" Height="6" Fill="#00FF88" Margin="0,0,4,0"/>
            <TextBlock x:Name="txtStatus" Text="ONLINE" Foreground="#00FF88" FontSize="8" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
          </StackPanel>

          <!-- Pin Toggle -->
          <ToggleButton x:Name="chkPin" Grid.Column="2" VerticalAlignment="Center" Margin="0,0,5,0" ToolTip="Toggle Always-on-Top (Pin)">
            <Border x:Name="pinBorder" CornerRadius="8" Background="#35FFFFFF" BorderBrush="#60FFFFFF" BorderThickness="1"
                    Width="42" Height="16" SnapsToDevicePixels="True">
              <Grid Margin="3,0">
                <Ellipse x:Name="dotPin" Width="10" Height="10" Fill="#C0FFFFFF" HorizontalAlignment="Left" VerticalAlignment="Center"/>
                <TextBlock x:Name="txtPin" Text="PIN" FontSize="6.5" FontWeight="Bold" FontFamily="Consolas" Foreground="#FFFFFF"
                           HorizontalAlignment="Right" VerticalAlignment="Center"/>
              </Grid>
            </Border>
          </ToggleButton>

          <!-- Window Min & Close -->
          <Button x:Name="btnMin" Grid.Column="3" Width="20" Height="16" Margin="0,0,4,0" ToolTip="Minimize">
            <Border CornerRadius="4" Background="#30FFFFFF" BorderBrush="#50FFFFFF" BorderThickness="1">
              <TextBlock Text="&#x2014;" FontSize="8" Foreground="#E0E0E0" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/>
            </Border>
          </Button>
          <Button x:Name="btnClose" Grid.Column="4" Width="20" Height="16" ToolTip="Close">
            <Border CornerRadius="4" Background="#E53935" BorderThickness="0">
              <TextBlock Text="&#x2715;" FontSize="7.5" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
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

          <!-- Account Dropdown Trigger Button -->
          <Border x:Name="accSelector" Grid.Column="0" CornerRadius="6" Background="#35FFFFFF"
                  BorderBrush="#70FFFFFF" BorderThickness="1" Padding="8,4" Cursor="Hand" ToolTip="Click to select account profile"
                  Height="28" SnapsToDevicePixels="True">
            <Grid>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,16,0">
                <Ellipse x:Name="dotSelected" Width="7" Height="7" Fill="#00FF88" Margin="0,0,6,0"/>
                <TextBlock x:Name="txtAccName" Text="(select profile)" Foreground="#FFFFFF"
                           FontFamily="Consolas" FontSize="9.5" FontWeight="Bold" VerticalAlignment="Center"
                           TextTrimming="CharacterEllipsis"/>
              </StackPanel>
              <TextBlock x:Name="txtArrow" Text="&#x25BC;" Foreground="#00E5FF" FontSize="8.5"
                         HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
          </Border>

          <!-- SWITCH Button -->
          <Button x:Name="btnSwitch" Grid.Column="1" Margin="5,0,0,0" ToolTip="Switch primary Antigravity session to this profile" Height="28">
            <Border CornerRadius="6" Background="#E65100" Padding="12,5">
              <TextBlock Text="SWITCH" Foreground="#FFFFFF" FontSize="8.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
            </Border>
          </Button>

          <!-- PARALLEL / FOCUS Button (Always clearly visible & distinct!) -->
          <Button x:Name="btnParalel" Grid.Column="2" Margin="5,0,0,0" ToolTip="Launch or focus parallel Antigravity instance" Height="28" MinWidth="82">
            <Border x:Name="brdParalel" CornerRadius="6" Background="#00838F" Padding="10,5">
              <TextBlock x:Name="txtParalelBtn" Text="&#x26A1; PARALLEL" Foreground="#FFFFFF" FontSize="8.5" FontWeight="Bold" FontFamily="Consolas" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </Button>
        </Grid>

        <!-- ROW 4: EMAIL + CREDITS -->
        <Grid Grid.Row="4">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="txtEmail" Grid.Column="0" Text="..." Foreground="#ECEFF1" FontSize="8.5" FontWeight="SemiBold" FontFamily="Consolas"
                     VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,8,0"/>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="txtCredits" Text="0" Foreground="#00E5FF" FontSize="9.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
            <TextBlock Text=" CR" Foreground="#00E5FF" FontSize="7.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" Opacity="0.9"/>
            <Button x:Name="btnUpgrade" Margin="4,0,0,0" ToolTip="Purchase credits / AI Studio" VerticalAlignment="Center">
              <Border CornerRadius="3" Background="#4000E5FF" BorderBrush="#8000E5FF" BorderThickness="1" Padding="5,1">
                <TextBlock Text="&#x2197;" Foreground="#FFFFFF" FontSize="8" FontWeight="Bold" VerticalAlignment="Center"/>
              </Border>
            </Button>
          </StackPanel>
        </Grid>

        <!-- ROW 6: QUOTA BARS (Crystal Glass Tray) -->
        <Border Grid.Row="6" Background="#28000000" BorderBrush="#25FFFFFF" BorderThickness="1" CornerRadius="6" Padding="6,2">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="12"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="18"/>
              <RowDefinition Height="18"/>
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
              <Grid Grid.Column="1" Margin="2,3" ToolTip="Gemini 5-hour quota">
                <Border Background="#35FFFFFF" CornerRadius="3"/>
                <Border x:Name="barG5h" Background="#FF7043" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
              </Grid>
              <TextBlock x:Name="txtG5hVal" Grid.Column="2" Text="--%" Foreground="#FFFFFF" FontSize="8" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
              <TextBlock x:Name="txtRstG5h" Grid.Column="3" Text="--" Foreground="#CFD8DC" FontSize="7.5" FontWeight="SemiBold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
            </Grid>

            <!-- C-5H -->
            <Grid Grid.Row="0" Grid.Column="2">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="28"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="26"/>
                <ColumnDefinition Width="42"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="C-5H" Foreground="#00E5FF" FontSize="7.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
              <Grid Grid.Column="1" Margin="2,3" ToolTip="Claude 5-hour quota">
                <Border Background="#35FFFFFF" CornerRadius="3"/>
                <Border x:Name="barC5h" Background="#00E5FF" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
              </Grid>
              <TextBlock x:Name="txtC5hVal" Grid.Column="2" Text="--%" Foreground="#FFFFFF" FontSize="8" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
              <TextBlock x:Name="txtRstC5h" Grid.Column="3" Text="--" Foreground="#CFD8DC" FontSize="7.5" FontWeight="SemiBold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
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
              <Grid Grid.Column="1" Margin="2,3" ToolTip="Gemini weekly quota">
                <Border Background="#35FFFFFF" CornerRadius="3"/>
                <Border x:Name="barGWk" Background="#FFA726" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
              </Grid>
              <TextBlock x:Name="txtGWkVal" Grid.Column="2" Text="--%" Foreground="#FFFFFF" FontSize="8" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
              <TextBlock x:Name="txtRstGWk" Grid.Column="3" Text="--" Foreground="#CFD8DC" FontSize="7.5" FontWeight="SemiBold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
            </Grid>

            <!-- C-WK -->
            <Grid Grid.Row="1" Grid.Column="2">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="28"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="26"/>
                <ColumnDefinition Width="42"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="C-WK" Foreground="#00E5FF" FontSize="7.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
              <Grid Grid.Column="1" Margin="2,3" ToolTip="Claude weekly quota">
                <Border Background="#35FFFFFF" CornerRadius="3"/>
                <Border x:Name="barCWk" Background="#00E5FF" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
              </Grid>
              <TextBlock x:Name="txtCWkVal" Grid.Column="2" Text="--%" Foreground="#FFFFFF" FontSize="8" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right"/>
              <TextBlock x:Name="txtRstCWk" Grid.Column="3" Text="--" Foreground="#CFD8DC" FontSize="7.5" FontWeight="SemiBold" FontFamily="Consolas" VerticalAlignment="Center" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
            </Grid>
          </Grid>
        </Border>

        <!-- ROW 8: ACTION BUTTONS (Symmetrical Frosted Glass Buttons) -->
        <Grid Grid.Row="8">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="5"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="5"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <Button x:Name="btnLoginNew" Grid.Column="0" ToolTip="Sign in new Google account via OAuth PKCE">
            <Border CornerRadius="6" Background="#0077B6" Padding="2,4">
              <TextBlock Text="+ LOGIN" Foreground="#FFFFFF" FontSize="8.5" FontWeight="Bold" FontFamily="Consolas" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </Button>

          <Button x:Name="btnSave" Grid.Column="2" ToolTip="Save currently active session as profile">
            <Border CornerRadius="6" Background="#E65100" Padding="2,4">
              <TextBlock Text="+ SAVE" Foreground="#FFFFFF" FontSize="8.5" FontWeight="Bold" FontFamily="Consolas" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </Button>

          <Button x:Name="btnRef" Grid.Column="4" ToolTip="Sync live model limits and quota">
            <Border CornerRadius="6" Background="#30FFFFFF" BorderBrush="#50FFFFFF" BorderThickness="1" Padding="2,4">
              <TextBlock Text="&#x21BB; SYNC" Foreground="#FFFFFF" FontSize="8.5" FontWeight="Bold" FontFamily="Consolas" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </Button>
        </Grid>

        <!-- ROW 10: STATUS BAR -->
        <Border Grid.Row="10" Background="#25000000" BorderBrush="#25FFFFFF" BorderThickness="1" CornerRadius="5" Padding="8,1">
          <TextBlock x:Name="txSt" Text="READY" Foreground="#00FF88" FontSize="7.5" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </Border>

        <!-- ======================================================== -->
        <!-- IN-WINDOW DROPDOWN TRAY (100% "KETAHAN", NEVER DROPS!)   -->
        <!-- ======================================================== -->
        <Border x:Name="dropOverlay" Grid.Row="3" Grid.RowSpan="8" Panel.ZIndex="100"
                Visibility="Collapsed" CornerRadius="8"
                Background="#F40A0F1A" BorderBrush="#607898B8" BorderThickness="1.2"
                Margin="0,2,0,0" Padding="6,6" SnapsToDevicePixels="True">
          <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="20" ShadowDepth="4" Opacity="0.80" Direction="270"/>
          </Border.Effect>
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="20"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- Dropdown Title + Close Button -->
            <Grid Grid.Row="0" Margin="4,0,4,4">
              <TextBlock Text="SAVED PROFILES" Foreground="#00E5FF" FontSize="8" FontWeight="Bold" FontFamily="Consolas" VerticalAlignment="Center"/>
              <Button x:Name="btnCloseDropdown" HorizontalAlignment="Right" Width="20" Height="18" Cursor="Hand" ToolTip="Close list">
                <Border CornerRadius="3" Background="#30FFFFFF">
                  <TextBlock Text="&#x2715;" FontSize="8" Foreground="#B0BEC5" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
              </Button>
            </Grid>

            <!-- Accounts ScrollViewer -->
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="pnlAccList"/>
            </ScrollViewer>
          </Grid>
        </Border>

      </Grid>
    </Grid>
  </Border>
</Window>
'@

[xml]$xaml = $xamlStr
$r = New-Object Xml.XmlNodeReader $xaml
$w = [Windows.Markup.XamlReader]::Load($r)

# Icon
if (Test-Path $ICON_PATH) {
    try { $w.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($ICON_PATH)) } catch {}
}

# Wire elements
$ns = New-Object Xml.XmlNamespaceManager $xaml.NameTable
$ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
$nodes = $xaml.SelectNodes('//*[@x:Name]', $ns)
$e = @{}
foreach ($node in $nodes) {
    $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    $e[$name] = $w.FindName($name)
}

# ============================================================================
# BRUSH CACHE
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

$brushGreen  = Br "#00FF88"
$brushOrange = Br "#FFA726"
$brushRed    = Br "#EF5350"

function GetBarBrush([double]$f) {
    if ($f -gt 0.5) { $brushGreen } elseif ($f -gt 0.2) { $brushOrange } else { $brushRed }
}

$script:lastUpgradeUri = $null
$script:selectedAccount = $null
$script:isFetchingQuota = $false

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
# FETCH LIVE QUOTA ENGINE
# ============================================================================

function FetchLiveQuotaSync([string]$cliPath) {
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
}

# ============================================================================
# BUTTONS STATE HELPER
# ============================================================================

function script:Update-ActionButtons($acc, $preloadedProcs = $null) {
    if (-not $acc) { return }
    $activeProcs = if ($preloadedProcs -ne $null) { $preloadedProcs } else { Get-ParallelProcesses }
    $isParallelRunning = [bool]($activeProcs | Where-Object { $_.IsParallel -and ($_.ProfileName -eq $acc.name.ToLower().Trim()) })

    if ($e.txtParalelBtn -and $e.brdParalel) {
        if ($isParallelRunning) {
            $e.txtParalelBtn.Text = [char]0x26A1 + " FOCUS"
            $e.brdParalel.Background = Br "#00897B"
            $e.btnParalel.ToolTip = "Bring running parallel instance for '$($acc.name)' to front"
        } else {
            $e.txtParalelBtn.Text = [char]0x26A1 + " PARALLEL"
            $e.brdParalel.Background = Br "#00838F"
            $e.btnParalel.ToolTip = "Launch isolated parallel Antigravity instance for '$($acc.name)'"
        }
    }

    if ($e.btnSwitch) {
        if ($acc.active) {
            $e.btnSwitch.Opacity = 0.55
            $e.btnSwitch.ToolTip = "This profile is already active"
        } else {
            $e.btnSwitch.Opacity = 1.0
            $e.btnSwitch.ToolTip = "Switch primary Antigravity session to '$($acc.name)'"
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
    if (Test-Path $AF) { $curName = (Get-Content $AF -Raw).Trim() }

    $activeProcs = Get-ParallelProcesses

    # Find which saved account matches the active credential
    $saved = LoadAccs
    $allAccs = @()

    $activeDn = ""
    if ($curEmail) {
        $matchedSaved = $saved | Where-Object { $_.email -eq $curEmail }
        if ($matchedSaved) {
            $activeDn = $matchedSaved.name
        } elseif ($curName) {
            $activeDn = $curName
        } else {
            $activeDn = $curEmail.Split('@')[0]
        }
        $allAccs += [PSCustomObject]@{ name=$activeDn; email=$curEmail; active=$true; status="PRIMARY" }
    }

    foreach ($a in $saved) {
        if ($curEmail -and ($a.email -eq $curEmail -or $a.name.ToLower() -eq $activeDn.ToLower())) { continue }
        $isRun = [bool]($activeProcs | Where-Object { $_.IsParallel -and ($_.ProfileName -eq $a.name.ToLower()) })
        $st = if ($isRun) { "RUNNING" } else { "IDLE" }
        $allAccs += [PSCustomObject]@{ name=$a.name; email=$a.email; active=$false; status=$st }
    }

    # Populate dropdown panel
    $e.pnlAccList.Children.Clear()
    foreach ($acc in $allAccs) {
        $row = New-Object Windows.Controls.Border
        $row.CornerRadius = [Windows.CornerRadius]::new(6)
        $row.Padding = [Windows.Thickness]::new(8,6,8,6)
        $row.Margin = [Windows.Thickness]::new(0,0,0,3)
        $row.Cursor = 'Hand'
        $bgNormal = if ($acc.active) { "#3500E5FF" } elseif ($acc.status -eq "RUNNING") { "#2500B4D8" } else { "#18FFFFFF" }
        $row.Background = Br $bgNormal

        $gridRow = New-Object Windows.Controls.Grid
        $cDot   = New-Object Windows.Controls.ColumnDefinition; $cDot.Width   = [Windows.GridLength]::Auto
        $cName  = New-Object Windows.Controls.ColumnDefinition; $cName.Width  = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $cBadge = New-Object Windows.Controls.ColumnDefinition; $cBadge.Width = [Windows.GridLength]::Auto
        $cDel   = New-Object Windows.Controls.ColumnDefinition; $cDel.Width   = [Windows.GridLength]::Auto
        $gridRow.ColumnDefinitions.Add($cDot)   | Out-Null
        $gridRow.ColumnDefinitions.Add($cName)  | Out-Null
        $gridRow.ColumnDefinitions.Add($cBadge) | Out-Null
        $gridRow.ColumnDefinitions.Add($cDel)   | Out-Null

        # Col 0: Dot
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 7; $dot.Height = 7
        $dot.Fill = if ($acc.active) { Br "#00FF88" } elseif ($acc.status -eq "RUNNING") { Br "#00E5FF" } else { Br "#78909C" }
        $dot.Margin = [Windows.Thickness]::new(0,0,7,0)
        $dot.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($dot, 0)
        $gridRow.Children.Add($dot) | Out-Null

        # Col 1: Label
        $lbl = New-Object Windows.Controls.TextBlock
        $lbl.Text = "$($acc.name.ToUpper())  $($acc.email)"
        $lbl.Foreground = Br "#FFFFFF"
        $lbl.FontFamily = [Windows.Media.FontFamily]::new("Consolas")
        $lbl.FontSize = 9.5; $lbl.FontWeight = 'Bold'; $lbl.VerticalAlignment = 'Center'
        $lbl.TextTrimming = 'CharacterEllipsis'
        $lbl.Margin = [Windows.Thickness]::new(0,0,6,0)
        [Windows.Controls.Grid]::SetColumn($lbl, 1)
        $gridRow.Children.Add($lbl) | Out-Null

        # Col 2: Badge
        $badge = New-Object Windows.Controls.Border
        $badge.CornerRadius = [Windows.CornerRadius]::new(3)
        $badge.Padding = [Windows.Thickness]::new(5,2,5,2)
        $badge.VerticalAlignment = 'Center'
        $bt = New-Object Windows.Controls.TextBlock
        $bt.Foreground = Br "#FFFFFF"; $bt.FontSize = 6.5
        $bt.FontFamily = [Windows.Media.FontFamily]::new("Consolas"); $bt.FontWeight = 'Bold'

        if ($acc.active) {
            $badge.Background = Br "#802E7D32"; $bt.Text = "ACTIVE"
        } elseif ($acc.status -eq "RUNNING") {
            $badge.Background = Br "#8000838F"; $bt.Text = "RUNNING"
        } else {
            $badge.Background = Br "#50607D8B"; $bt.Text = "IDLE"
        }
        $badge.Child = $bt
        [Windows.Controls.Grid]::SetColumn($badge, 2)
        $gridRow.Children.Add($badge) | Out-Null

        # Col 3: Delete button
        if (-not $acc.active) {
            $btnDel = New-Object Windows.Controls.Border
            $btnDel.Width = 20; $btnDel.Height = 20
            $btnDel.CornerRadius = [Windows.CornerRadius]::new(4)
            $btnDel.Background = Br "#25FFFFFF"
            $btnDel.Margin = [Windows.Thickness]::new(6,0,0,0)
            $btnDel.Cursor = 'Hand'
            $btnDel.VerticalAlignment = 'Center'
            $btnDel.ToolTip = "Delete profile '$($acc.name)'"
            $delTxt = New-Object Windows.Controls.TextBlock
            $delTxt.Text = [char]0x2715
            $delTxt.FontSize = 8; $delTxt.Foreground = Br "#90A4AE"
            $delTxt.HorizontalAlignment = 'Center'; $delTxt.VerticalAlignment = 'Center'
            $btnDel.Child = $delTxt

            $btnDel.Add_MouseEnter({ $this.Background = Br "#D5E53935"; $this.Child.Foreground = Br "#FFFFFF" }.GetNewClosure())
            $btnDel.Add_MouseLeave({ $this.Background = Br "#25FFFFFF"; $this.Child.Foreground = Br "#90A4AE" }.GetNewClosure())

            $delTargetName = $acc.name
            $btnDel.Add_PreviewMouseLeftButtonDown({
                $_.Handled = $true
                $conf = [Windows.MessageBox]::Show(
                    "Delete profile '$delTargetName' from AGY RIG?",
                    "Confirm Delete",
                    [Windows.MessageBoxButton]::YesNo,
                    [Windows.MessageBoxImage]::Warning
                )
                if ($conf -eq [Windows.MessageBoxResult]::Yes) {
                    DelAcc $delTargetName
                    $e.dropOverlay.Visibility = 'Collapsed'
                    $e.txtArrow.Text = [char]0x25BC
                    $e.txSt.Text = "DELETED: $delTargetName"
                    $e.txSt.Foreground = Br "#FFA726"
                    Refresh-Widget
                }
            }.GetNewClosure())
            [Windows.Controls.Grid]::SetColumn($btnDel, 3)
            $gridRow.Children.Add($btnDel) | Out-Null
        }

        $row.Child = $gridRow

        # Click to select account
        $capturedAcc = $acc
        $row.Add_PreviewMouseLeftButtonDown({
            $script:selectedAccount = $capturedAcc
            $e.txtAccName.Text = $capturedAcc.name.ToUpper()
            $e.txtEmail.Text = $capturedAcc.email
            $e.dotSelected.Fill = if ($capturedAcc.active) { Br "#00FF88" } elseif ($capturedAcc.status -eq "RUNNING") { Br "#00E5FF" } else { Br "#78909C" }
            
            # Hide in-window dropdown tray
            $e.dropOverlay.Visibility = 'Collapsed'
            $e.txtArrow.Text = [char]0x25BC
            $_.Handled = $true

            Update-ActionButtons $capturedAcc

            $cachedQ = GetAccountQuota $capturedAcc.name
            if ($cachedQ) {
                ApplyQuotaToBars $cachedQ
                $e.txSt.Text = "SELECTED: $($capturedAcc.name.ToUpper())"
                $e.txSt.Foreground = Br "#00E5FF"
            }
        }.GetNewClosure())

        # Hover
        $capturedBg = $bgNormal
        $row.Add_MouseEnter({ $this.Background = Br "#40FFFFFF" }.GetNewClosure())
        $row.Add_MouseLeave({ $this.Background = Br $capturedBg }.GetNewClosure())

        $e.pnlAccList.Children.Add($row) | Out-Null
    }

    # Initial selection
    if ($allAccs.Count -gt 0) {
        $first = $allAccs[0]
        $script:selectedAccount = $first
        $e.txtAccName.Text = $first.name.ToUpper()
        $e.txtEmail.Text = $first.email
        $e.dotSelected.Fill = if ($first.active) { Br "#00FF88" } elseif ($first.status -eq "RUNNING") { Br "#00E5FF" } else { Br "#78909C" }
        Update-ActionButtons $first $activeProcs
    } else {
        $e.txtAccName.Text = "(not logged in)"
        $e.txtEmail.Text = "(no active session)"
    }

    # Status LED
    $e.ledStatus.Fill = if ($curEmail) { Br "#00FF88" } else { Br "#FFA726" }
    $e.txtStatus.Text = if ($curEmail) { "ONLINE" } else { "OFFLINE" }
    $e.txtStatus.Foreground = if ($curEmail) { Br "#00FF88" } else { Br "#FFA726" }

    # Load local cached quota immediately (< 2ms)
    $cachedQ = $null
    if ($script:selectedAccount) { $cachedQ = GetAccountQuota $script:selectedAccount.name }
    if (-not $cachedQ -and $curName) { $cachedQ = GetAccountQuota $curName }
    if ($cachedQ) {
        ApplyQuotaToBars $cachedQ
        $e.txSt.Text = "ONLINE"
        $e.txSt.Foreground = Br "#00FF88"
    }
}

# ============================================================================
# PRE-LAUNCH SPLASH SYNC ROUTINE
# ============================================================================

function StartPreLaunchSync {
    $e.viewLoading.Visibility = 'Visible'
    $e.viewMain.Visibility = 'Collapsed'
    $e.barLoading.Width = 30
    $e.txtLoadingStep.Text = "Scanning local credential vault..."
    $e.txtLoadingSub.Text = "STEP 1/3 // SCANNING PROFILES"

    # Pre-render local accounts and cached quota immediately (< 2ms)
    Refresh-Widget

    $script:syncState = @{
        cliBin      = (Find-AgyBin)
        bgPs        = [powershell]::Create()
        asyncHandle = $null
        ticks       = 0
        timer       = (New-Object Windows.Threading.DispatcherTimer)
    }

    $script:syncState.bgPs.AddScript({
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
    }).AddArgument($script:syncState.cliBin) | Out-Null

    $script:syncState.asyncHandle = $script:syncState.bgPs.BeginInvoke()
    $script:syncState.timer.Interval = [TimeSpan]::FromMilliseconds(100)

    $script:syncState.timer.Add_Tick({
        $script:syncState.ticks++
        $t = $script:syncState.ticks

        if ($t -lt 12) {
            $e.barLoading.Width = [math]::Min(110, 30 + ($t * 7))
            $binName = if ($script:syncState.cliBin) { [IO.Path]::GetFileName($script:syncState.cliBin) } else { "agy.exe" }
            $e.txtLoadingStep.Text = "Connecting to Antigravity CLI ($binName)..."
            $e.txtLoadingSub.Text = "STEP 1/3 // CONNECTING"
        } elseif ($t -lt 28) {
            $e.barLoading.Width = [math]::Min(210, 110 + (($t - 12) * 6))
            $e.txtLoadingStep.Text = "Synchronizing Gemini & Claude live limits..."
            $e.txtLoadingSub.Text = "STEP 2/3 // SYNCING QUOTA"
        } else {
            $e.barLoading.Width = [math]::Min(255, 210 + (($t - 28) * 3))
            $e.txtLoadingStep.Text = "Synchronizing credits & active profiles..."
            $e.txtLoadingSub.Text = "STEP 3/3 // FINALIZING"
        }

        # Complete when async returns or after 45 ticks (4.5s max timeout)
        if ($script:syncState.asyncHandle.IsCompleted -or $script:syncState.ticks -ge 45) {
            $script:syncState.timer.Stop()
            try {
                if ($script:syncState.asyncHandle.IsCompleted) {
                    $res = $script:syncState.bgPs.EndInvoke($script:syncState.asyncHandle)
                    if ($res -and $res.Count -gt 0 -and $res[0].success) {
                        $liveQ = $res[0]
                        ApplyQuotaToBars $liveQ
                        if ($script:selectedAccount) {
                            SaveAccountQuota $script:selectedAccount.name $liveQ
                        }
                    }
                }
            } catch {}
            finally {
                $script:syncState.bgPs.Dispose()
            }

            # Update dashboard state
            Refresh-Widget
            $e.barLoading.Width = 260
            $e.txtLoadingStep.Text = "Synchronized! Opening dashboard..."
            $e.txtLoadingSub.Text = "STATUS: COMPLETE"

            $e.viewLoading.Visibility = 'Collapsed'
            $e.viewMain.Visibility = 'Visible'
        }
    })
    $script:syncState.timer.Start()
}

# ============================================================================
# BACKGROUND SYNC (FOR ↻ SYNC BUTTON WITHOUT BLOCKING MAIN VIEW)
# ============================================================================

function FetchLiveQuotaAsync {
    if ($script:isFetchingQuota) { return }
    $script:isFetchingQuota = $true

    $e.txSt.Text = "SYNCING..."
    $e.txSt.Foreground = Br "#FFA726"

    $script:bgState = @{
        cliBin      = (Find-AgyBin)
        bgPs        = [powershell]::Create()
        asyncHandle = $null
        ticks       = 0
        timer       = (New-Object Windows.Threading.DispatcherTimer)
    }

    $script:bgState.bgPs.AddScript({
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
    }).AddArgument($script:bgState.cliBin) | Out-Null

    $script:bgState.asyncHandle = $script:bgState.bgPs.BeginInvoke()
    $script:bgState.timer.Interval = [TimeSpan]::FromMilliseconds(200)

    $script:bgState.timer.Add_Tick({
        $script:bgState.ticks++
        if ($script:bgState.asyncHandle.IsCompleted -or $script:bgState.ticks -ge 50) {
            $script:bgState.timer.Stop()
            try {
                if ($script:bgState.asyncHandle.IsCompleted) {
                    $res = $script:bgState.bgPs.EndInvoke($script:bgState.asyncHandle)
                    if ($res -and $res.Count -gt 0 -and $res[0].success) {
                        $liveQ = $res[0]
                        ApplyQuotaToBars $liveQ
                        if ($script:selectedAccount) {
                            SaveAccountQuota $script:selectedAccount.name $liveQ
                        }
                        $e.txSt.Text = "ONLINE // $(Get-Date -Format 'HH:mm:ss')"
                        $e.txSt.Foreground = Br "#00FF88"
                    } else {
                        $e.txSt.Text = "OFFLINE // Check CLI"
                        $e.txSt.Foreground = Br "#FFA726"
                    }
                } else {
                    $e.txSt.Text = "SYNC TIMEOUT"
                    $e.txSt.Foreground = Br "#FFA726"
                }
            } catch {
                $e.txSt.Text = "SYNC ERROR"
                $e.txSt.Foreground = Br "#EF5350"
            } finally {
                $script:bgState.bgPs.Dispose()
                $script:isFetchingQuota = $false
            }
        }
    })
    $script:bgState.timer.Start()
}

# ============================================================================
# EVENT HANDLERS
# ============================================================================

# Drag window from header
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
    $e.pinBorder.Background = Br "#00897B"
    $e.pinBorder.BorderBrush = Br "#00E5FF"
    $e.dotPin.Fill = Br "#FFFFFF"
    $e.dotPin.HorizontalAlignment = 'Right'
    $e.txtPin.HorizontalAlignment = 'Left'
    $e.txtPin.Text = "ON"
    $e.txtPin.Foreground = Br "#FFFFFF"
})
$e.chkPin.Add_Unchecked({
    $w.Topmost = $false
    $e.pinBorder.Background = Br "#35FFFFFF"
    $e.pinBorder.BorderBrush = Br "#60FFFFFF"
    $e.dotPin.Fill = Br "#C0FFFFFF"
    $e.dotPin.HorizontalAlignment = 'Left'
    $e.txtPin.HorizontalAlignment = 'Right'
    $e.txtPin.Text = "PIN"
    $e.txtPin.Foreground = Br "#FFFFFF"
})

# Upgrade credits
$e.btnUpgrade.Add_Click({
    $uri = if ($script:lastUpgradeUri) { $script:lastUpgradeUri } else { "https://aistudio.google.com/apikey" }
    Start-Process $uri
})

# In-Window Dropdown Tray Toggle (100% "Ketahan", never closes by accident!)
$e.accSelector.Add_PreviewMouseLeftButtonDown({
    if ($e.dropOverlay.Visibility -eq 'Visible') {
        $e.dropOverlay.Visibility = 'Collapsed'
        $e.txtArrow.Text = [char]0x25BC
    } else {
        $e.dropOverlay.Visibility = 'Visible'
        $e.txtArrow.Text = [char]0x25B2
    }
    $_.Handled = $true
})

# Close button inside dropdown tray
$e.btnCloseDropdown.Add_Click({
    $e.dropOverlay.Visibility = 'Collapsed'
    $e.txtArrow.Text = [char]0x25BC
})

# SWITCH — make this profile the primary session
$e.btnSwitch.Add_Click({
    $tag = $script:selectedAccount
    if (-not $tag) { $e.txSt.Text = "Please select a profile first"; $e.txSt.Foreground = Br "#FFA726"; return }
    if ($tag.active) {
        $e.txSt.Text = "Already active"; $e.txSt.Foreground = Br "#FFA726"
        return
    }
    $e.txSt.Text = "SWITCHING PRIMARY TO: $($tag.name.ToUpper())..."; $e.txSt.Foreground = Br "#FFA726"
    $w.Dispatcher.Invoke([Action]{}, 'Render')
    $res = SwitchTo $tag.name
    if ($res -eq "OK") {
        $e.txSt.Text = "SWITCHED! Primary Antigravity restarted."
        $e.txSt.Foreground = Br "#00FF88"
    } else {
        $e.txSt.Text = "SWITCH FAILED: $res"
        $e.txSt.Foreground = Br "#EF5350"
    }
    Refresh-Widget
})

# PARALLEL / FOCUS — launches an isolated parallel instance or focuses if running
$e.btnParalel.Add_Click({
    $tag = $script:selectedAccount
    if (-not $tag) {
        $e.txSt.Text = "Please select a profile first"
        $e.txSt.Foreground = Br "#FFA726"
        return
    }

    $cleanName = $tag.name.ToLower().Trim()
    $activeProcs = Get-ParallelProcesses
    $running = $activeProcs | Where-Object { $_.IsParallel -and ($_.ProfileName -eq $cleanName) }

    if ($running -and $running.ProcessObj -and $running.ProcessObj.MainWindowHandle -ne [IntPtr]::Zero) {
        [Win32WindowHelper]::ShowWindowAsync($running.ProcessObj.MainWindowHandle, 9) | Out-Null
        [Win32WindowHelper]::SetForegroundWindow($running.ProcessObj.MainWindowHandle) | Out-Null
        $e.txSt.Text = "FOCUSED: $($tag.name.ToUpper())"
        $e.txSt.Foreground = Br "#00E5FF"
    } else {
        $e.txSt.Text = "LAUNCHING PARALLEL: $($tag.name.ToUpper())..."
        $e.txSt.Foreground = Br "#FFA726"
        $w.Dispatcher.Invoke([Action]{}, 'Render')

        $res = LaunchParallel $cleanName
        if ($res -eq "OK") {
            $e.txSt.Text = "PARALLEL LAUNCHED: $($tag.name.ToUpper())"
            $e.txSt.Foreground = Br "#00FF88"
        } elseif ($res -eq "NO_EXE") {
            $e.txSt.Text = "ERROR: Antigravity.exe not found"
            $e.txSt.Foreground = Br "#EF5350"
        } else {
            $e.txSt.Text = "PARALLEL ERROR: $res"
            $e.txSt.Foreground = Br "#EF5350"
        }
    }

    Start-Sleep -Milliseconds 400
    Refresh-Widget
})

# LOGIN — Google OAuth sign-in
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
                    "Profile '$cleanName' ($($res.email)) saved successfully.`n`nSwitch to this profile now?",
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
                $e.txSt.Foreground = Br "#00FF88"
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

# SAVE — save current session
$e.btnSave.Add_Click({
    $cred = ReadActiveCredBlob
    if (-not $cred) {
        $e.txSt.Text = "No active session to save"; $e.txSt.Foreground = Br "#EF5350"
        return
    }
    $email = GetEmail $cred
    $defaultName = if ($email) { $email.Split('@')[0] } else { "user" }
    $name = AskName $defaultName
    if ($name) {
        SaveCur $name
        $e.txSt.Text = "SAVED: $name"
        $e.txSt.Foreground = Br "#00FF88"
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

# Initial pre-launch sync & animation
$w.Add_Loaded({
    StartPreLaunchSync
})

# ============================================================================
# LAUNCH
# ============================================================================

$w.ShowDialog() | Out-Null
