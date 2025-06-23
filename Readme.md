# deliver a live stock view for customers

- matrixify can upload to server so thats what we're doing. use sftp
- key needs to be added to matrixify

## step by each: what are each ?

1. a file arrives to the ftp server (proftp names it .in. while its being transfered. node app is ignoring .in files)
2. waiting watching for changes in the /uploads dir
3. after file is uploaded, make a graphql query to upload the file (3 parts to this step)
4. do a cleanup of all files in uploads older than 30 days

# todos

- [x] stagedUploadsCreate to get a url to upload to
- [x] upload via http post (but i have not tested yet.)
- [x] FileCreate "create" a file- make it avaliavle in the files api
- [x] store the id of the uploaded file to delete on the next upload
- [x] clean up files
- [x] upload a consistant filename to shopify

## final deployment project notes

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

# How to deploy

1. Copy over the droplet setup script into the host with scp
   `scp -i <path to key> <local file> <user@address>:~`
2. ssh into host, chmod script and Run it
   `ssh -i <path to key> <user@address>`
   `chomd +x ./script.sh`
3. copy over the local production.env as .env into host project dir (follow commands from output)
   `scp -i <path to key> <./upload-app/.env> <user@address:/opt/sl-app/.env>`
4. Run the deploy.sh script

## node setup notes

i wanted to use ts, and this may complicate the docker stuff a bit. (we have to compile ts into js)

### keep this

sftp-server:
build: ./sftp
container_name: sftp-server
ports: - "22:22" - "21000-21010:21000-21010"
volumes: - shared-data:/home/sftpuser/uploads

# notes for deploy progress

- having some trouble on server running the node
- confirmed the problem: all 5 keys are missing. env issue.

how to get docker to inject the .env into the node app?

# swarm plan

1. Prepare Droplet: Initialize Docker Swarm on your Droplet.
2. Create Secrets: Using SSH on your Droplet, you'll create a Docker secret for each of your Shopify API keys and other sensitive variables.
3. Update docker-compose.yml: Modify your docker-compose.yml file (on your local machine) to tell Docker Swarm about the secrets and how your node-app service will use them.
4. Update Node.js Code: Adjust your shop.ts file to read these secrets from the special /run/secrets/ file paths instead of process.env.
5. Deploy: Use the docker stack deploy command to deploy your entire application to the Swarm. Your deploy.sh script will be updated to handle this process.
