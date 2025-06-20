FROM debian:bookworm

# Install ProFTPD with SFTP module
RUN apt-get update && apt-get install -y \
    proftpd-core \
    proftpd-mod-crypto \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

    # Create proftpd group and assign proftpd user to it
RUN groupadd proftpd && usermod -g proftpd proftpd

# Create SFTP user for file uploads
RUN useradd -m -d /home/sftpuser -s /bin/false sftpuser && \
    mkdir -p /home/sftpuser/uploads && \
    chown sftpuser:sftpuser /home/sftpuser/uploads && \
    chmod 755 /home/sftpuser/uploads

# Setup client authentication directory
RUN mkdir -p /etc/proftpd/authorized_keys && \
    chown proftpd:proftpd /etc/proftpd/authorized_keys

# Copy the original OpenSSH public key to a temporary location in the image
COPY sftp_app_key.pub /tmp/sftp_app_openssh.pub
COPY she_ftp_key.pub /tmp/she_ftp_key_openssh.pub

# Convert the OpenSSH public key to RFC4716 format and place it in the final location.
# The `ssh-keygen -e` command outputs to standard output, so we redirect it.
# Then, clean up the temporary file.
RUN ssh-keygen -e -f /tmp/sftp_app_openssh.pub -m RFC4716 > /etc/proftpd/authorized_keys/sftpuser && \
    rm /tmp/sftp_app_openssh.pub

RUN ssh-keygen -e -f /tmp/she_ftp_key_openssh.pub -m RFC4716 >> /etc/proftpd/authorized_keys/sftpuser && \
    rm /tmp/she_ftp_key_openssh.pub
# Set the correct ownership and permissions on the final RFC4716 formatted key file
RUN chmod 644 /etc/proftpd/authorized_keys/sftpuser && \
    chown proftpd:proftpd /etc/proftpd/authorized_keys/sftpuser

    # Copy ProFTPD configuration
COPY proftpd.conf /etc/proftpd/proftpd.conf

# Create log directory
RUN mkdir -p /var/log/proftpd && \
    chown proftpd:proftpd /var/log/proftpd

# Expose SFTP port (changed to 2222 to match config)
EXPOSE 2222

# Copy entrypoint script
COPY entry.sh /entry.sh
RUN chmod +x /entry.sh

# Start using script instead of ProFTPD directly
CMD ["/entry.sh"]