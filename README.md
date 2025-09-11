# skynet.local

This repository is my personal collection of **scripts** and **Docker Compose stacks** used to manage, automate, and run services in my homelab (**Skynet**).  
It serves as a central place to store, organize, and version-control everything I build and maintain.

---

## 🚀 Usage

### Scripts

1. Navigate to the correct OS folder (`linux`, `windows`, or `macos`):  

```bash
cd scripts/linux
```

2. Run the script:  

```bash
./myscript.sh
```

*(On Windows use `.ps1` or `.bat`, on macOS use `.sh` or `.zsh` depending on the script)*  

---

### Docker Compose

1. Navigate into the desired application folder:  

```bash
cd docker-compose/<app-name>
```

2. Start the service:  

```bash
docker compose up -d
```

3. Stop it:  

```bash
docker compose down
```

---

## 🛠️ Homelab Context

This repo is part of my **homelab project (Skynet)**, where I experiment with:  

- **Proxmox** for virtualization  
- **Docker & Docker Compose** for containerized services  
- **AI/ML workloads** (Ollama, OpenWebUI, RAG pipelines, etc.)  
- **Storage, backup, and networking automation**  

---

## 📌 Notes
  
- All files are designed to run on **Ubuntu 22.04/24.04**, but some may work on other platforms.  

---

## 📜 License

MIT License.  
Use and adapt freely, but at your own risk.
