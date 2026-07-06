#!/bin/bash
# Idempotent whole-stack deploy: converges the running stack onto the current
# code and secrets, with no teardown. Safe to re-run at any time:
#   - secrets are created only if missing (never removed or recreated)
#   - all images are rebuilt, but only services whose image or compose spec
#     actually changed get restarted
# Adding a new service = add it to docker-compose.yml, its build dir to
# SERVICE_NAMES/BUILD_DIRS below, and its secrets to the manifest. No new script.
#
# To rotate an existing secret (the deliberate exception, not the rule).
# Scaling to 0 does NOT release the secret: Swarm counts a secret as "in use"
# whenever a service *spec* references it, regardless of replica count. You must
# detach it from every service that references it before the secret can be removed:
#   docker service update --secret-rm <name> <stack>_<service>   # every service using it
#   docker secret rm <name>
#   ./deploy-stack.sh                             # recreates secret, re-attaches, redeploys
#
# For a brand-new droplet, run droplet_setup.sh first; this script assumes
# Docker Swarm is initialized and only converges from there.
if [[ "$1" == "--help" ]]; then
    echo "Usage: ./deploy-stack.sh [--local]"
    echo "  --local   Deploy to the local test stack from the working tree (no SSH)"
    exit 0
fi

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
log_info "Configuration looks good. Starting stack deployment to '$STACK_NAME'..."

# 1. Pull latest code and update submodules on the Droplet.
# Skipped in local mode: the local working tree (including uncommitted
# changes) is what gets built and deployed.
if [ "$IS_LOCAL" = false ]; then
    log_info "Navigating to $PROJECT_DIR and pulling latest code..."
    run_remote "cd $PROJECT_DIR && git pull origin $GIT_BRANCH && git submodule sync && git submodule update --init"
fi

# 2. Ensure every secret in the manifest exists. Swarm secrets are immutable
# while in use, so existing ones are always skipped — see the rotation note
# at the top of this file.
log_info "Ensuring Docker Secrets exist..."

# ensure_secret <secret_name> <value>
# The value is only required when the secret is missing, so routine code-only
# deploys work even if a local .env value is absent.
ensure_secret() {
    local name="$1" value="$2"
    if remote_capture "docker secret inspect $name >/dev/null 2>&1"; then
        echo "  - Secret '$name' already exists — skipping."
        return 0
    fi
    if [ -z "$value" ]; then
        log_error "Secret '$name' is missing on the swarm and no local value was found to create it."
        exit 1
    fi
    printf '%s\n' "$value" | remote_capture "docker secret create $name -" \
    || { log_error "Failed to create Docker secret '$name'."; exit 1; }
    echo "  - Secret '$name' created."
}

# node-app secrets, read from ./upload-app/.env. The file is grepped rather
# than sourced, so we strip one layer of surrounding quotes ourselves: a line
# like KEY="https://..." must yield https://... , not the quoted string. This
# mirrors what `source` does for the go secrets below. Without it the quotes
# end up inside the secret and the node app's fetch(url) throws "Invalid URL".
NODE_SECRETS=(
    "SHOPIFY_SHOP_DOMAIN=shopify_shop_domain"
    "SERVER_HOST=server_host"
    "SHOPIFY_ADMIN_API_ACCESS_TOKEN=shopify_admin_api_access_token"
    "SHOPIFY_API_KEY=shopify_api_key"
    "SHOPIFY_API_SECRET_KEY=shopify_api_secret_key"
    "EB_STOCK_ON_HAND_FILE_UPLOAD_HEALTHCHECK_URL=eb_stock_on_hand_file_upload_healthcheck_url"
)

if [ ! -f "./upload-app/.env" ]; then
    echo "WARNING: ./upload-app/.env not found — node-app secrets can be skipped but not created."
fi

for SECRET_PAIR in "${NODE_SECRETS[@]}"; do
    ENV_VAR_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f1)
    SECRET_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f2)
    SECRET_VALUE=$(grep "^${ENV_VAR_NAME}=" ./upload-app/.env 2>/dev/null | cut -d'=' -f2- | sed -E 's/^(["'"'"'])(.*)\1$/\2/')
    ensure_secret "$SECRET_NAME" "$SECRET_VALUE"
done

# go-usa-stock secrets, sourced from ./go-usa-stock/.env
GO_SECRETS=(
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

if [ -f "./go-usa-stock/.env" ]; then
    source "./go-usa-stock/.env"
else
    echo "WARNING: ./go-usa-stock/.env not found — go secrets can be skipped but not created."
fi

for SECRET_PAIR in "${GO_SECRETS[@]}"; do
    ENV_VAR_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f1)
    SECRET_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f2)
    ensure_secret "$SECRET_NAME" "${!ENV_VAR_NAME}"
done

# SSH host key secrets, created from local files if missing. Never recreated:
# NetSuite pins this host key, so rotating it must be a deliberate act.
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
        log_error "Secret '$SECRET_NAME' is missing on the swarm and key file '$LOCAL_PATH' was not found."
        exit 1
    fi

    cat "$LOCAL_PATH" | remote_capture "docker secret create $SECRET_NAME -" \
    || { log_error "Failed to create Docker secret '$SECRET_NAME'."; exit 1; }
    echo "  - Secret '$SECRET_NAME' created."
done

# 3. Rebuild all images, recording image IDs so we can tell which ones
# actually changed. An unchanged build is a fast no-op thanks to layer cache.
SERVICE_NAMES=("pro-ftpd" "node-app" "go-usa-stock")
BUILD_DIRS=("pro" "upload-app" "go-usa-stock")
PRE_IMAGES=()
POST_IMAGES=()
PRE_VERSIONS=()

log_info "Building images..."
for i in "${!SERVICE_NAMES[@]}"; do
    NAME="${SERVICE_NAMES[$i]}"
    PRE_IMAGES[$i]=$(remote_capture "docker image inspect --format '{{.Id}}' ${NAME}:latest 2>/dev/null" || echo "none")
    run_remote "docker build -t ${NAME}:latest $TARGET_DIR/${BUILD_DIRS[$i]}"
    POST_IMAGES[$i]=$(remote_capture "docker image inspect --format '{{.Id}}' ${NAME}:latest")
done

# 4. Re-apply the stack. This is idempotent: Swarm only restarts services
# whose compose definition changed.
for i in "${!SERVICE_NAMES[@]}"; do
    SVC="${STACK_NAME}_${SERVICE_NAMES[$i]}"
    PRE_VERSIONS[$i]=$(remote_capture "docker service inspect --format '{{.Version.Index}}' $SVC 2>/dev/null" || echo "")
done

log_info "Deploying stack '$STACK_NAME' (only changed services are updated)..."
run_remote "cd $TARGET_DIR && docker stack deploy -c docker-compose.yml $STACK_NAME" \
|| { log_error "Failed to deploy Docker stack '$STACK_NAME'."; exit 1; }

# Because images are all tagged :latest, Swarm can't see when only the image
# content changed: if a service's spec is untouched it won't restart on its
# own. Force-update exactly those services whose image was rebuilt to a new
# ID but whose spec the deploy left alone.
for i in "${!SERVICE_NAMES[@]}"; do
    NAME="${SERVICE_NAMES[$i]}"
    SVC="${STACK_NAME}_${NAME}"

    if [ "${PRE_IMAGES[$i]}" == "${POST_IMAGES[$i]}" ]; then
        echo "  - $NAME: image unchanged — leaving service alone."
        continue
    fi

    POST_VERSION=$(remote_capture "docker service inspect --format '{{.Version.Index}}' $SVC 2>/dev/null" || echo "")
    if [ -n "${PRE_VERSIONS[$i]}" ] && [ "${PRE_VERSIONS[$i]}" == "$POST_VERSION" ]; then
        log_info "$NAME: new image but unchanged spec — forcing redeploy..."
        run_remote "docker service update --force $SVC"
    else
        echo "  - $NAME: service spec changed — Swarm already redeployed it with the new image."
    fi
done

# 5. Health check
log_info "Checking stack '$STACK_NAME'..."
run_remote "docker stack ps $STACK_NAME"

if [ "$IS_LOCAL" = true ]; then
    log_info "Local stack deployment completed successfully!"
else
    log_info "Stack deployment to $DROPLET_HOST completed successfully!"
fi
