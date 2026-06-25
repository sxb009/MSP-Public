#!/bin/bash

# ==============================================================================
# MudroLogic Edge Gateway Provisioning Script
# Initial_setup.sh
#
# USAGE:
#   wget https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_PUBLIC_REPO/main/Initial_setup.sh
#   cat Initial_setup.sh          # Always verify before running
#   chmod +x Initial_setup.sh
#   sudo ./Initial_setup.sh
# ==============================================================================

# --- 0. Setup and Error Handling ---
# Stop immediately if any command fails - prevents partial installs
set -e
# Suppress all interactive apt prompts
export DEBIAN_FRONTEND=noninteractive
# Capture the actual human user even when script is run with sudo
# Without this, $USER becomes 'root' and Docker permissions break permanently
ACTUAL_USER=${SUDO_USER:-$USER}

echo "Starting MudroLogic Edge Provisioning..."

# --- 1. Update the base operating system ---
echo "Updating system..."
sudo -E apt-get update
sudo -E apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
sudo apt-get install curl jq -y

# --- 2. Install Docker & Compose ---
echo "Installing Docker Engine and Compose..."
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo apt-get install -y docker-compose-plugin
rm get-docker.sh

# --- 3. Fix the Docker Permissions Trap ---
# When you run this script with sudo, $USER becomes 'root'.
# ACTUAL_USER captures the actual person who ran the script.
echo "Adding user $ACTUAL_USER to the docker group..."
sudo usermod -aG docker $ACTUAL_USER

# --- 4. Enable Services ---
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

# --- 5. Docker Log Rotation (SSD Protection) ---
# Prevents Docker logs filling the SSD on long-running edge devices
echo "Configuring Docker Log Rotation..."
sudo mkdir -p /etc/docker
echo '{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}' | sudo tee /etc/docker/daemon.json > /dev/null
sudo systemctl restart docker

# --- 6. Install Tailscale ---
echo "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
echo ""
# -s = silent (key not shown on screen), -p = prompt text
# Key is passed inline to sudo and never written to disk or bash history
read -sp 'Enter Tailscale Auth Key (input hidden): ' TS_KEY
echo ""
echo "Authenticating Tailscale..."
sudo TAILSCALE_AUTHKEY=$TS_KEY tailscale up --accept-routes
unset TS_KEY
echo "Tailscale connected."

# --- 7. Firewall & Network Routing ---
echo "Configuring Firewall and Network Routing..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow in on tailscale0

# Enable IP Forwarding so Docker containers can reach the Tailscale VPN
# Required for Telegraf to write to a remote TimescaleDB over Tailscale
sudo sysctl -w net.ipv4.ip_forward=1
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
fi

# Allow Docker containers to route traffic out through Tailscale and back
sudo ufw route allow in on docker0 out on tailscale0
sudo ufw route allow in on tailscale0 out on docker0
sudo ufw --force enable

# --- 8. Create MudroLogic Maintenance User ---
# Creates a dedicated maintenance account so you retain access even if the
# client changes the default Ubuntu user password.
echo "Creating maintenance user..."
if ! id "mudro-admin" &>/dev/null; then
    sudo useradd -m -s /bin/bash mudro-admin
    sudo usermod -aG sudo,docker mudro-admin

    # Generate a secure random password.
    # NOTE: NOPASSWD removed intentionally - password authentication required for security.
    # The random password below is strong enough; passwordless sudo is unnecessary risk.
    ADMIN_PASSWORD=$(openssl rand -base64 16)
    echo "mudro-admin:$ADMIN_PASSWORD" | sudo chpasswd

    # Display BEFORE unsetting - password must be saved before it is wiped from memory
    echo ""
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  !! SAVE THIS PASSWORD IN YOUR PASSWORD MANAGER  !!"
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  Maintenance user : mudro-admin"
    echo "  Password         : $ADMIN_PASSWORD"
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    # Pause to give you time to copy the password before it scrolls away.
    # Only wipe from memory AFTER you confirm you have saved it.
    read -p "  Press ENTER once you have saved the password..."
    unset ADMIN_PASSWORD
else
    echo "Maintenance user already exists, skipping."
fi

# --- 9. Install Portainer Agent ---
# This registers the PC with your central Portainer dashboard over Tailscale.
# The Edge Key is unique to your Portainer environment - get it from:
# Portainer Dashboard -> Environments -> Add Environment -> Edge Agent
echo ""
echo "  You will now need your Portainer Edge Agent command."
echo "  Get it from your Portainer dashboard under:"
echo "  Environments -> Add Environment -> Edge Agent"
echo ""
read -p "  Paste your full Portainer Edge Agent 'docker run' command here, then press ENTER: " PORTAINER_CMD
echo ""
eval $PORTAINER_CMD
unset PORTAINER_CMD
echo "Portainer Agent installed."

# --- 10. Host Sanitization ---
# Clears sensitive data from this subshell's memory.
# Note: your interactive terminal session history is separate and unaffected.
# Manually run 'history -c && history -w' in your terminal after the script completes
# if you want to clear that session too.
echo "Sanitizing provisioning environment..."
unset TS_KEY ADMIN_PASSWORD PORTAINER_CMD

echo ""
echo "========================================================="
echo "  MudroLogic Edge Provisioning Complete!"
echo "========================================================="
echo ""
echo "  NEXT STEPS:"
echo "  1. Verify this device appears in your Tailscale admin console."
echo "  2. Disable key expiry for this node in Tailscale admin"
echo "     (prevents losing access after 180 days)."
echo "  3. Confirm the device appears as associated in your Portainer dashboard."
echo "  4. Deploy your Docker stack from your private GitHub repo via Portainer."
echo ""
echo "  A reboot is recommended to apply Docker group permissions."
echo "  Run: sudo reboot"
echo ""
