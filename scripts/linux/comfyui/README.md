# 1) Make it executable
chmod +x comfyui_grab_models.sh

# 2) Export your Hugging Face token (needed for SDXL)
export HF_TOKEN=hf_********************************

# 3) (Optional) toggle extras
export GET_JUGGERNAUT=1
export GET_DREAMSHAPER=1
export GET_CONTROLNET=1
export GET_ANIMATEDIFF=1

# 5) Run it
./comfyui_grab_models.sh
