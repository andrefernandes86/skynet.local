#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-comfyui}"
HF_TOKEN="${HF_TOKEN:-}"    # export HF_TOKEN=hf_xxx (required for SDXL)
# Optional extras (set these to enable additional downloads)
GET_JUGGERNAUT="${GET_JUGGERNAUT:-0}"     # 1 to enable
GET_DREAMSHAPER="${GET_DREAMSHAPER:-0}"   # 1 to enable
GET_CONTROLNET="${GET_CONTROLNET:-0}"     # 1 to enable (Canny + Depth examples for SDXL)
GET_ANIMATEDIFF="${GET_ANIMATEDIFF:-0}"   # 1 to enable (motion module example)

echo ">>> Target container: $CONTAINER"
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || { echo "❌ Container '$CONTAINER' not running"; exit 1; }

# Inside the container, these paths are bind-mounted to your host:
CKPT_DIR="/comfyui/models/checkpoints"
VAE_DIR="/comfyui/models/vae"
UPSCALE_DIR="/comfyui/models/upscale_models"
CONTROLNET_DIR="/comfyui/models/controlnet"
MOTION_DIR="/comfyui/models/motion_modules"   # you may need to create/use this

echo ">>> Ensuring tools inside the container..."
docker exec -it "$CONTAINER" bash -lc '
  apt-get update && apt-get install -y git-lfs >/dev/null 2>&1 || true
  pip install --upgrade huggingface_hub >/dev/null 2>&1
  mkdir -p "'"$CKPT_DIR"'" "'"$VAE_DIR"'" "'"$UPSCALE_DIR"'" "'"$CONTROLNET_DIR"'" "'"$MOTION_DIR"'" >/dev/null 2>&1
'

if [[ -z "$HF_TOKEN" ]]; then
  echo "⚠️  HF_TOKEN is empty. SDXL base/refiner usually require a Hugging Face token (license acceptance)."
  echo "   Export it like:  export HF_TOKEN=hf_xxx"
fi

echo ">>> Downloading core SDXL models (base, refiner, TAESD VAE, RealESRGAN)..."

# SDXL Base
docker exec -it "$CONTAINER" bash -lc "
  huggingface-cli download stabilityai/stable-diffusion-xl-base-1.0 \
    sd_xl_base_1.0.safetensors \
    --local-dir $CKPT_DIR \
    ${HF_TOKEN:+--token $HF_TOKEN} >/dev/null 2>&1 || true
"

# SDXL Refiner (optional but helpful)
docker exec -it "$CONTAINER" bash -lc "
  huggingface-cli download stabilityai/stable-diffusion-xl-refiner-1.0 \
    sd_xl_refiner_1.0.safetensors \
    --local-dir $CKPT_DIR \
    ${HF_TOKEN:+--token $HF_TOKEN} >/dev/null 2>&1 || true
"

# TAESD VAE for SDXL
docker exec -it "$CONTAINER" bash -lc "
  huggingface-cli download madebyollin/taesdxl \
    taesdxl.safetensors \
    --local-dir $VAE_DIR >/dev/null 2>&1 || true
"

# RealESRGAN x4 upscaler
docker exec -it "$CONTAINER" bash -lc "
  huggingface-cli download xinntao/Real-ESRGAN \
    weights/RealESRGAN_x4plus.pth \
    --local-dir $UPSCALE_DIR >/dev/null 2>&1 || true
"

# ---- Optional: Popular people/futuristic checkpoints (you toggle above) ----

if [[ "$GET_JUGGERNAUT" == "1" ]]; then
  echo ">>> Downloading JuggernautXL (checkpoint) ..."
  # File name sometimes changes. Try common candidates, ignore failures.
  docker exec -it "$CONTAINER" bash -lc "
    huggingface-cli download RunDiffusion/Juggernaut-XL \
      juggernautXL_v9.safetensors \
      --local-dir $CKPT_DIR --include '*' >/dev/null 2>&1 || \
    huggingface-cli download RunDiffusion/Juggernaut-XL \
      Juggernaut-XL.safetensors \
      --local-dir $CKPT_DIR --include '*' >/dev/null 2>&1 || true
  "
fi

if [[ "$GET_DREAMSHAPER" == "1" ]]; then
  echo '>>> Downloading DreamShaperXL (checkpoint) ...'
  docker exec -it "$CONTAINER" bash -lc "
    huggingface-cli download Lykon/DreamShaperXL \
      DreamShaperXL_Turbo.safetensors \
      --local-dir $CKPT_DIR --include '*' >/dev/null 2>&1 || \
    huggingface-cli download Lykon/DreamShaperXL \
      DreamShaperXL.safetensors \
      --local-dir $CKPT_DIR --include '*' >/dev/null 2>&1 || true
  "
fi

if [[ "$GET_CONTROLNET" == "1" ]]; then
  echo ">>> Downloading ControlNet SDXL examples (canny + depth) ..."
  # SDXL ControlNets vary by repo/file; try common ones
  docker exec -it "$CONTAINER" bash -lc "
    huggingface-cli download xinsir/controlnet-sdxl-1.0-canny \
      controlnet-sdxl-1.0-canny.safetensors \
      --local-dir $CONTROLNET_DIR >/dev/null 2>&1 || true
  "
  docker exec -it "$CONTAINER" bash -lc "
    huggingface-cli download diffusers/controlnet-depth-sdxl-1.0-small \
      diffusion_pytorch_model.safetensors \
      --local-dir $CONTROLNET_DIR >/dev/null 2>&1 || true
  "
fi

if [[ "$GET_ANIMATEDIFF" == "1" ]]; then
  echo ">>> Downloading AnimateDiff motion module example ..."
  # Motion module filenames differ; attempt a common SDXL motion module path
  docker exec -it "$CONTAINER" bash -lc "
    huggingface-cli download guoyww/animatediff \
      mm_sdxl_v10_beta.ckpt \
      --local-dir $MOTION_DIR >/dev/null 2>&1 || true
  "
fi

echo ">>> Restarting ComfyUI so it picks up new models..."
docker restart "$CONTAINER" >/dev/null

echo
echo "=== Available models now (inside container mounts) ==="
docker exec -it "$CONTAINER" bash -lc "
  echo '# Checkpoints:';  ls -lh $CKPT_DIR || true; echo
  echo '# VAE:';         ls -lh $VAE_DIR || true; echo
  echo '# Upscalers:';   ls -lh $UPSCALE_DIR || true; echo
  echo '# ControlNet:';  ls -lh $CONTROLNET_DIR || true; echo
  echo '# Motion Modules:'; ls -lh $MOTION_DIR || true; echo
"
echo "Done."
