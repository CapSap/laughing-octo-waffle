#!/bin/bash
set -e

KEY_DIR="/etc/proftpd/keys"
KEY_FILE="$KEY_DIR/sftp_rsa_host_key"

# Generate host key if it doesn't exist
if [ ! -f "$KEY_FILE" ]; then
    echo "Generating SSH host key..."
    mkdir -p "$KEY_DIR"
    ssh-keygen -t rsa -b 2048 -f "$KEY_FILE" -N ""
    chown -R proftpd:proftpd "$KEY_DIR"
    chmod 600 "$KEY_FILE"
fi

# Start ProFTPD
exec /usr/sbin/proftpd --nodaemon --config /etc/proftpd/proftpd.conf
