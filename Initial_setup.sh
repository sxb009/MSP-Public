#!/bin/bash

# ==============================================================================
# MudroLogic Edge Gateway Provisioning Script
# Initial_setup.sh
#
# PURPOSE:
#   Takes a blank Ubuntu PC and makes it a secure, deployment-ready edge node.
#   Installs Docker, Tailscale, UFW, Docker network security, the MudroLogic
#   maintenance user, deploys the SSH access key, hardens SSH, and installs
#   the Portainer Edge Agent.
#
#   This script stops here. The full Docker stack (Node-RED, TimescaleDB, etc.)
#   is deployed separately via Portainer pulling from the private GitHub repo.
#
# SECURITY MODEL:
#   - All container ports are protected by DOCKER-USER iptables chain
#     (UFW alone does NOT protect Docker-published ports — this does)
#   - Tailscale is the only remote access path — no ports exposed to internet
#   - Portainer Edge Agent communicates outbound only over Tailscale
#   - No secrets are written to disk or bash history
#
# USAGE:
#   wget https://raw.githubusercontent.com/sxb009/MSP-Public/main/Initial_setup.sh
#   cat Initial_setup.sh          # Always verify before running
#   chmod +x Initial_setup.sh
#   sudo ./Initial_setup.sh
# ==============================================================================


# ==============================================================================
# CONFIGURATION — REVIEW BEFORE EVERY DEPLOYMENT
# ==============================================================================

# MudroLogic maintenance SSH public key.
# This is a PUBLIC key and is safe in a public repo — only the matching private
# key can authenticate. It MUST be the real key: the script refuses to run with
# the placeholder, because a malformed entry in authorized_keys fails silently
# and you would only discover it when you needed emergency access.
MUDRO_SSH_PUBKEY="REPLACE_WITH_REAL_ED25519_PUBLIC_KEY"

# Should Grafana (port 3000) be reachable from the factory LAN?
#   true  — factory floor staff can open dashboards without Tailscale.
#           Grafana's login page is then exposed to every device on the LAN.
#   false — Grafana is reachable only over Tailscale, like every other service.
#
# This must be set deliberately. The previous version of this script claimed
# LAN access was enabled while the firewall rules actually blocked it.
GRAFANA_LAN_ACCESS=true
GRAFANA_PORT=3000

# Directory Portainer deploys the stack into — the compose file uses relative
# bind mounts (./init, ./mosquitto/config, ./telegraf, ./grafana, ./node-red),
# so those paths must exist there with the right ownership.
# Verify this against your Portainer stack path; the default is only a guess.
STACK_DIR="${STACK_DIR:-/opt/mudrologic}"


# ==============================================================================
# 0. SETUP AND ERROR HANDLING
# ==============================================================================
# Stop immediately if any command fails — prevents partial installs
set -e

# Suppress all interactive apt prompts — critical for unattended installs
export DEBIAN_FRONTEND=noninteractive

# Capture the actual human user even when script is run with sudo.
# Without this, $USER becomes 'root' and Docker group permissions break.
ACTUAL_USER=${SUDO_USER:-$USER}

# Detect the primary external network interface (eth0, ens33, enp3s0, etc.)
# Used to configure DOCKER-USER iptables rules correctly regardless of hardware.
EXTERNAL_IF=$(ip route | grep default | awk '{print $5}' | head -1)

# --- PREFLIGHT ---------------------------------------------------------------
# Fail before touching the system rather than half-way through.

if [ -z "${EXTERNAL_IF}" ]; then
    echo "ERROR: could not detect the default network interface." >&2
    echo "       The DOCKER-USER firewall rules depend on it. Aborting." >&2
    exit 1
fi

# Reject the placeholder key. Writing it would produce an authorized_keys entry
# that never authenticates, leaving you locked out of your own maintenance account.
if [ "${MUDRO_SSH_PUBKEY}" = "REPLACE_WITH_REAL_ED25519_PUBLIC_KEY" ] \
   || [ -z "${MUDRO_SSH_PUBKEY}" ] \
   || case "${MUDRO_SSH_PUBKEY}" in *"..."*) true ;; *) false ;; esac; then
    echo "ERROR: MUDRO_SSH_PUBKEY is not set to a real public key." >&2
    echo "       Edit the CONFIGURATION block at the top of this script." >&2
    echo "       Get it with:  cat ~/.ssh/id_ed25519.pub" >&2
    exit 1
fi

echo ""
echo "=============================================="
echo "  MudroLogic Edge Provisioning Starting..."
echo "  User      : ${ACTUAL_USER}"
echo "  Interface : ${EXTERNAL_IF}"
echo "=============================================="
echo ""


# ==============================================================================
# 1. UPDATE OPERATING SYSTEM
# ==============================================================================
echo "[1/11] Updating operating system..."

sudo -E apt-get update -q
sudo -E apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    -q

# Install required utilities
# curl      — used to download Docker and Tailscale installers
# jq        — used to parse JSON in health checks and scripts
# iptables-persistent — persists DOCKER-USER rules across reboots (installed later)
sudo apt-get install -y curl jq -q

echo "      OS update complete."


# ==============================================================================
# 2. INSTALL DOCKER ENGINE AND COMPOSE PLUGIN
# ==============================================================================
echo "[2/11] Installing Docker Engine and Compose plugin..."

# Uses the official Docker convenience script — installs Docker Engine,
# containerd, and the CLI. Never use the Snap version of Docker — it causes
# volume mount permission failures with TimescaleDB and other containers.
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh -q
rm get-docker.sh

# Compose plugin gives 'docker compose' (with a space).
# This is the modern plugin — NOT the deprecated 'docker-compose' binary.
sudo apt-get install -y docker-compose-plugin -q

echo "      Docker installed."


# ==============================================================================
# 3. FIX DOCKER PERMISSIONS
# ==============================================================================
echo "[3/11] Configuring Docker permissions for: ${ACTUAL_USER}..."

# Add the actual user (not root) to the docker group.
# Without this, every docker command requires sudo after reboot.
# Takes effect after next login or reboot.
sudo usermod -aG docker "${ACTUAL_USER}"

echo "      Permissions configured."


# ==============================================================================
# 4. ENABLE DOCKER AUTOSTART
# ==============================================================================
echo "[4/11] Enabling Docker autostart on boot..."

# Critical for edge devices — stack must survive power outages automatically.
# Without this, a client power cut means the entire system stays down until
# someone manually starts Docker.
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

echo "      Autostart enabled."


# ==============================================================================
# 5. DOCKER LOG ROTATION (SSD PROTECTION)
# ==============================================================================
echo "[5/11] Configuring Docker log rotation..."

# Without this, Docker logs grow unbounded and fill the SSD on long-running
# edge devices. 10MB per file, 3 files = 30MB maximum total log storage.
# Applied globally to all containers on this host.
sudo mkdir -p /etc/docker
echo '{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}' | sudo tee /etc/docker/daemon.json > /dev/null

sudo systemctl restart docker

echo "      Log rotation configured (10MB x 3 files)."


# ==============================================================================
# 6. INSTALL AND AUTHENTICATE TAILSCALE
# ==============================================================================
echo "[6/11] Installing Tailscale VPN..."

curl -fsSL https://tailscale.com/install.sh | sh

echo ""
echo "      Tailscale installed. Authentication required."
echo "      Get a one-time auth key from: tailscale.com/admin → Settings → Auth Keys"
echo "      The key will not be shown on screen as you type."
echo ""

# read -srp: silent prompt — key is never displayed or written to terminal.
# -r prevents backslashes in the key from being mangled.
# The key is passed as a command-line flag, never stored in a file or written
# to bash history. Unset immediately after use.
read -srp "      Tailscale Auth Key: " TS_KEY
echo ""

if [ -z "${TS_KEY}" ]; then
    echo "ERROR: no auth key entered. Aborting." >&2
    exit 1
fi

echo "      Authenticating..."
# NOTE: 'tailscale up' takes --auth-key as a FLAG. There is no TAILSCALE_AUTHKEY
# environment variable — the previous version set one, which tailscale ignored
# (and which sudo stripped anyway), so the key was silently discarded and the
# command fell back to interactive browser auth. That is a dead end on a
# headless edge device.
sudo tailscale up --auth-key="${TS_KEY}" --accept-routes
unset TS_KEY

# Verify Tailscale connected and get the assigned IP for later use
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "pending")
echo "      Tailscale connected. IP: ${TAILSCALE_IP}"
echo ""
echo "      ACTION REQUIRED AFTER SCRIPT COMPLETES:"
echo "      Go to tailscale.com/admin → Machines → find this device"
echo "      Click '...' → 'Disable key expiry'"
echo "      Without this, the device drops off your network after 180 days."
echo ""


# ==============================================================================
# 7. FIREWALL AND NETWORK SECURITY
# ==============================================================================
echo "[7/11] Configuring firewall and network security..."

# --- UFW BASELINE ---
# Default deny all incoming. Only Tailscale traffic and SSH are allowed.
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Keep SSH open in case direct local access is needed during setup.
# In production you could remove this once Tailscale is confirmed working.
sudo ufw allow ssh comment "SSH - local access"

# Allow all traffic arriving on the Tailscale interface.
# This is the primary remote management path.
sudo ufw allow in on tailscale0 comment "Tailscale VPN"

# --- IP FORWARDING ---
# Required so Docker containers can reach the Tailscale VPN network.
# Without this, Telegraf cannot write to a remote TimescaleDB over Tailscale.
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
fi

# --- UFW ROUTING RULES ---
# Allow Docker containers to route traffic to and from the Tailscale VPN.
# This enables containers to reach Tailscale IPs and vice versa.
sudo ufw route allow in on docker0 out on tailscale0 comment "Docker → Tailscale"
sudo ufw route allow in on tailscale0 out on docker0 comment "Tailscale → Docker"

sudo ufw --force enable

# --- DOCKER-USER IPTABLES CHAIN ---
# CRITICAL SECURITY FIX: UFW does NOT protect Docker-published ports.
# Docker writes its own iptables rules that bypass UFW entirely.
# A container bound to 0.0.0.0:3000 is reachable from the factory LAN
# even with 'ufw default deny incoming' in place.
#
# The DOCKER-USER chain is the correct solution. Docker respects this chain
# and it is the officially documented way to add custom firewall rules
# that Docker cannot bypass.
#
# Effect: ALL container ports are blocked from the external interface.
# Only traffic arriving via tailscale0 can reach containers.
# This makes every container effectively Tailscale-only at the network level,
# regardless of what bind IP individual containers use.
#
# Grafana is the one documented exception, controlled by GRAFANA_LAN_ACCESS in
# the CONFIGURATION block. Binding Grafana to 0.0.0.0 in the compose file is NOT
# sufficient on its own — without an explicit ACCEPT rule here, the blanket DROP
# below silently blocks it. The previous version of this script had exactly that
# mismatch: it printed "accessible on factory LAN" while denying the traffic.

echo "      Applying DOCKER-USER iptables rules..."

# The DOCKER-USER chain is created by Docker. If the daemon has not populated it
# yet, create it so the inserts below cannot fail under 'set -e'.
if ! sudo iptables -n -L DOCKER-USER >/dev/null 2>&1; then
    sudo iptables -N DOCKER-USER
    sudo iptables -I FORWARD -j DOCKER-USER
fi

# Idempotency: strip any rules a previous run of this script left behind,
# otherwise re-running stacks duplicates and the effective policy drifts.
while sudo iptables -D DOCKER-USER -i "${EXTERNAL_IF}" -j DROP 2>/dev/null; do :; done
while sudo iptables -D DOCKER-USER -i "${EXTERNAL_IF}" \
    -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
while sudo iptables -D DOCKER-USER -i tailscale0 -j ACCEPT 2>/dev/null; do :; done
while sudo iptables -D DOCKER-USER -i "${EXTERNAL_IF}" -p tcp \
    --dport "${GRAFANA_PORT}" -j ACCEPT 2>/dev/null; do :; done

# Rules are inserted with -I (position 1), so the LAST insert is evaluated FIRST.
# Final evaluation order is the reverse of the order written below:
#   1. tailscale0                      ACCEPT
#   2. external + Grafana port         ACCEPT   (only if GRAFANA_LAN_ACCESS=true)
#   3. external + RELATED,ESTABLISHED  ACCEPT
#   4. external                        DROP

# 4th evaluated — default deny for container ports from the LAN/internet
sudo iptables -I DOCKER-USER -i "${EXTERNAL_IF}" -j DROP

# 3rd evaluated — responses to outbound container traffic
sudo iptables -I DOCKER-USER -i "${EXTERNAL_IF}" \
    -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# 2nd evaluated — the documented Grafana exception
if [ "${GRAFANA_LAN_ACCESS}" = "true" ]; then
    sudo iptables -I DOCKER-USER -i "${EXTERNAL_IF}" -p tcp \
        --dport "${GRAFANA_PORT}" -j ACCEPT
fi

# 1st evaluated — Tailscale always reaches containers
sudo iptables -I DOCKER-USER -i tailscale0 -j ACCEPT

# --- PERSIST IPTABLES RULES ---
# Without persistence, DOCKER-USER rules are lost on every reboot.
# iptables-persistent saves current rules and restores them at boot.
sudo apt-get install -y iptables-persistent -q
sudo netfilter-persistent save

echo "      Firewall configured."
echo "      Container ports: accessible via Tailscale only."
if [ "${GRAFANA_LAN_ACCESS}" = "true" ]; then
    echo "      Grafana (port ${GRAFANA_PORT}): ALSO reachable from the factory LAN."
else
    echo "      Grafana (port ${GRAFANA_PORT}): Tailscale only (GRAFANA_LAN_ACCESS=false)."
fi


# ==============================================================================
# 8. CREATE MUDROLOGIC MAINTENANCE USER
# ==============================================================================
echo "[8/11] Creating maintenance user..."

# A dedicated maintenance account ensures you always have access to this machine
# even if the client changes the default Ubuntu user password, or the original
# setup user account is deleted.
#
# The password is randomly generated, displayed ONCE, then wiped from memory.
# Save it to your password manager before pressing ENTER.

if ! id "mudro-admin" &>/dev/null; then
    sudo useradd -m -s /bin/bash mudro-admin
    sudo usermod -aG sudo,docker mudro-admin

    # Generate a cryptographically secure random password.
    # NOPASSWD sudoers removed intentionally — password authentication is required.
    # A random 16-character base64 password is strong enough without passwordless sudo.
    ADMIN_PASSWORD=$(openssl rand -base64 16)
    echo "mudro-admin:${ADMIN_PASSWORD}" | sudo chpasswd

    # Display password BEFORE unsetting from memory.
    # Once unset, this password cannot be recovered — it must be saved now.
    echo ""
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║    SAVE THIS PASSWORD IN YOUR PASSWORD MANAGER   ║"
    echo "  ╠═══════════════════════════════════════════════════╣"
    echo "  ║  User     : mudro-admin                          ║"
    echo "  ║  Password : ${ADMIN_PASSWORD}  ║"
    echo "  ╚═══════════════════════════════════════════════════╝"
    echo ""
    echo "  This password will NOT be shown again."
    echo "  Once you press ENTER it is wiped from memory."
    echo ""
    read -p "  Press ENTER once you have saved the password to your password manager: "

    unset ADMIN_PASSWORD

    echo "      Maintenance user created."
else
    echo "      Maintenance user already exists — skipping."
fi


# ==============================================================================
# 9. DEPLOY MUDROLOGIC SSH PUBLIC KEY
# ==============================================================================
echo "[9/11] Deploying SSH access key for mudro-admin..."

# Ensures MudroLogic can always SSH into this device as mudro-admin via key-based
# auth. The public key below is safe to store in a public repo — only the
# matching private key (kept securely by MudroLogic) can authenticate.
sudo mkdir -p /home/mudro-admin/.ssh
sudo chmod 700 /home/mudro-admin/.ssh
sudo touch /home/mudro-admin/.ssh/authorized_keys

# Validate the key actually parses before installing it. A malformed key is
# accepted by the file but silently ignored by sshd, which would leave you
# without the emergency access this whole section exists to guarantee.
if ! printf '%s\n' "${MUDRO_SSH_PUBKEY}" | ssh-keygen -l -f - >/dev/null 2>&1; then
    echo "ERROR: MUDRO_SSH_PUBKEY is not a valid SSH public key." >&2
    echo "       Refusing to install it — you would be locked out." >&2
    exit 1
fi

# Idempotent: re-running the script must not append a duplicate entry.
if sudo grep -qF "${MUDRO_SSH_PUBKEY}" /home/mudro-admin/.ssh/authorized_keys; then
    echo "      Key already present — skipping."
else
    printf '%s\n' "${MUDRO_SSH_PUBKEY}" \
        | sudo tee -a /home/mudro-admin/.ssh/authorized_keys > /dev/null
    echo "      Key installed."
fi

sudo chmod 600 /home/mudro-admin/.ssh/authorized_keys
sudo chown -R mudro-admin:mudro-admin /home/mudro-admin/.ssh

echo "      SSH key deployed."


# ==============================================================================
# 10. HARDEN SSH CONFIGURATION
# ==============================================================================
echo "[10/11] Hardening SSH configuration..."

# Disables password-based login and root login over SSH.
# After this point, only key-based authentication is accepted.
# This prevents brute-force attacks even if a weak password exists.
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

# Ubuntu 22.04+ also ships drop-in configs under /etc/ssh/sshd_config.d/ which
# are read AFTER sshd_config and would override the settings above (the cloud
# images commonly enable password auth there).
if [ -d /etc/ssh/sshd_config.d ]; then
    sudo grep -rlE '^\s*(PasswordAuthentication|PermitRootLogin)' \
        /etc/ssh/sshd_config.d/ 2>/dev/null | while read -r f; do
        sudo sed -i 's/^\s*PasswordAuthentication.*/PasswordAuthentication no/' "$f"
        sudo sed -i 's/^\s*PermitRootLogin.*/PermitRootLogin no/' "$f"
    done
fi

# Validate before restarting — a bad sshd_config plus a restart locks you out.
sudo sshd -t

# The unit is 'ssh' on Debian/Ubuntu and 'sshd' on RHEL-family.
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd

echo "      SSH hardened. Key-only access enforced."


# ==============================================================================
# 11. INSTALL PORTAINER EDGE AGENT
# ==============================================================================
echo "[11/11] Installing Portainer Edge Agent..."

# The Edge Agent registers this PC with your central Portainer dashboard.
# Once running, you deploy and manage the full Docker stack remotely via Portainer.
# The agent communicates OUTBOUND only to your central Portainer over Tailscale.
# No inbound ports are opened.
#
# Get the command from your central Portainer dashboard:
#   Environments → Add Environment → Edge Agent
#   Set the Portainer server URL to your Portainer's Tailscale IP:
#   e.g. https://100.x.x.x:9443
#
# The generated command contains a unique EDGE_ID and EDGE_KEY for this device.
# It looks like:
#   docker run -d \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v /var/lib/docker/volumes:/var/lib/docker/volumes \
#     --name portainer_edge_agent \
#     --restart always \
#     -e EDGE=1 \
#     -e EDGE_ID=xxxx-xxxx-xxxx \
#     -e EDGE_KEY=xxxx... \
#     portainer/agent:latest

echo ""
echo "  ──────────────────────────────────────────────────────"
echo "  Before continuing, generate the Edge Agent command in"
echo "  your central Portainer dashboard:"
echo ""
echo "  Environments → Add Environment → Edge Agent"
echo "  Set server URL to: https://${TAILSCALE_IP}:9443"
echo "  (Replace with your actual Portainer Tailscale IP if different)"
echo "  ──────────────────────────────────────────────────────"
echo ""

# The command is read into a variable, executed, then immediately wiped.
# It is not written to disk and does not enter your shell history (the script
# reads it, not the interactive shell). It IS visible on screen as you paste —
# the EDGE_KEY is a secret, so make sure nobody is reading over your shoulder.
#
# Read line-by-line until a blank line: Portainer generates a multi-line command
# with trailing backslashes. A plain 'read' would capture only the first line,
# and without -r it would also eat the backslashes.
echo "  Paste the full 'docker run' command."
echo "  Multi-line is fine — press ENTER on a BLANK line when done:"
PORTAINER_CMD=""
while IFS= read -r line; do
    [ -z "${line}" ] && break
    PORTAINER_CMD="${PORTAINER_CMD}${line}"$'\n'
done
echo ""

# Sanity-check before eval. This does not make eval safe against a hostile
# paste — it catches the realistic failure, which is pasting the wrong thing.
case "${PORTAINER_CMD}" in
    *docker*run*portainer/agent*) ;;
    *)
        echo "ERROR: that does not look like a Portainer agent 'docker run' command." >&2
        echo "       Nothing was executed. Re-run this script or start the agent manually." >&2
        exit 1
        ;;
esac

eval "${PORTAINER_CMD}"
unset PORTAINER_CMD line

echo "      Portainer Edge Agent installed."


# ==============================================================================
# SANITIZATION
# ==============================================================================
# Clears all sensitive variables from this subshell's memory.
# Note: your interactive terminal session history is a separate process.
# To clear that too, run the following in your terminal AFTER this script:
#   history -c && history -w
unset TS_KEY ADMIN_PASSWORD PORTAINER_CMD TAILSCALE_IP


# ==============================================================================
# STACK BIND-MOUNT DIRECTORIES
# The compose file uses relative bind mounts, so these must exist — with the
# right ownership — in the directory Portainer deploys the stack into.
#
# The previous version created these relative to whatever directory the script
# happened to be run from (usually the installing user's home), which is not
# where Portainer puts the stack. Set STACK_DIR at the top of this script to
# your actual Portainer stack path.
#
# Mosquitto in particular will not start at all without its config file present.
# ==============================================================================
echo ""
echo "      Preparing stack directories under: ${STACK_DIR}"

sudo mkdir -p "${STACK_DIR}/node-red/data"
sudo mkdir -p "${STACK_DIR}/mosquitto/data" "${STACK_DIR}/mosquitto/log"

# node-red currently runs as root in docker-compose.yml. UID 1000 matches the
# stock node-red image user, which is what you want if that is ever changed back.
sudo chown -R 1000:1000 "${STACK_DIR}/node-red/data"
sudo chown -R 1883:1883 "${STACK_DIR}/mosquitto/data" "${STACK_DIR}/mosquitto/log"

# Host backup directory (bind-mounted by the rclone backup service)
sudo mkdir -p /backups

echo "      Stack directories ready."
echo ""
echo "      NOTE: verify ${STACK_DIR} matches the path Portainer actually uses."
echo "      If it does not, the stack's relative bind mounts will not resolve"
echo "      and mosquitto will fail to start."


# ==============================================================================
# COMPLETION
# ==============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         MudroLogic Edge Provisioning Complete!          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  IMMEDIATE ACTIONS REQUIRED:                            ║"
echo "║                                                          ║"
echo "║  1. tailscale.com/admin → Machines → this device        ║"
echo "║     Click '...' → Disable key expiry                    ║"
echo "║     (Without this, access is lost after 180 days)       ║"
echo "║                                                          ║"
echo "║  2. Verify device appears in your Portainer dashboard    ║"
echo "║     as 'Associated' (may take 2-3 minutes)              ║"
echo "║                                                          ║"
echo "║  3. Clear your terminal history:                        ║"
echo "║     history -c && history -w                            ║"
echo "║                                                          ║"
echo "║  4. Reboot to apply Docker group permissions:           ║"
echo "║     sudo reboot                                         ║"
echo "║                                                          ║"
echo "║  AFTER REBOOT — deploy stack via Portainer:             ║"
echo "║  Stacks → Add Stack → Repository → your private repo    ║"
echo "║  Add environment variables in Advanced Mode             ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
