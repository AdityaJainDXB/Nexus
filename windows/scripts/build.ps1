# Builds Nexus for Windows: self-contained app + CLI + offline AI → dist\Nexus, then the installer and a portable zip.
param([string]$Version = "1.0.0", [switch]$NoInstaller)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root "dist"
$app = Join-Path $dist "Nexus"
Remove-Item $app -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $app | Out-Null

dotnet publish "$root\src\Nexus.App\Nexus.App.csproj" -c Release -r win-x64 --self-contained true -p:Version=$Version -p:PublishReadyToRun=true -o $app
if ($LASTEXITCODE -ne 0) { throw "publish failed" }
dotnet publish "$root\src\nexusctl\nexusctl.csproj" -c Release -r win-x64 --self-contained true -p:Version=$Version -p:PublishSingleFile=true -o "$dist\cli"
if ($LASTEXITCODE -ne 0) { throw "cli publish failed" }
Copy-Item "$dist\cli\nexusctl.exe" $app -Force

if (Test-Path "$root\vendor\llama\llama-server.exe") {
    Copy-Item "$root\vendor\llama" "$app\llama" -Recurse -Force
    Copy-Item "$root\vendor\Models" "$app\Models" -Recurse -Force
    Copy-Item "$root\vendor\Licenses" "$app\Licenses" -Recurse -Force
} else { Write-Warning "vendor\ missing — run scripts\fetch-vendor.ps1 to bundle offline AI" }
Copy-Item "$root\..\LICENSE" "$app\LICENSE.txt" -Force

if (-not $NoInstaller) {
    $iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $iscc) { throw "Inno Setup 6 not found (choco install innosetup)" }
    & $iscc "/DAppVersion=$Version" "/DSourceDir=$app" "/O$dist" "$root\installer\nexus.iss"
    if ($LASTEXITCODE -ne 0) { throw "installer build failed" }
    Compress-Archive -Path "$app\*" -DestinationPath "$dist\Nexus-$Version-win-x64-portable.zip" -CompressionLevel Optimal -Force
}
Get-ChildItem $dist -File | Format-Table Name, @{n = "MB"; e = { [math]::Round($_.Length / 1MB, 1) } }
