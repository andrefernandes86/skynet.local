#!/bin/bash
set -e

echo "[1/6] Removing old versions (if any)..."
sudo apt-get remove -y docker docker-engine docker.io containerd runc || true

echo "[2/6] Installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release

echo "[3/6] Adding Docker’s official GPG key..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "[4/6] Setting up the Docker repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "[5/6] Installing Docker Engine and Docker Compose plugin..."
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "[6/6] Enabling and starting Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

echo "✅ Docker and Docker Compose installed successfully!"

echo
echo "Versions installed:"
docker --version
docker compose version

echo
echo "👉 If you want to run Docker without sudo, run:"
echo "   sudo usermod -aG docker \$USER"
echo "   Then log out and back in."
