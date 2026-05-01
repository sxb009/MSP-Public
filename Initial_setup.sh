#!/bin/bash

# 1. Update the base operating system and install curl
echo "Updating system..."
sudo apt update && sudo apt upgrade -y
sudo apt install curl -y

# 2. Install the official Docker Engine & Docker Compose
echo "Installing Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# 3. Add your current user to the Docker group (eliminates needing 'sudo' for docker commands)
sudo usermod -aG docker $USER

# 4. Configure Docker to start automatically after a factory power outage
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

# 5. Install the Tailscale VPN Client
echo "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh

# 6. Configure and Harden the Firewall (UFW)
echo "Configuring Firewall..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
# Allow standard SSH just in case you need local network access
sudo ufw allow ssh 
sudo ufw allow in on tailscale0
# Turn the firewall on
sudo ufw --force enable

echo "Base provisioning complete! Please reboot the server to apply user group changes."