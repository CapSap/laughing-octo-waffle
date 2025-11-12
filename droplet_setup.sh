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

# 3. Docker Swarm Initialization 
log_info "Checking Docker Swarm status and initializing if necessary..."
if [ "$(docker info --format '{{.Swarm.ControlAvailable}}')" = "true" ]; then
    echo "This node is already a Docker Swarm manager. Skipping swarm initialization."
else
    # Retrieve the private IP for --advertise-addr
    # This command uses the DigitalOcean metadata service, which is reliable.
    PRIVATE_IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/private/0/ipv4/address)

    if [ -z "$PRIVATE_IP" ]; then
        echo "Warning: Could not retrieve private IP from DigitalOcean metadata. Attempting to use a common alternative for --advertise-addr."
        # Fallback to general private IP detection or prompt if necessary
        # This might pick up 127.0.0.1 or public IP if no private network is configured.
        PRIVATE_IP=$(hostname -I | awk '{print $1}') # Tries to get any IP, often the primary one
        if [ -z "$PRIVATE_IP" ]; then
            echo "Error: Could not determine an IP for --advertise-addr. Please specify it manually or ensure private networking is configured."
            exit 1
        fi
    fi

    echo "Initializing Docker Swarm with --advertise-addr $PRIVATE_IP..."
    docker swarm init --advertise-addr "$PRIVATE_IP"

    if [ $? -eq 0 ]; then
        echo "Docker Swarm initialized successfully."
    else
        echo "Error: Docker Swarm initialization failed."
        exit 1
    fi
fi

echo "Docker setup complete."

# 3. Configure Firewall (UFW)
log_info "Configuring UFW firewall..."
sudo apt install -y ufw # Ensure ufw is installed

sudo ufw allow OpenSSH         # Keep SSH access
sudo ufw allow 2222/tcp        # For SFTP via proFTP 
sudo ufw allow 2223/tcp        # For SFTP via go-usa-app

sudo ufw allow 2377/tcp        # Docker Swarm management port (for other managers)
sudo ufw allow 7946/tcp        # for overlay network node discovery
sudo ufw allow 7946/udp        # for overlay network node discovery
sudo ufw allow 4789/udp        # (configurable) for overlay network traffic  (VXLAN)

log_info "Enabling UFW firewall. Confirm with 'y' if prompted."
sudo ufw enable || log_error "Failed to enable UFW."
sudo ufw status verbose || log_error "Failed to show UFW status."

# 4. Create Application's Project Directory
log_info "Creating application project directory: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
# No need for chown if the commands are run as root; root will own directories it creates.

log_info final manual step: create docker secrets
log_info 'use ssh-agent for only 1 x prompt "eval "$(ssh-agent -s)"'
log_info "ssh-add ~/.ssh/droplet"
log_info "ssh -i ~/.ssh/id_do_droplet_1 root@$DROPLET_HOST "
log_info "./deploy.sh"


log_info "Initial Droplet setup completed!"