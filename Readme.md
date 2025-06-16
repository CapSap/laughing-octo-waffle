# deliver a live stock view for customers

- matrixify can upload to server so thats what we're doing. use sftp
- key needs to be added to matrixify

## step by each: what is the node app doing?

1. waiting watching for changes in the /uploads dir (what exactly is it waiting for? a new file to arrive and finish uploading.)
2. after file is uploaded, make a graphql query to upload the file
3. mv the file from /uploads to a /archive dir
4. and maybe once a week do a cleanup of all files in archive

# todos

- [ ] move the file after we're done with it
- [ ] make the graph ql upload of the file and get a success or not
- [ ]

## node setup notes

i wanted to use ts, and this may complicate the docker stuff a bit. (we have to compile ts into js)

### keep this

sftp-server:
build: ./sftp
container_name: sftp-server
ports: - "22:22" - "21000-21010:21000-21010"
volumes: - shared-data:/home/sftpuser/uploads
