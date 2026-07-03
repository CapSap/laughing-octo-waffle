# docker swarm orchestrator + deliver a live stock view for customers

- Problem this app is solving: We want to provide our customers with a live stock level.
  - matrixify can upload to server so thats what we're doing. using sftp
  - And then we upload this file back to shopify
  - and use the liquid filter {{ 'file.csv' | file_url }} to provide a url in our theme

## step by each: a more detailed breakdown of the app's workflow

1. matrixify (shopify app) can upload a file via ftp to our server
2. a file arrives to the ftp server (proftp names it .in. while its being transfered. node app is ignoring .in files)
3. node app is watching for changes in the /uploads dir
4. after file is uploaded to our server, upload the file to shopify (3 parts to this step)
   a. delete the previous file (if exists)
   b. make a stagedUploads graphql request to get an upload url (shopify does not allow us to upload directly- instead we upload via a pre-signed upload URL that points to storage infrastructure associated with their CDN. Uploading to this URL sends the file data directly to the storage endpoint, bypassing Shopify’s main application servers)
   c. upload the file to the returned target upload url
   d. "register" the file so that is avaliable in our CDN
5. do a cleanup of all files in uploads older than 30 days

## Project notes + challenges

This app is deployed to digital ocean- reason for this is to learn a little more about this platform and to help troubleshoot another app deployed here.
The two main components are an FTP server and a node app. I went through 2 different ftp servers before settling on pro-ftpd. This one has an option HiddenStores for 2 stage uploads. While the file is being upload it has a .in. prefix to the name which can be ignored

A challenge was handleing the env variables/secrets for the node app- to handle this I am using docker swarm. Another challenge that im still working out is how to handle updates, monitoring and long term maintance of this thing

# How to deploy

1. Copy over the droplet_setup.sh script into the host with scp. This will install docker and other needed things for first time setup
   `scp -i <path to key> <local file> <user@address>:~`
2. ssh into host, chmod script and Run it
   `ssh -i <path to key> <user@address>`
   `chomd +x ./script.sh`
3. on local machine run the deploy-full-reset.sh script (this will connect via ssh, run git and docker commands remotely, and passes in local env vars from host machine). Don't forget to run ssh-agent

Which deploy script to use:

- `deploy-stack.sh` — the everyday one. Idempotent whole-stack deploy: creates only missing secrets, rebuilds images, and restarts only services whose image or spec changed. No downtime for untouched services.
- `deploy-go.sh` — targeted go-usa-stock-only deploy (subset of deploy-stack.sh).
- `deploy-full-reset.sh` — DESTRUCTIVE. Fresh-droplet bootstrap or deliberate start-over: tears down the whole stack and recreates all secrets (including the SFTP host key NetSuite pins). See warning at the top of the script.

# swarm plan for me

1. Prepare Droplet: Initialize Docker Swarm on your Droplet.
2. Create Secrets: Using SSH on your Droplet, you'll create a Docker secret for each of your Shopify API keys and other sensitive variables.
3. Update docker-compose.yml: Modify your docker-compose.yml file (on your local machine) to tell Docker Swarm about the secrets and how your node-app service will use them.
4. Update Node.js Code: Adjust your shop.ts file to read these secrets from the special /run/secrets/ file paths instead of process.env.
5. Deploy: Use the docker stack deploy command to deploy your entire application to the Swarm. Your deploy scripts handle this process.

# How to push changes

- merge into main

# todos

- [x] stagedUploadsCreate to get a url to upload to
- [x] upload via http post (but i have not tested yet.)
- [x] FileCreate "create" a file- make it avaliavle in the files api
- [x] store the id of the uploaded file to delete on the next upload
- [x] clean up files
- [x] upload a consistant filename to shopify
- [x] verify that upload from matrixify works. (private key works, and target dir is / on the job)
- [x] add fail2ban (lets see if there is a need)
- [x] whitelist ip address (this can be done in digital ocean)
- [x] deploy!
- [x] use a more efficient docker image (we could build the node ts app in a builder image and then remove the build tools/src files and run it with a barebones docker node image)

## low priority - cant be bothered right now, only if i have the energy some day

- [ ] node app: report caught upload failures to sentry with captureException (right now catch blocks only console.error + ping healthchecks /fail, so sentry issue alerts never fire for uploads. go app already does this via Notify())
- [ ] sentry: set a real release (git sha at build time) and environment in both apps instead of hardcoded "dev" - makes regression detection ("resolved becomes unresolved") meaningful
- [ ] betterstack: tcp port monitors on 2222 (proftpd/matrixify inbound) and 2223 (go app sftp that netsuite fetches from) - the one layer healthchecks/sentry dont cover. remember to allowlist betterstack probe ips in the DO firewall or it will always read down

# adding a new service: go app- ftp middleware

problem: we had a working script in netsuite that would get a file from a ftp server. the broken part was that the file had grown beyond the 100mb netsuite file size limit. this fix would get the file, make it smaller and make it avaliable for the netsuite script.

just leaving some notes for myself for next time:

- the go sftp package is not a full blown sftp server- it just handles some of the request response and i had to write my own fs handlers
- i went with mono repo for simiplicity (ha) and i think eventually it would be good to split some of these apps out into their own repos, and have this repo only have the orchestration stuff. (deploy scripts, and testing scripts)
- or maybe each app should have its own deploy.sh that is called from the orchestrator? not sure.
- i got to mess about with git submodules
