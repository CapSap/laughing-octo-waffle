# Test plan: NetSuite fetching files from the go-usa-stock container

## What we're verifying (the contract NetSuite depends on)

From `go-usa-stock/server/server.go` and `go-usa-stock/server/fs.go`, a NetSuite fetch
only succeeds if all of these hold:

- TCP reachable at `<droplet>:2223` (Swarm maps it to the container's `:22`)
- username is exactly `netsuite-client`
- public-key auth with the private key pairing `authorised/go_usa_stock.pub`
  (baked into the image — there is no password fallback)
- host key matches the `ssh_host_rsa_key_go_usa` secret (NetSuite pins host keys)
- `CWI_INVENTORY` / `sanmar_shopify.csv` exist under `/app/downloads` — a request
  for a missing file returns an error. `EnsureFresh` refreshes *stale* files in the
  background but won't block to create a *missing* one, so files must pre-exist
  before NetSuite's first fetch.

## Phase 1 — Local rehearsal (no real credentials needed)

Proves the whole mechanism end-to-end before touching production: build the image
from the working tree with a throwaway client keypair swapped into
`authorised/go_usa_stock.pub` (working tree only — never commit it), throwaway host
keys in `keys/`, dummy secrets, then run the stack via `local-testing.sh` (or a
trimmed go-only variant).

1. Generate throwaway keys — one host pair, one fake "NetSuite client" pair:
   ```sh
   ssh-keygen -t rsa -b 4096 -N "" -f ./go-usa-stock/keys/ssh_host_rsa_key_go_usa
   ssh-keygen -t rsa -b 4096 -N "" -f /tmp/netsuite-testkey
   cp /tmp/netsuite-testkey.pub ./go-usa-stock/authorised/go_usa_stock.pub  # DO NOT COMMIT
   ```
2. Deploy locally (`./local-testing.sh`), then drop a dummy `CWI_INVENTORY` into the
   `go-app` volume. The real fetchers will fail with dummy FTP secrets — that's fine,
   *serving* is what's under test.
3. Test with the OpenSSH client, which speaks the same protocol NetSuite does:
   ```sh
   sftp -P 2223 -i /tmp/netsuite-testkey netsuite-client@localhost
   # then: ls, get CWI_INVENTORY
   ```
4. Negative checks:
   - wrong username → rejected
   - wrong key → rejected
   - `put somefile` → refused (read-only FS)
   - `get ../../etc/passwd` → refused (path traversal guard)
5. Afterwards: `git checkout -- go-usa-stock/authorised/go_usa_stock.pub` and remove
   the throwaway keys.

## Phase 2 — Droplet-side state checks

- Service healthy and listening:
  ```sh
  docker service ps <stack>_go-usa-stock
  docker service logs <stack>_go-usa-stock | grep -E "SFTP server listening|Loaded authorized key"
  ```
- Confirm the files exist and check sizes. The image is `FROM scratch` — **there is
  no shell, `docker exec` won't work**. Inspect the volume from the host instead:
  ```sh
  sudo ls -la $(docker volume inspect -f '{{.Mountpoint}}' <stack>_go-app)
  ```
- Verify `sanmar_shopify.csv` is under NetSuite's 100 MB file-size limit (the whole
  reason this service exists) — check `CWI_INVENTORY` too.

## Phase 3 — Real-credential test from outside

- From a machine holding the real private key that pairs with
  `authorised/go_usa_stock.pub`:
  ```sh
  sftp -P 2223 -i <real-key> netsuite-client@<droplet-ip>
  # ls, get both files, compare sizes against the volume
  ```
- Capture the host key NetSuite must pin:
  ```sh
  ssh-keyscan -p 2223 <droplet-ip>
  ```
  The base64 body of the `ssh-rsa` line is what goes in the NetSuite connection config.
- **Firewall:** confirm the DO firewall allows inbound 2223 from NetSuite's egress
  IPs, not just your own IP. (The Readme note about allowlisting BetterStack probes
  suggests the firewall is restrictive.) This is the most likely
  "works for me, fails for NetSuite" gap.

## Phase 4 — The actual NetSuite test

In a sandbox account first, run a short SuiteScript (script debugger or a scheduled
script) that exercises exactly what production will do:

```javascript
const conn = sftp.createConnection({
  username: 'netsuite-client',
  keyId: '<uploaded-private-key-id>',
  url: '<droplet-ip>',
  port: 2223,
  directory: '/',
  hostKey: '<base64 body from ssh-keyscan>'
});
const file = conn.download({ filename: 'CWI_INVENTORY' });
log.audit('downloaded', file.size);
```

Watch both sides:

- NetSuite logs the downloaded size.
- Droplet service logs should show `🔗 TCP connection accepted`, `✅ Authorized user`,
  `🔍 Fileread request`, and — if the file was stale — `triggering background refresh`
  followed by a healthcheck ping (works post CA-certs fix).

Then run the real production script and confirm the downstream import.

## Success criteria

- [ ] Local rehearsal passes, including all negative tests
- [ ] Both files present on the droplet volume and under 100 MB
- [ ] Real-key `sftp get` works from outside the droplet
- [ ] `ssh-keyscan` host key captured and configured in NetSuite
- [ ] NetSuite sandbox script downloads both files
- [ ] Production script completes; refresh-on-read visible in logs/healthchecks
