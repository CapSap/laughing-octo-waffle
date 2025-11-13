#!/bin/bash
if [[ "$1" == "--help" ]]; then
    echo "Usage: ./deploy.sh [--local]"
    echo "  --local   Run all commands locally (no SSH)"
    exit 0
fi

# catch the --local flag
IS_LOCAL=false
if [ "$1" == "--local" ]; then
  IS_LOCAL=true
fi

# --- Functions ---
log_info() { echo -e "\n\033[1;34m=== $1 ===\033[0m"; }
log_error() { echo -e "\n\033[1;31m!!! ERROR: $1 !!!\033[0m"; }

# --- Load Environment Variables from local .env file ---
if [ -f "deploy.env" ]; then
    log_info "Loading configuration from deploy.env..."
    source "deploy.env"
else
    log_error "deploy.env not found! Please create it with your deployment variables."
    exit 1
fi

if [ "$IS_LOCAL" = false ]; then
    # Check if SSH agent is running
    if [ -z "$SSH_AUTH_SOCK" ]; then
        log_error "SSH agent is not running. Please start it with:"
        echo ""
        echo "  eval \$(ssh-agent -s)"
        echo "  ssh-add ~/.ssh/<KEY NAME HERE>"
        echo ""
        exit 1
    fi

    # Optional: check if any keys are loaded
    if ! ssh-add -l >/dev/null 2>&1; then
        log_error "No SSH keys loaded in agent. Please run:"
        echo ""
        echo "  ssh-add ~/.ssh/<KEY NAME HERE>"
        echo ""
        exit 1
    fi
fi

# --- Error Handling ---
set -e # Exit immediately if a command exits with a non-zero status.


run_remote() {
    local command="$@"
    if [ "$IS_LOCAL" = true ]; then
        (cd "$PROJECT_DIR" && eval "$command")
    else 
        log_info "Executing remotely on $DROPLET_HOST: '$command'"
        # using ssh-agent now so don't need to specific the key path
        # ssh -i "$SSH_KEY_PATH" "$SSH_USER@$DROPLET_HOST" "$command"
        ssh "$SSH_USER@$DROPLET_HOST" "$command"
    fi
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
if [ -z "$PROJECT_DIR" ]; then
    log_error "PROJECT_DIR is not set. Please define it in deploy.env."
    exit 1
fi
if [ -z "$STACK_NAME" ]; then
    log_error "STACK_NAME is not set. Please define it in deploy.env (e.g., STACK_NAME=\"sl-app-stack\")."
    exit 1
fi
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
    fi && \
    git submodule update --init && \
    cd ./go-usa-stock && \
    git checkout mono && \
    git pull origin mono && \
    cd .. 
    "

# 2. Create Docker Secrets on the remote Droplet
log_info "Creating/Updating Docker Secrets on the Droplet..."

# Define your secrets here, reading from your local .env file
# Ensure these names match what you'll use in docker-compose.yml
SECRETS_TO_CREATE=(
    "SHOPIFY_SHOP_DOMAIN=shopify_shop_domain"
    "SERVER_HOST=server_host"
    "SHOPIFY_ADMIN_API_ACCESS_TOKEN=shopify_admin_api_access_token"
    "SHOPIFY_API_KEY=shopify_api_key"
    "SHOPIFY_API_SECRET_KEY=shopify_api_secret_key"
)

for SECRET_PAIR in "${SECRETS_TO_CREATE[@]}"; do
    ENV_VAR_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f1)
    SECRET_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f2)

    # Read the value from the local .env file
    SECRET_VALUE=$(grep "^${ENV_VAR_NAME}=" ./upload-app/.env | cut -d'=' -f2-)

    if [ -z "$SECRET_VALUE" ]; then
        log_error "Local .env variable '$ENV_VAR_NAME' is empty or not found. Cannot create secret '$SECRET_NAME'."
        exit 1
    fi

    # UPDATED: Using run_remote for secret removal
    run_remote "docker secret rm $SECRET_NAME || true"

    # UPDATED: Using run_remote for secret creation
    # The 'echo' needs to happen on the local machine and then piped via ssh opened by run_remote.
    echo "$SECRET_VALUE" | run_remote "docker secret create $SECRET_NAME -" \
    || log_error "Failed to create Docker secret '$SECRET_NAME'."
    echo "  - Secret '$SECRET_NAME' created/updated."
done

# create go app secrets
# New secrets for go-usa-app
echo -e "\n--- Creating secrets for go-usa-app ---"

GO_SECRETS_TO_CREATE=(
    "REMOTE_URL=go_remote_url"
    "REMOTE_PORT=go_remote_port"
    "REMOTE_USERNAME=go_remote_username"
    "REMOTE_PASSWORD=go_remote_password"
    "REMOTE_DIR=go_remote_dir"
    "REMOTE_FILENAME=go_remote_filename"
    "SENTRY_DSN=sentry_dsn"
)

# Check if go app .env exists, if not create dummy values for testing
if [ -f "./go-usa-stock/.env" ]; then
    echo "Loading go-usa-app secrets from ./go-usa-stock.env"
    source "./go-usa-stock/.env"
else
    echo "WARNING: ./go-usa-stock/.env not found. "
    exit 1
fi

for SECRET_PAIR in "${GO_SECRETS_TO_CREATE[@]}"; do
    ENV_VAR_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f1)
    SECRET_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f2)
    SECRET_VALUE="${!ENV_VAR_NAME}"
    
    if [ -z "$SECRET_VALUE" ]; then
        echo "ERROR: Local .env variable '$ENV_VAR_NAME' is empty or not found after sourcing. Cannot create secret '$SECRET_NAME'."
        exit 1
    fi
    
    run_remote docker secret rm "$SECRET_NAME" 2>/dev/null || true
    echo "$SECRET_VALUE" | run_remote docker secret create "$SECRET_NAME" - \
    || { echo "ERROR: Failed to create Docker secret '$SECRET_NAME'."; exit 1; }
    echo "  - Secret '$SECRET_NAME' created/updated."
done

# Define the local paths and corresponding secret names
KEY_SECRETS=(
    "./go-usa-stock/keys/ssh_host_rsa_key_go_usa:ssh_host_rsa_key_go_usa"
    "./go-usa-stock/keys/ssh_host_rsa_key_go_usa.pub:ssh_host_rsa_key_go_usa_pub"
)

for KEY_PAIR in "${KEY_SECRETS[@]}"; do
    LOCAL_PATH=$(echo "$KEY_PAIR" | cut -d':' -f1)
    SECRET_NAME=$(echo "$KEY_PAIR" | cut -d':' -f2)

    if [ ! -f "$LOCAL_PATH" ]; then
        log_error "Key file not found at '$LOCAL_PATH'. Cannot create secret '$SECRET_NAME'."
        exit 1
    fi

    # 1. Remove the old secret remotely
    run_remote "docker secret rm $SECRET_NAME 2>/dev/null || true"

    # 2. Create the new secret remotely by piping the local file content
    echo "  - Creating secret '$SECRET_NAME' from local file '$LOCAL_PATH'"
    # The secret name is passed as an argument to the remote command.
    # The file content is read locally and piped to the remote 'docker secret create'.
    cat "$LOCAL_PATH" | run_remote "docker secret create $SECRET_NAME -" \
    || log_error "Failed to create Docker secret '$SECRET_NAME'."
    echo "   Secret '$SECRET_NAME' created successfully"  # Add this line

done

# 3. Stop existing containers gracefully
log_info "Stopping existing containers..."
run_remote "cd $PROJECT_DIR && docker compose down || true"

# 3. Stop existing Docker Swarm stack gracefully (optional, but good for clean redeploy)
log_info "Stopping existing Docker Swarm stack '$STACK_NAME' if it exists..."
run_remote "docker stack rm $STACK_NAME || true" # Use '|| true' to prevent script exit if stack doesn't exist

# build
run_remote docker build -t pro-ftpd:latest $PROJECT_DIR/pro
run_remote docker build -t node-app:latest $PROJECT_DIR/upload-app
run_remote docker build -t go-usa-stock:latest $PROJECT_DIR/go-usa-stock

# 4. Deploy the Docker Swarm stack
log_info "Deploying Docker Swarm stack '$STACK_NAME'..."
# `docker stack deploy` will automatically build images if 'build' context is defined in docker-compose.yml
run_remote "cd $PROJECT_DIR && docker stack deploy -c docker-compose.yml $STACK_NAME" \
|| log_error "Failed to deploy Docker stack '$STACK_NAME'."

# 5. Health check for Swarm services
log_info "Checking Docker Swarm services for stack '$STACK_NAME'..."
run_remote "docker stack ps $STACK_NAME"

if [ "$IS_LOCAL" = true ]; then
    log_info "Local deployment completed successfully!"
else
    log_info "Deployment to $DROPLET_HOST completed successfully!"
fi
