FROM debian:bookworm

# Install OpenSSH server
RUN apt-get update && apt-get install -y openssh-server && \
    mkdir /var/run/sshd

# Create the sftpuser but DO NOT let them own the home directory
RUN useradd -m -d /home/sftpuser -s /usr/sbin/nologin sftpuser && \
    mkdir -p /home/sftpuser/uploads && \
    chown sftpuser:sftpuser /home/sftpuser/uploads && \
    chmod 755 /home/sftpuser

# Create .ssh directory and copy the public key
RUN mkdir -p /home/sftpuser/.ssh
COPY sftp_app_key.pub /home/sftpuser/.ssh/authorized_keys

# Set correct permissions
RUN chown -R root:root /home/sftpuser && \
    chown -R sftpuser:sftpuser /home/sftpuser/uploads && \
    chown -R sftpuser:sftpuser /home/sftpuser/.ssh && \
    chmod 755 /home/sftpuser && \
    chmod 700 /home/sftpuser/.ssh && \
    chmod 600 /home/sftpuser/.ssh/authorized_keys

# Copy sshd config
COPY sshd_config /etc/ssh/sshd_config

# Expose port
EXPOSE 22

# Start SSH
CMD ["/usr/sbin/sshd", "-D", "-e"]
