FROM debian:bookworm

# Install ProFTPD with SFTP module
RUN apt-get update && apt-get install -y \
    proftpd-core\
    proftpd-mod-sftp-ldap \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Create the sftpuser
RUN useradd -m -d /home/sftpuser -s /usr/sbin/nologin sftpuser && \
    mkdir -p /home/sftpuser/uploads && \
    chown sftpuser:sftpuser /home/sftpuser/uploads && \
    chmod 755 /home/sftpuser

# Generate SSH host keys for SFTP
RUN mkdir -p /etc/proftpd/keys && \
    ssh-keygen -t rsa -b 2048 -f /etc/proftpd/keys/sftp_rsa_host_key -N "" && \
    ssh-keygen -t ecdsa -f /etc/proftpd/keys/sftp_ecdsa_host_key -N "" && \
    ssh-keygen -t ed25519 -f /etc/proftpd/keys/sftp_ed25519_host_key -N ""

# Create directory for authorized keys
RUN mkdir -p /etc/proftpd/authorized_keys

# Copy the public key for user authentication
COPY sftp_app_key.pub /etc/proftpd/authorized_keys/sftpuser

# Set proper permissions for keys
RUN chown -R proftpd:proftpd /etc/proftpd/keys && \
    chmod 600 /etc/proftpd/keys/* && \
    chown -R proftpd:proftpd /etc/proftpd/authorized_keys && \
    chmod 644 /etc/proftpd/authorized_keys/sftpuser

# Copy ProFTPD configuration
COPY proftpd.conf /etc/proftpd/proftpd.conf

# Create necessary directories
RUN mkdir -p /var/log/proftpd && \
    chown proftpd:proftpd /var/log/proftpd

# Expose SFTP port
EXPOSE 22

# Start ProFTPD
CMD ["/usr/sbin/proftpd", "--nodaemon", "--config", "/etc/proftpd/proftpd.conf"]