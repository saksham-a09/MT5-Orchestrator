# Complete Production Deployment Guide: MT5 Remote API on Linux (Wine + Xvfb)

This document provides step-by-step instructions to set up, configure, and maintain the **Bhionex MT5 Remote API** system on a production Linux server (Ubuntu/Debian).

---

## 1. System Architecture Overview

The system consists of:
1. **MT5 Orchestrator Daemon (`orchestrator.py`)**: Periodically polls the Bhionex API for active user subscriptions, automatically clones MetaTrader 5 terminal instances, and manages background `worker.py` processes for each user. It also automatically embeds and serves the **MT5 Validator API** on port 5001.
2. **MT5 Validator API (`validator_api.py`)**: A production WSGI (Waitress) HTTP service providing endpoints (`/` and `/validate`) to test and validate MT5 account credentials synchronously using temporary MT5 clone instances. Runs embedded inside `orchestrator.py` by default, or independently as a standalone service.

### Why Wine + Xvfb?
MetaTrader 5 (`terminal64.exe`) and the official `MetaTrader5` Python package rely on Windows APIs. Running this stack on a headless Linux server requires:
- **Wine 64-bit**: Windows compatibility layer for Linux.
- **Xvfb (X Virtual Framebuffer)**: Provides a headless display environment required by MT5 GUI components.
- **Windows Python inside Wine**: Executed via Wine so the native Windows `MetaTrader5` C-extensions bind directly to MT5 terminal instances.

---

## 2. Prerequisites & Server Requirements

| Component | Minimum Specification | Recommended Specification |
| :--- | :--- | :--- |
| **OS** | Ubuntu 22.04 LTS / 24.04 LTS or Debian 12 | Ubuntu 22.04 LTS / 24.04 LTS |
| **CPU** | 2 vCPUs | 4+ vCPUs |
| **RAM** | 2 GB | 4 GB - 8 GB+ (Scales with client clone count) |
| **Disk Space** | 20 GB SSD | 50 GB+ NVMe SSD |
| **Architecture** | x86_64 / amd64 | x86_64 / amd64 |

---

## 3. Step-by-Step Server Setup Guide

### Step 1: Update System & Install Dependencies

```bash
sudo apt update && sudo apt upgrade -y
sudo dpkg --add-architecture i386
sudo apt install -y software-properties-common wget curl git xvfb cabextract psmisc ufw
```

### Step 2: Install Wine (HQ Repository)

```bash
# Add WineHQ signing key
sudo mkdir -pm755 /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key

# Add WineHQ repository for Ubuntu 22.04 (jammy)
# Replace 'jammy' with your distribution release codename if different (e.g., noble, focal)
sudo wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/winehq-jammy.sources

sudo apt update
sudo apt install -y --install-recommends winehq-stable
```

Verify Wine installation:
```bash
wine --version
```

---

### Step 3: Configure Wine Prefix Environment

Create a dedicated Wine prefix for the MT5 system (e.g., under `/root/.wine_mt5` or `/home/mt5user/.wine_mt5`):

```bash
export WINEPREFIX="/root/.wine_mt5"
export WINEARCH="win64"
export DISPLAY=":99"

# Initialize wine prefix without GUI prompts
xvfb-run -a wineboot --init
```

---

### Step 4: Install Windows Python inside Wine Prefix

Download and install Windows Python 3.10 (64-bit) into the Wine environment:

```bash
cd /tmp
wget https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe

# Quiet installation for all users with PATH addition enabled
xvfb-run -a wine python-3.10.11-amd64.exe /quiet InstallAllUsers=1 PrependPath=1

# Verify Python in Wine
xvfb-run -a wine python --version
```

---

### Step 5: Install Master MetaTrader 5 Terminal

1. Download or copy your Master MetaTrader 5 installation directory (containing `terminal64.exe` and standard MT5 system files).
2. Place the master terminal directory at `/opt/mt5-master` (or custom location defined in `.env`).

```bash
sudo mkdir -p /opt/mt5-master
sudo mkdir -p /opt/mt5-clients

# Example: Extract or copy your prepared MT5 master folder to /opt/mt5-master
# Ensure terminal64.exe is directly present at /opt/mt5-master/terminal64.exe
```

---

### Step 6: Deploy Project Code & Install Requirements

Clone or copy the project code to `/opt/mt5-remote-api`:

```bash
sudo mkdir -p /opt/mt5-remote-api
# Copy orchestrator.py, worker.py, validator_api.py, example.ini, requirements.txt, etc.
cd /opt/mt5-remote-api

# Upgrade pip and install required packages inside Wine Python
xvfb-run -a wine python -m pip install --upgrade pip
xvfb-run -a wine python -m pip install -r requirements.txt
```

---

### Step 7: Configure Environment Variables (`.env`)

Create `/opt/mt5-remote-api/.env` based on `.env.example`:

```bash
cat << 'EOF' > /opt/mt5-remote-api/.env
# Bhionex API Configuration
API_BASE_URL=https://api.bhionex.com
BOT_API_KEY=your_production_bot_api_key_here

# Directory Paths (Wine paths inside Wine prefix)
MASTER_MT5_DIR=C:/opt/mt5-master
CLIENTS_DIR=C:/opt/mt5-clients

# Orchestrator Configuration
ORCHESTRATOR_INTERVAL=60

# Worker Configuration
WORKER_SYNC_INTERVAL=30
HISTORY_DAYS=7
CONFIG_TEMPLATE=example.ini
WORKER_EXPERT=FCE
WORKER_SYMBOL=XAUUSD
WORKER_TIMEFRAME=M1

# Validator API Configuration
VALIDATOR_PORT=5001
VALIDATION_TIMEOUT=30
VALIDATOR_THREADS=4
EOF
```

> **Note on Wine Paths**: In Wine, `/opt/mt5-master` maps to `Z:/opt/mt5-master` or `C:/opt/mt5-master` depending on drive mappings. Using `C:/opt/mt5-master` or standard Linux paths resolved inside Python will be normalized by `os.path.normpath`.

---

## 4. systemd Service Setup

Setting up `systemd` services guarantees automatic startup on boot, process supervision, auto-restarts, and central logging.

> **Note**: Because `orchestrator.py` automatically embeds and serves the Validator API on port 5001, you only need to run **Service 1 (`mt5-orchestrator.service`)**. Service 2 is optional for decoupled setups.

### Service 1: MT5 Orchestrator (`mt5-orchestrator.service`)

Create `/etc/systemd/system/mt5-orchestrator.service`:

```ini
[Unit]
Description=Bhionex MT5 Orchestrator Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/mt5-remote-api
Environment="WINEPREFIX=/root/.wine_mt5"
Environment="WINEARCH=win64"
ExecStart=/usr/bin/xvfb-run -a wine python.exe orchestrator.py
Restart=always
RestartSec=10
StandardOutput=append:/var/log/mt5-orchestrator.log
StandardError=append:/var/log/mt5-orchestrator.err

[Install]
WantedBy=multi-user.target
```

### Service 2: MT5 Validator API (`mt5-validator.service`)

Create `/etc/systemd/system/mt5-validator.service`:

```ini
[Unit]
Description=Bhionex MT5 Account Validator API Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/mt5-remote-api
Environment="WINEPREFIX=/root/.wine_mt5"
Environment="WINEARCH=win64"
ExecStart=/usr/bin/xvfb-run -a wine python.exe validator_api.py
Restart=always
RestartSec=5
StandardOutput=append:/var/log/mt5-validator.log
StandardError=append:/var/log/mt5-validator.err

[Install]
WantedBy=multi-user.target
```

### Enable & Start Services

```bash
# Reload systemd manager configuration
sudo systemctl daemon-reload

# Enable services to start automatically at boot
sudo systemctl enable mt5-orchestrator
sudo systemctl enable mt5-validator

# Start services immediately
sudo systemctl start mt5-orchestrator
sudo systemctl start mt5-validator

# Check status
sudo systemctl status mt5-orchestrator
sudo systemctl status mt5-validator
```

---

## 5. Security & Firewall Configuration

Protect the Validator API port (default: 5001) using UFW:

```bash
sudo ufw allow 22/tcp
# Allow access to Validator API port from trusted internal server/IP only
sudo ufw allow from <TRUSTED_SERVER_IP> to any port 5001 proto tcp

# Enable firewall
sudo ufw enable
```

---

## 6. Logs & Process Monitoring

### Check Real-Time Logs

- **Orchestrator Logs**:
  ```bash
  tail -f /var/log/mt5-orchestrator.log /var/log/mt5-orchestrator.err
  ```

- **Validator API Logs**:
  ```bash
  tail -f /var/log/mt5-validator.log /var/log/mt5-validator.err
  ```

- **Individual Client Worker Logs**:
  ```bash
  tail -f /opt/mt5-clients/clone_<LOGIN_ID>/worker_<LOGIN_ID>_spawn.log
  ```

### Useful Management Commands

- **Restart Services**:
  ```bash
  sudo systemctl restart mt5-orchestrator
  sudo systemctl restart mt5-validator
  ```

- **Emergency Stop All Workers**:
  ```bash
  xvfb-run -a wine python.exe stop_workers.py
  ```

- **Purge Inactive Clone Directories**:
  ```bash
  xvfb-run -a wine python.exe purge_clones.py
  ```

---
