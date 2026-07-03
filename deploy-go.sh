#!/bin/bash
# Targeted deploy for the go-usa-stock service only.
# Leaves pro-ftpd and node-app running untouched (no stack teardown).
if [[ "$1" == "--help" ]]; then
    echo "Usage: ./deploy-go.sh [--local]"
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
       eval "$command"
    else
        log_info "Executing remotely on $DROPLET_HOST: '$command'"
        ssh "$SSH_USER@$DROPLET_HOST" "$command"
    fi
}

# Like run_remote, but without the log banner so stdout can be captured
# into variables (log_info output would pollute command substitution).
remote_capture() {
    local command="$@"
    if [ "$IS_LOCAL" = true ]; then
       eval "$command"
    else
        ssh "$SSH_USER@$DROPLET_HOST" "$command"
    fi
}

# --- Pre-Checks ---
log_info "Performing pre-deployment checks..."
if [ -z "$DROPLET_HOST" ] && [ "$IS_LOCAL" = false ]; then
    log_error "DROPLET_HOST is not set. Please define it in deploy.env."
    exit 1
fi
if [ -z "$SSH_USER" ] && [ "$IS_LOCAL" = false ]; then
    log_error "SSH_USER is not set. Please define it in deploy.env."
    exit 1
fi
if [ -z "$PROJECT_DIR" ] && [ "$IS_LOCAL" = false ]; then
    log_error "PROJECT_DIR is not set. Please define it in deploy.env."
    exit 1
fi
if [ -z "$STACK_NAME" ] && [ "$IS_LOCAL" = false ]; then
    log_error "STACK_NAME is not set. Please define it in deploy.env (e.g., STACK_NAME=\"sl-app-stack\")."
    exit 1
fi

# In local mode: target the local test stack (same name local-testing.sh uses)
# and build straight from the current working tree — no git pull.
if [ "$IS_LOCAL" = true ]; then
    STACK_NAME="local-app-stack"
    TARGET_DIR="."
else
    TARGET_DIR="$PROJECT_DIR"
fi
log_info "Configuration looks good. Starting go-usa-stock deployment to stack '$STACK_NAME'..."

GO_SERVICE="${STACK_NAME}_go-usa-stock"

# 1. Pull latest code and update the go submodule on the Droplet.
# Skipped in local mode: the local working tree (including uncommitted
# changes) is what gets built and deployed.
if [ "$IS_LOCAL" = false ]; then
    log_info "Navigating to $PROJECT_DIR and pulling latest code..."
    run_remote "cd $PROJECT_DIR && git pull origin $GIT_BRANCH && git submodule sync && git submodule update --init"
fi

# 2. Create any MISSING secrets for the go service.
# Swarm secrets are immutable while in use, so existing ones are skipped —
# to rotate a secret value, see the rotation note in ./deploy-stack.sh.
log_info "Creating missing Docker Secrets for go-usa-stock..."

if [ -f "./go-usa-stock/.env" ]; then
    echo "Loading go-usa-stock secrets from ./go-usa-stock/.env"
    source "./go-usa-stock/.env"
else
    log_error "./go-usa-stock/.env not found."
    exit 1
fi

# Only the secrets the go-usa-stock service references in docker-compose.yml
GO_SECRETS_TO_CREATE=(
    "SANMAR_REMOTE_URL=sanmar_remote_url"
    "SANMAR_REMOTE_PORT=sanmar_remote_port"
    "SANMAR_REMOTE_USERNAME=sanmar_remote_username"
    "SANMAR_REMOTE_PASSWORD=sanmar_remote_password"
    "SENTRY_DSN=sentry_dsn"
    "CHEFWORKS_REMOTE_URL=chefworks_remote_url"
    "CHEFWORKS_REMOTE_PORT=chefworks_remote_port"
    "CHEFWORKS_REMOTE_USERNAME=chefworks_remote_username"
    "CHEFWORKS_REMOTE_PASSWORD=chefworks_remote_password"
    "CHEFWORKS_REMOTE_DIR=chefworks_remote_dir"
    "CHEFWORKS_REMOTE_FILENAME=chefworks_remote_filename"
    "CHEFWORKS_HEALTHCHECK_URL=chefworks_healthcheck_url"
    "SANMAR_HEALTHCHECK_URL=sanmar_healthcheck_url"
)

for SECRET_PAIR in "${GO_SECRETS_TO_CREATE[@]}"; do
    ENV_VAR_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f1)
    SECRET_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f2)

    if remote_capture "docker secret inspect $SECRET_NAME >/dev/null 2>&1"; then
        echo "  - Secret '$SECRET_NAME' already exists — skipping."
        continue
    fi

    SECRET_VALUE="${!ENV_VAR_NAME}"
    if [ -z "$SECRET_VALUE" ]; then
        log_error "Local .env variable '$ENV_VAR_NAME' is empty or not found. Cannot create secret '$SECRET_NAME'."
        exit 1
    fi

    echo "$SECRET_VALUE" | remote_capture "docker secret create $SECRET_NAME -" \
    || { log_error "Failed to create Docker secret '$SECRET_NAME'."; exit 1; }
    echo "  - Secret '$SECRET_NAME' created."
done

# SSH host key secrets, created from local files if missing
KEY_SECRETS=(
    "./go-usa-stock/keys/ssh_host_rsa_key_go_usa:ssh_host_rsa_key_go_usa"
    "./go-usa-stock/keys/ssh_host_rsa_key_go_usa.pub:ssh_host_rsa_key_go_usa_pub"
)

for KEY_PAIR in "${KEY_SECRETS[@]}"; do
    LOCAL_PATH=$(echo "$KEY_PAIR" | cut -d':' -f1)
    SECRET_NAME=$(echo "$KEY_PAIR" | cut -d':' -f2)

    if remote_capture "docker secret inspect $SECRET_NAME >/dev/null 2>&1"; then
        echo "  - Secret '$SECRET_NAME' already exists — skipping."
        continue
    fi

    if [ ! -f "$LOCAL_PATH" ]; then
        log_error "Key file not found at '$LOCAL_PATH'. Cannot create secret '$SECRET_NAME'."
        exit 1
    fi

    cat "$LOCAL_PATH" | remote_capture "docker secret create $SECRET_NAME -" \
    || { log_error "Failed to create Docker secret '$SECRET_NAME'."; exit 1; }
    echo "  - Secret '$SECRET_NAME' created."
done

# 3. Rebuild only the go image
log_info "Building go-usa-stock image..."
run_remote "docker build -t go-usa-stock:latest $TARGET_DIR/go-usa-stock"

# 4. Re-apply the stack. This is idempotent: Swarm only restarts services
# whose definition changed, so pro-ftpd and node-app are left alone.
PRE_VERSION=$(remote_capture "docker service inspect --format '{{.Version.Index}}' $GO_SERVICE 2>/dev/null" || echo "")

log_info "Deploying stack '$STACK_NAME' (only changed services are updated)..."
run_remote "cd $TARGET_DIR && docker stack deploy -c docker-compose.yml $STACK_NAME" \
|| { log_error "Failed to deploy Docker stack '$STACK_NAME'."; exit 1; }

# If the service spec didn't change (e.g. only the Go code changed and the
# image was rebuilt under the same :latest tag), Swarm won't restart the
# service on its own — force an update so it picks up the new local image.
POST_VERSION=$(remote_capture "docker service inspect --format '{{.Version.Index}}' $GO_SERVICE 2>/dev/null" || echo "")
if [ -n "$PRE_VERSION" ] && [ "$PRE_VERSION" == "$POST_VERSION" ]; then
    log_info "Service spec unchanged — forcing $GO_SERVICE to redeploy with the rebuilt image..."
    run_remote "docker service update --force $GO_SERVICE"
fi

# 5. Health check for the go service
log_info "Checking service '$GO_SERVICE'..."
run_remote "docker service ps $GO_SERVICE"

if [ "$IS_LOCAL" = true ]; then
    log_info "Local go-usa-stock deployment completed successfully!"
else
    log_info "go-usa-stock deployment to $DROPLET_HOST completed successfully!"
fi
