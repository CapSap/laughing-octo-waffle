#!/bin/bash

# --- Load Environment Variables from local .env file ---
# IMPORTANT: Ensure 'local_deploy.env' is NOT committed to Git if it contains secrets!
# For production secrets (e.g., DB passwords), they should live ONLY on the Droplet's .env file.
if [ -f "local_deploy.env" ]; then
    log_info "Loading configuration from local_deploy.env..."
    source "local_deploy.env"
else
    log_error "local_deploy.env not found! Please create it with your deployment variables."
    exit 1
fi

# --- Configuration Variables (These will be overwritten by local_deploy.env if present) ---
# If local_deploy.env is not used, or for default values, you can keep these.
# They are now fallback/default values if not defined in the sourced .env file.
# Example: DROPLET_HOST="${DROPLET_HOST:-default_droplet_ip}"
# For simplicity, remove them if you strictly use local_deploy.env for all vars.
# I'll keep them commented for clarity that they'd be redundant if local_deploy.env is complete.
# DROPLET_HOST="your_droplet_ip_or_hostname"
# SSH_KEY_PATH="~/.ssh/id_do_droplet_1"
# SSH_USER="root"
# PROJECT_DIR="/opt/your_project_name"
# GIT_REPO_URL="https://github.com/your_username/your_repo.git"
# GIT_BRANCH="main"

# --- Error Handling ---
set -e # Exit immediately if a command exits with a non-zero status.

# --- Functions ---
log_info() { echo -e "\n\033[1;34m=== $1 ===\033[0m"; }
log_error() { echo -e "\n\033[1;31m!!! ERROR: $1 !!!\033[0m"; }
run_remote() {
    local command="$@"
    log_info "Executing remotely on $DROPLET_HOST: '$command'"
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$DROPLET_HOST" "$command"
}

# --- Pre-Checks ---
log_info "Performing pre-deployment checks..."
if [ ! -f "$SSH_KEY_PATH" ]; then
    log_error "SSH private key not found at $SSH_KEY_PATH. Please verify the path and permissions (chmod 400)."
    exit 1
fi
if [ -z "$DROPLET_HOST" ]; then # Check if variable is empty after sourcing
    log_error "DROPLET_HOST is not set. Please define it in local_deploy.env."
    exit 1
fi
if [ -z "$SSH_USER" ]; then
    log_error "SSH_USER is not set. Please define it in local_deploy.env."
    exit 1
fi
# Add similar checks for other critical variables
log_info "Configuration looks good. Starting deployment..."

# --- Deployment Steps (These remain the same as before) ---

# 1. Navigate to project directory on Droplet and pull latest code
log_info "Navigating to $PROJECT_DIR and pulling latest code..."
run_remote "cd $PROJECT_DIR && \
    if [ -d .git ]; then \
        echo 'Git repo exists, pulling...'; \
        git pull origin $GIT_BRANCH; \
    else \
        echo 'Git repo not found, cloning...'; \
        git clone $GIT_REPO_URL .; \
    fi"

# 2. Handle .env file (Reminder for secure practice)
log_info "REMINDER: Production .env file must exist in $PROJECT_DIR on the Droplet (not in Git)."
log_info "It was set up by droplet_setup.sh or manually. Ensure it's current if secrets changed."

# 3. Stop existing containers gracefully
log_info "Stopping existing containers..."
run_remote "cd $PROJECT_DIR && docker compose down || true"

# 4. Build/Pull Docker images and bring up services
log_info "Building new Docker images and bringing up services..."
run_remote "cd $PROJECT_DIR && docker compose build --no-cache && docker compose up -d"

# 5. (Optional) Basic health check for Node.js server
log_info "Performing basic health check on Node.js service..."
run_remote "curl -f http://localhost:3000/health || { echo 'Health check failed for Node.js!'; exit 1; }"
log_info "Node.js service appears to be running on localhost:3000"

log_info "Deployment to $DROPLET_HOST completed successfully!"