# deliver a live stock view for customers

- matrixify can upload to server so thats what we're doing. use sftp
- key needs to be added to matrixify

## step by each: what is the node app doing?

1. waiting watching for changes in the /uploads dir (what exactly is it waiting for? a new file to arrive and finish uploading.)
2. after file is uploaded, make a graphql query to upload the file
3. mv the file from /uploads to a /archive dir
4. and maybe once a week do a cleanup of all files in archive

# todos

- [x] stagedUploadsCreate to get a url to upload to
- [x] upload via http post (but i have not tested yet.)
- [x] FileCreate "create" a file- make it avaliavle in the files api
- [x] store the id of the uploaded file to delete on the next upload
- [x] clean up files
- [x] upload a consistant filename to shopify

## final mile

question

- how do we want to name the files?
  - matrixify can have dynamic filenames with date/time
- i think that we need to have a consistant name within the shopify cdn / so that we can find the file name when using the file filter

## node setup notes

i wanted to use ts, and this may complicate the docker stuff a bit. (we have to compile ts into js)

### keep this

sftp-server:
build: ./sftp
container_name: sftp-server
ports: - "22:22" - "21000-21010:21000-21010"
volumes: - shared-data:/home/sftpuser/uploads
