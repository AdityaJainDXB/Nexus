#!/bin/zsh
# Downloads the offline AI runtime (llama.cpp, MIT) and the default model (Qwen2.5-1.5B-Instruct Q4_K_M, Apache-2.0).
set -euo pipefail
cd "$(dirname "$0")/.."
LLAMA_TAG=${LLAMA_TAG:-b11007}
MODEL_URL=${MODEL_URL:-https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf}
MODEL_SHA=${MODEL_SHA:-6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e}
mkdir -p Vendor/llama Vendor/models
if [[ ! -x Vendor/llama/llama-$LLAMA_TAG/llama-server ]]; then
  echo "▸ Fetching llama.cpp $LLAMA_TAG"
  curl -fL --progress-bar -o Vendor/llama/llama.tar.gz "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-bin-macos-arm64.tar.gz"
  tar -xzf Vendor/llama/llama.tar.gz -C Vendor/llama && rm Vendor/llama/llama.tar.gz
fi
MODEL=Vendor/models/$(basename "$MODEL_URL")
if [[ ! -f "$MODEL" ]] || [[ "$(shasum -a 256 "$MODEL" | cut -d' ' -f1)" != "$MODEL_SHA" ]]; then
  echo "▸ Fetching model (~1.1 GB)"
  curl -fL --progress-bar -o "$MODEL" "$MODEL_URL"
  [[ "$(shasum -a 256 "$MODEL" | cut -d' ' -f1)" == "$MODEL_SHA" ]] || { echo "✗ checksum mismatch"; exit 1; }
fi
curl -fsL -o Vendor/models/LICENSE-Qwen2.5.txt https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/LICENSE
echo "✓ Vendor ready"
