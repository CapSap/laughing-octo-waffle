FROM debian:bullseye

RUN apt-get update && \
    apt-get install -y vsftpd && \
    useradd -m ftpuser && echo "ftpuser:ftppass" | chpasswd && \
    mkdir -p /home/ftpuser/uploads && \
    mkdir -p /var/run/vsftpd/empty && \
    chown ftpuser:ftpuser /home/ftpuser/uploads

COPY vsftpd.conf /etc/vsftpd.conf

EXPOSE 21
EXPOSE 21000-21010

CMD ["/usr/sbin/vsftpd", "/etc/vsftpd.conf"]
