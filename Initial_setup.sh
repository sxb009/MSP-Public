#!/bin/bash

# --- 0. Setup and Error Handling ---
# 'set -e' tells bash to stop the script immediately if any command fails.
set -e 
# This prevents apt from popping up pink/purple dialog boxes asking for user input.
export DEBIAN_FRONTEND=noninteractive

echo "Starting Mudro Logic Edge Provisioning..."

# --- 1. Update the base operating system ---
echo "Updating system..."
# Added options to automatically keep existing configs and never prompt the user
sudo -E apt-get update
sudo -E apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
sudo apt-get install curl jq -y

# --- 2. Install Docker & Compose ---
echo "Installing Docker Engine and Compose..."
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo apt-get install -y docker-compose-plugin

# --- 3. Fix the Docker Permissions Trap ---
# When you run this script with sudo, $USER becomes 'root'. 
# SUDO_USER captures the actual person who ran the script.
ACTUAL_USER=${SUDO_USER:-$USER}
echo "Adding user $ACTUAL_USER to the docker group..."
sudo usermod -aG docker $ACTUAL_USER

# --- 4. Enable Services ---
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

# --- 5. Install Tailscale ---
echo "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
echo ""
read -sp 'Enter Tailscale Auth Key (Input will be hidden): ' TS_KEY
echo ""
echo "Authenticating Tailscale..."
# Pass the key securely as an environment variable
sudo TAILSCALE_AUTHKEY=$TS_KEY tailscale up
# Unset the variable immediately
unset TS_KEY

# --- 6. Firewall & Network Routing (CRITICAL FIX) ---
echo "Configuring Firewall and Network Routing..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh 
sudo ufw allow in on tailscale0

# The Missing Link: Enable IP Forwarding so Docker can reach the Tailscale VPN
sudo sysctl -w net.ipv4.ip_forward=1
# Persist it across reboots
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi
# The Missing Link: Allow Docker to route traffic out through Tailscale
sudo ufw route allow in on docker0 out on tailscale0
sudo ufw route allow in on tailscale0 out on docker0
sudo ufw --force enable

# --- 7. Docker Log Rotation (SSD Protection) ---
echo "Configuring Docker Log Rotation..."
sudo mkdir -p /etc/docker
# Using tee overwrites the file. If you have other docker configs, this deletes them.
# For a fresh edge device, this is perfectly safe.
echo '{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker

# --- 8. Create Mudro Logic Maintenance User ---
echo "Creating maintenance user..."
if ! id "mudro-admin" &>/dev/null; then
    sudo useradd -m -s /bin/bash mudro-admin
    # Ensure they have a secure, random password or disable password login entirely
    sudo usermod -aG sudo,docker mudro-admin
    echo "mudro-admin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/mudro-admin
    echo "Maintenance user created successfully!"
else
    echo "Maintenance user already exists, skipping."
fi

# --- 9. Host Sanitization ---
echo "Sanitizing host environment..."
# Clear the current session history
history -c
# Write the empty history to the file
history -w
# Clear terminal screen
clear
echo "Provisioning complete. System is clean."

echo "========================================================="
echo "Base provisioning complete!"
echo "Please REBOOT the server to apply Docker group permissions."
echo "After reboot, run 'sudo tailscale up' to authenticate."
echo "========================================================="