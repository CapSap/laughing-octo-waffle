#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

STACK_NAME="local-app-stack"
COMPOSE_FILE="docker-compose.yml" # Use the main docker-compose.yml file

echo "--- Removing existing stack (if any) ---"
docker stack rm "$STACK_NAME" 2>/dev/null || true


# Wait until all services from the stack are gone
echo "Waiting for stack '$STACK_NAME' to fully remove..."
while docker stack ls | grep -q "$STACK_NAME"; do
    # Only show the output if we are still waiting
    echo -n "."
    sleep 1
done
echo "Stack '$STACK_NAME' removed."

echo "rm go app volumne"
docker volume rm -f local-app-stack_go-app

# Wait until old networks are fully cleaned up
echo "Waiting for networks from '$STACK_NAME' to be fully removed..."
while docker network ls  | grep -q "^${STACK_NAME}_"; do
    echo -n "."
    sleep 1
done
echo "All networks for '$STACK_NAME' removed."

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

echo -e "\n--- Creating/Updating Docker Secrets locally for shopify stack ---"
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
    echo "WARNING: ./.env not found. Creating dummy secrets for testing."
    REMOTE_URL="ftp.example.com"
    REMOTE_PORT="21"
    REMOTE_USERNAME="testuser"
    REMOTE_PASSWORD="testpass"
    REMOTE_DIR="/remote/dir"
    REMOTE_FILENAME="test.csv"
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

# Add go server host keys and allowed client keys
echo -e "\n--- Adding server keys ---"

# Check and create host private key
if [ -f "./go-usa-stock/keys/ssh_host_rsa_key_go_usa" ]; then
    docker secret rm ssh_host_rsa_key_go_usa 2>/dev/null || true
    docker secret create ssh_host_rsa_key_go_usa ./go-usa-stock/keys/ssh_host_rsa_key_go_usa \
    || { echo "ERROR: Failed to create ssh_host_rsa_key_go_usa secret"; exit 1; }
    echo "  ✓ Created secret: ssh_host_rsa_key_go_usa"
else
    echo "ERROR: Host key not found at ./go-usa-stock/keys/ssh_host_rsa_key_go_usa"
    exit 1
fi

# Check and create host public key
if [ -f "./go-usa-stock/keys/ssh_host_rsa_key_go_usa.pub" ]; then
    docker secret rm ssh_host_rsa_key_go_usa_pub 2>/dev/null || true
    docker secret create ssh_host_rsa_key_go_usa_pub ./go-usa-stock/keys/ssh_host_rsa_key_go_usa.pub \
    || { echo "ERROR: Failed to create ssh_host_rsa_key_go_usa_pub secret"; exit 1; }
    echo "  ✓ Created secret: ssh_host_rsa_key_go_usa_pub"
else
    echo "ERROR: Host public key not found at ./go-usa-stock/keys/ssh_host_rsa_key_go_usa.pub"
    exit 1
fi

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