#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Jupyter Notebook / JupyterHub Provisioning Script
# - Multi-user setup via JupyterHub (PAM + system users)
# - Idempotent, reproducible, CI/CD-ready
# -----------------------------------------------------------------------------

echo "Waiting for cloud-init (if present)..."
cloud-init status --wait || true

echo "Updating system packages..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade

echo "Installing base packages..."
sudo apt-get install -y --no-install-recommends \
  curl ca-certificates git \
  python3 python3-venv python3-pip

echo "Installing Node.js (LTS) + npm..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y --no-install-recommends nodejs

# Enable SSH password authentication for cloud-init provisioning
echo "Configuring SSH for password authentication..."
sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

echo "Installing JupyterHub + JupyterLab..."
if [ ! -d "/opt/jupyterhub" ]; then
  sudo python3 -m venv /opt/jupyterhub
fi

sudo /opt/jupyterhub/bin/pip install --upgrade pip
sudo /opt/jupyterhub/bin/pip install jupyterhub jupyterlab

echo "Installing configurable-http-proxy (pinned version)..."
sudo npm install -g configurable-http-proxy@5.2.0

echo "Configuring JupyterHub..."
sudo mkdir -p /etc/jupyterhub

sudo tee /etc/jupyterhub/jupyterhub_config.py >/dev/null << 'EOF'
c = get_config()
c.JupyterHub.bind_url = "http://[::]:8000"
c.JupyterHub.spawner_class = "jupyterhub.spawner.LocalProcessSpawner"
c.Spawner.cmd = ["/opt/jupyterhub/bin/jupyterhub-singleuser"]
c.Spawner.default_url = "/lab"
c.Authenticator.admin_users = set()
c.Authenticator.allow_all = True
EOF

echo "Creating systemd service for JupyterHub..."
sudo tee /etc/systemd/system/jupyterhub.service >/dev/null << 'EOF'
[Unit]
Description=JupyterHub
After=network.target

[Service]
Type=simple
ExecStart=/opt/jupyterhub/bin/jupyterhub -f /etc/jupyterhub/jupyterhub_config.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable jupyterhub
sudo systemctl restart jupyterhub

echo "Cleaning up apt cache and package lists..."
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

echo "Resetting machine-id..."
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id || true

echo "Provisioning complete."
