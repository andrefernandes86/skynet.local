#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/mnt/data/comfyui"
IMAGE_NAME="comfyui-local"
CONTAINER_NAME="comfyui"
PORT="8188"
TZ_VAL="America/Chicago"

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

echo "[1/5] Write Dockerfile"
cat > Dockerfile <<'DOCKER'
FROM pytorch/pytorch:2.3.1-cuda12.1-cudnn8-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1

# OS deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    git git-lfs ffmpeg libglib2.0-0 libsm6 libxrender1 libxext6 \
    && rm -rf /var/lib/apt/lists/* \
    && git lfs install

WORKDIR /opt
# clone ComfyUI at build time
RUN git clone https://github.com/comfyanonymous/ComfyUI.git
WORKDIR /opt/ComfyUI

# torch wheels index for CUDA builds and base deps
RUN pip install --no-cache-dir --upgrade pip setuptools wheel \
 && pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/cu121 \
    -r requirements.txt

# Create mount points for host volumes (will be bind-mounted)
RUN mkdir -p /comfyui/models /comfyui/input /comfyui/output /comfyui/custom_nodes

EXPOSE 8188
CMD ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
DOCKER

echo "[2/5] Write docker-compose.yml"
cat > docker-compose.yml <<'YAML'
services:
  comfyui:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: comfyui
    ports:
      - "8188:8188"
    restart: always
    # Requires NVIDIA Container Toolkit installed
    gpus: all
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,utility,video
      - TZ=America/Chicago
    volumes:
      - ./models:/comfyui/models
      - ./input:/comfyui/input
      - ./output:/comfyui/output
      - ./custom_nodes:/comfyui/custom_nodes
YAML

echo "[3/5] Prepare host folders"
mkdir -p models/{checkpoints,vae,loras,controlnet,upscale_models,clip} input output custom_nodes

echo "[4/5] Build image"
docker compose build

echo "[5/5] Run container"
docker compose up -d

echo "----------------------------------------------------------------"
echo "ComfyUI is starting. Open:  http://<this-host-ip>:${PORT}/"
echo "Models:   ${BASE_DIR}/models"
echo "Outputs:  ${BASE_DIR}/output"
echo "Custom nodes: ${BASE_DIR}/custom_nodes"
echo "----------------------------------------------------------------"
