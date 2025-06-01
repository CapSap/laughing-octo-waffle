FROM debian:bookworm

# Install ProFTPD with SFTP module
RUN apt-get update && apt-get install -y \
    proftpd-core\
    proftpd-mod-crypto \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN cat /etc/passwd | grep proftpd || echo "No proftpd user found"

# Create SFTP user for file uploads
RUN useradd -m -d /home/sftpuser -s /bin/false sftpuser && \
    mkdir -p /home/sftpuser/uploads && \
    chown sftpuser:sftpuser /home/sftpuser/uploads && \
    chmod 755 /home/sftpuser/uploads

# Generate server host keys (server identity for SFTP)
RUN mkdir -p /etc/proftpd/keys && \
    ssh-keygen -t rsa -b 2048 -f /etc/proftpd/keys/sftp_rsa_host_key -N "" && \
    ssh-keygen -t ecdsa -f /etc/proftpd/keys/sftp_ecdsa_host_key -N "" && \
    ssh-keygen -t ed25519 -f /etc/proftpd/keys/sftp_ed25519_host_key -N ""

# Setup client authentication - client's public key goes here
RUN mkdir -p /etc/proftpd/authorized_keys
COPY sftp_app_key.pub /etc/proftpd/authorized_keys/sftpuser

# Set proper ownership and permissions
RUN chown -R proftpd /etc/proftpd/keys && \
    chmod 600 /etc/proftpd/keys/* && \
    chown -R proftpd /etc/proftpd/authorized_keys && \
    chmod 644 /etc/proftpd/authorized_keys/sftpuser

# Copy ProFTPD configuration
COPY proftpd.conf /etc/proftpd/proftpd.conf

# Create log directory
RUN mkdir -p /var/log/proftpd && \
    chown proftpd /var/log/proftpd

# Expose SFTP port
EXPOSE 22

# Start ProFTPD in foreground
CMD ["/usr/sbin/proftpd", "--nodaemon", "--config", "/etc/proftpd/proftpd.conf"]