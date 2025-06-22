#!/bin/bash

# --- Load Environment Variables from local .env file ---
if [ -f "deploy.env" ]; then
    log_info "Loading configuration from deploy.env..."
    source "deploy.env"
else
    log_error "deploy.env not found! Please create it with your deployment variables."
    exit 1
fi

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
        echo 'Git repo not found, init and cloning...'; \
        git init && \
        git remote add origin $GIT_REPO_URL && \
        git pull origin $GIT_BRANCH; \
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

# 5. Health check
run_remote "cd $PROJECT_DIR && docker compose ps -a"


log_info "Deployment to $DROPLET_HOST completed successfully!"