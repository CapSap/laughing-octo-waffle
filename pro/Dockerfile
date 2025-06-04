FROM debian:bookworm

# Install ProFTPD with SFTP module
RUN apt-get update && apt-get install -y \
    proftpd-core \
    proftpd-mod-crypto \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN id proftpd && getent group | grep proftpd

RUN cat /etc/passwd | grep proftpd || echo "No proftpd user found"

# Create SFTP user for file uploads
RUN useradd -m -d /home/sftpuser -s /bin/false sftpuser && \
    mkdir -p /home/sftpuser/uploads && \
    chown sftpuser:sftpuser /home/sftpuser/uploads && \
    chmod 755 /home/sftpuser/uploads

# Generate server host key (simplified to just RSA for now)
RUN mkdir -p /etc/proftpd/keys && \
    ssh-keygen -t rsa -b 2048 -f /etc/proftpd/keys/sftp_rsa_host_key -N "" && \
    chown -R proftpd /etc/proftpd/keys && \
    chmod 600 /etc/proftpd/keys/*

# Setup client authentication directory
RUN mkdir -p /etc/proftpd/authorized_keys && \
    chown proftpd /etc/proftpd/authorized_keys

# Copy client's public key
COPY sftp_app_key.pub /etc/proftpd/authorized_keys/sftpuser
RUN chmod 644 /etc/proftpd/authorized_keys/sftpuser && \
    chown proftpd /etc/proftpd/authorized_keys/sftpuser

# Copy ProFTPD configuration
COPY proftpd.conf /etc/proftpd/proftpd.conf

# Create log directory
RUN mkdir -p /var/log/proftpd && \
    chown proftpd /var/log/proftpd

# Expose SFTP port (changed to 2222 to match config)
EXPOSE 2222

# Start ProFTPD in foreground
CMD ["/usr/sbin/proftpd", "--nodaemon", "--config", "/etc/proftpd/proftpd.conf"]


