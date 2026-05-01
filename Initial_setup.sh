#!/bin/bash

# 1. Update the base operating system and install curl
echo "Updating system..."
sudo apt update && sudo apt upgrade -y
sudo apt install curl -y

# 2. Install the official Docker Engine
echo "Installing Docker Engine..."
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# 2.5 Install the Docker Compose Plugin (The "Space" version)
echo "Installing Docker Compose Plugin..."
sudo apt-get install -y docker-compose-plugin

# 3. Add current user to Docker group
sudo usermod -aG docker $USER

# 4. Configure Docker to start automatically after power outage
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

# 5. Install the Tailscale VPN Client
echo "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh

# 6. Configure and Harden the Firewall (UFW)
echo "Configuring Firewall..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh 
sudo ufw allow in on tailscale0
sudo ufw --force enable

# 7. MSP Bonus: Install Log Rotation (Prevents SSD wear on edge devices)
echo "Configuring Docker Log Rotation..."
sudo mkdir -p /etc/docker
echo '{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker

echo "Base provisioning complete! Please reboot the server to apply changes."

# 8. Create Mudro Logic Maintenance User
echo "Creating maintenance user..."
if ! id "mudro-admin" &>/dev/null; then
    sudo useradd -m -s /bin/bash mudro-admin
    sudo usermod -aG sudo,docker mudro-admin
    # Enable passwordless sudo for this specific user
    echo "mudro-admin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/mudro-admin
    echo "Maintenance user created successfully!"
else
    echo "Maintenance user already exists, skipping."
fi