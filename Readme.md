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

## final delivery

- how much do i need to think about security and hardening?
- what platform should we deploy to?
  easy answer is a digital ocean droplett.
  why? learn more about DO and running a service

i think i could be handleing secrets better. use docker to handle the .env vars that the node app needs. also could have the pub key in the docker host

and i need to get the networking working from matrixify to the ftp server

- i could allow matrixify only and block everything else.
- alex has been targeted with ..?
- and i dont know how to protect against these.

and should i restrict ports?

and add fail2ban?

plan from here

- [x] verify that upload from matrixify works. (private key works, and target dir is / on the job)
- [ ] deploy!

things that i wont do just yet

- [ ] use docker secret instead of .env (i think this is safe enough)
- [ ] add fail2ban (lets see if there is a need)
- [ ] whitelist ip address (this can be done in digital ocean)

## node setup notes

i wanted to use ts, and this may complicate the docker stuff a bit. (we have to compile ts into js)

### keep this

sftp-server:
build: ./sftp
container_name: sftp-server
ports: - "22:22" - "21000-21010:21000-21010"
volumes: - shared-data:/home/sftpuser/uploads
