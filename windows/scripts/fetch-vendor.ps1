# Downloads the offline AI runtime (llama.cpp, MIT) and model (Qwen2.5-1.5B-Instruct Q4_K_M, Apache-2.0) for Windows.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $root "vendor"
$llamaTag = if ($env:LLAMA_TAG) { $env:LLAMA_TAG } else { "b11007" }
$modelUrl = "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
$modelSha = "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e"

New-Item -ItemType Directory -Force -Path "$vendor\llama", "$vendor\Models", "$vendor\Licenses" | Out-Null

if (-not (Test-Path "$vendor\llama\llama-server.exe")) {
    $zip = "$vendor\llama-win.zip"
    Write-Host "Downloading llama.cpp $llamaTag (win-cpu-x64)…"
    Invoke-WebRequest "https://github.com/ggml-org/llama.cpp/releases/download/$llamaTag/llama-$llamaTag-bin-win-cpu-x64.zip" -OutFile $zip
    Expand-Archive $zip -DestinationPath "$vendor\llama-tmp" -Force
    $server = Get-ChildItem "$vendor\llama-tmp" -Recurse -Filter "llama-server.exe" | Select-Object -First 1
    Copy-Item (Join-Path $server.DirectoryName "*") "$vendor\llama" -Recurse -Force
    Remove-Item "$vendor\llama-tmp", $zip -Recurse -Force
}
# Keep only what the server needs
Get-ChildItem "$vendor\llama" -Filter "*.exe" | Where-Object { $_.Name -ne "llama-server.exe" } | Remove-Item -Force

$model = "$vendor\Models\qwen2.5-1.5b-instruct-q4_k_m.gguf"
if (-not (Test-Path $model) -or (Get-FileHash $model -Algorithm SHA256).Hash.ToLower() -ne $modelSha) {
    Write-Host "Downloading Qwen2.5-1.5B-Instruct (Q4_K_M, ~1 GB)…"
    Invoke-WebRequest $modelUrl -OutFile $model
    if ((Get-FileHash $model -Algorithm SHA256).Hash.ToLower() -ne $modelSha) { throw "Model checksum mismatch" }
}
Invoke-WebRequest "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/LICENSE" -OutFile "$vendor\Licenses\Qwen2.5-LICENSE.txt"
Invoke-WebRequest "https://raw.githubusercontent.com/ggml-org/llama.cpp/master/LICENSE" -OutFile "$vendor\Licenses\llama.cpp-LICENSE.txt"
Write-Host "✓ vendor ready: $(Get-ChildItem $vendor -Recurse | Measure-Object Length -Sum | ForEach-Object { '{0:N0} MB' -f ($_.Sum / 1MB) })"
