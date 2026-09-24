param()
Add-Type -AssemblyName PresentationFramework

function Check-FileSyntax($path) {
    $errs = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
    if ($errs.Count -eq 0) {
        Write-Host "$([IO.Path]::GetFileName($path)) syntax: OK" -ForegroundColor Green
        return $true
    } else {
        Write-Host "$([IO.Path]::GetFileName($path)) syntax errors:" -ForegroundColor Red
        foreach ($e in $errs) {
            Write-Host "  Line $($e.Extent.StartLineNumber): $($e.Message)"
        }
        return $false
    }
}

$ok1 = Check-FileSyntax "$PSScriptRoot\AgyRig-GUI.ps1"
$ok2 = Check-FileSyntax "$PSScriptRoot\agy-rig.ps1"

if (-not ($ok1 -and $ok2)) { exit 1 }

$content = Get-Content "$PSScriptRoot\AgyRig-GUI.ps1" -Raw
if ($content -match '\$xamlStr = @''([\s\S]*?)''@') {
    try {
        $xml = [xml]$matches[1]
        $r = New-Object Xml.XmlNodeReader $xml
        $w = [Windows.Markup.XamlReader]::Load($r)
        Write-Host "XAML Loaded successfully! Width=$($w.Width) Height=$($w.Height)" -ForegroundColor Green
    } catch {
        Write-Host "XAML Load Error: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) { Write-Host "Inner: $($_.Exception.InnerException.Message)" -ForegroundColor Yellow }
        exit 1
    }
}
