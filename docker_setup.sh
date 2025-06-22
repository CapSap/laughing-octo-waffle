#!/bin/bash

# --- Configuration Variables for Initial Droplet Setup ---
# These are internal to this setup script, don't change them unless you change paths on droplet
PROJECT_DIR="/opt/sl-app" # Make sure this matches PROJECT_DIR in your deploy.sh

# --- Error Handling ---
set -e
log_info() { echo -e "\n\033[1;34m=== $1 ===\033[0m"; } # Blue bold
log_error() { echo -e "\n\033[1;31m!!! ERROR: $1 !!!\033[0m"; } # Red bold

log_info "Starting initial Droplet setup..."

# 1. Update system and install basic prerequisites
log_info "Updating system packages and installing curl, gnupg..."
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release

# 2. Install Docker Engine, containerd, and Docker Compose plugin
log_info "Installing Docker Engine and Docker Compose plugin..."

# Add Docker's official GPG key:
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log_info "Verifying Docker installation..."
sudo docker run hello-world || log_error "Docker 'hello-world' test failed. Check Docker installation."

# 3. Configure Firewall (UFW)
log_info "Configuring UFW firewall..."
sudo apt install -y ufw # Ensure ufw is installed

sudo ufw allow OpenSSH         # Keep SSH access
sudo ufw allow 2222/tcp          # For proFTP 

log_info "Enabling UFW firewall. Confirm with 'y' if prompted."
sudo ufw enable || log_error "Failed to enable UFW."
sudo ufw status verbose || log_error "Failed to show UFW status."

# 4. Create Application's Project Directory
log_info "Creating application project directory: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
# No need for chown if the commands are run as root; root will own directories it creates.

log_info "Initial Droplet setup completed!"