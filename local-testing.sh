#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

STACK_NAME="local-app-stack"
COMPOSE_FILE="docker-compose.yml" # Use the main docker-compose.yml file

echo "--- Initializing Docker Swarm (if not already) ---"
docker swarm init 2>/dev/null || true

echo "--- Building images locally ---"

docker build -t "pro-ftpd:latest" ./pro || {
    echo "ERROR: Failed to build pro-ftpd image."
    exit 1
}

docker build -t "node-app:latest" ./upload-app || {
    echo "ERROR: Failed to build node-app image."
    exit 1
}

docker build -t "go-usa-app:latest" ./go-usa-stock || {
    echo "ERROR: Failed to build go-usa-app image."
    exit 1
}

for IMAGE in "pro-ftpd:latest" "node-app:latest" "go-usa-app:latest"; do
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "ERROR: Image '$IMAGE' does not exist after build. Aborting."
        exit 1
    fi
done

echo "--- Creating/Updating Docker Secrets locally ---"
SECRETS_TO_CREATE=(
    "SHOPIFY_SHOP_DOMAIN=shopify_shop_domain"
    "SERVER_HOST=server_host"
    "SHOPIFY_ADMIN_API_ACCESS_TOKEN=shopify_admin_api_access_token"
    "SHOPIFY_API_KEY=shopify_api_key"
    "SHOPIFY_API_SECRET_KEY=shopify_api_secret_key"
)

if [ ! -f "./upload-app/.env" ]; then
    echo "ERROR: Local .env file not found at ./upload-app/.env. Cannot create secrets."
    exit 1
fi
source "./upload-app/.env"

for SECRET_PAIR in "${SECRETS_TO_CREATE[@]}"; do
    ENV_VAR_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f1)
    SECRET_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f2)

    SECRET_VALUE="${!ENV_VAR_NAME}"

    if [ -z "$SECRET_VALUE" ]; then
        echo "ERROR: Local .env variable '$ENV_VAR_NAME' is empty or not found after sourcing. Cannot create secret '$SECRET_NAME'."
        exit 1
    fi

    docker secret rm "$SECRET_NAME" 2>/dev/null || true

    echo "$SECRET_VALUE" | docker secret create "$SECRET_NAME" - \
    || { echo "ERROR: Failed to create Docker secret '$SECRET_NAME'."; exit 1; }
    echo "  - Secret '$SECRET_NAME' created/updated."
done


# New secrets for go-usa-app
echo "--- Creating secrets for go-usa-app ---"

GO_SECRETS_TO_CREATE=(
    "GO_REMOTE_URL=go_remote_url"
    "GO_REMOTE_PORT=go_remote_port"
    "GO_REMOTE_USERNAME=go_remote_username"
    "GO_REMOTE_PASSWORD=go_remote_password"
    "GO_REMOTE_DIR=go_remote_dir"
    "GO_REMOTE_FILENAME=go_remote_filename"
    "SENTRY_DSN=sentry_dsn"
)

# Check if go app .env exists, if not create dummy values for testing
if [ -f "./go-usa-stock/.env" ]; then
    echo "Loading go-usa-app secrets from ./.env"
    source "./go-use-stock/.env"
else
    echo "WARNING: ./.env not found. Creating dummy secrets for testing."
    GO_REMOTE_URL="ftp.example.com"
    GO_REMOTE_PORT="21"
    GO_REMOTE_USERNAME="testuser"
    GO_REMOTE_PASSWORD="testpass"
    GO_REMOTE_DIR="/remote/dir"
    GO_REMOTE_FILENAME="test.csv"
    SENTRY_DSN="https://dummy@sentry.io/123456"
fi

for SECRET_PAIR in "${GO_SECRETS_TO_CREATE[@]}"; do
    ENV_VAR_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f1)
    SECRET_NAME=$(echo "$SECRET_PAIR" | cut -d'=' -f2)
    SECRET_VALUE="${!ENV_VAR_NAME}"
    
    if [ -z "$SECRET_VALUE" ]; then
        echo "WARNING: Variable '$ENV_VAR_NAME' is empty. Creating empty secret '$SECRET_NAME'."
        SECRET_VALUE="dummy"
    fi
    
    docker secret rm "$SECRET_NAME" 2>/dev/null || true
    echo "$SECRET_VALUE" | docker secret create "$SECRET_NAME" - \
    || { echo "ERROR: Failed to create Docker secret '$SECRET_NAME'."; exit 1; }
    echo "  - Secret '$SECRET_NAME' created/updated."
done


# --- DIAGNOSTIC STEP: Check if secrets are listed immediately after creation ---
echo "--- Verifying secrets are listed by Docker Swarm before deploy ---"
docker secret ls

echo "--- Deploying stack locally using '$COMPOSE_FILE' ---"
docker stack deploy -c "$COMPOSE_FILE" "$STACK_NAME"

echo "--- Deployment initiated. Check status with 'docker stack ps $STACK_NAME' ---"
echo "--- Or view logs with 'docker service logs node-app' ---"

echo ""
echo "To clean up all components locally after testing:"
echo "docker stack rm $STACK_NAME && docker secret rm $(docker secret ls -q --filter name=${STACK_NAME}_) && docker image rm pro-ftpd:latest node-app:latest"