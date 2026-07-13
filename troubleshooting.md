# Troubleshooting: healthchecks.io reporting down

Commands to run **on the droplet** (`ssh root@134.199.155.34`) when a check goes
silent. Stack name is `sl-app-stack`.

Key fact about how the pings work: every code path pings — success hits the
check URL, failure hits `<url>/fail`. So a check that is down with an **old
"Last Ping"** means the ping code path *never ran* (or the ping HTTP request
itself failed), not that a download/upload failed. A failed run would show a
recent last ping with a red status.

What triggers each ping:

| check                        | app          | ping fires when                                                                 |
| ---------------------------- | ------------ | ------------------------------------------------------------------------------- |
| chefworks-usa-stock          | go-usa-stock | container startup, or NetSuite SFTP-pulls `CWI_INVENTORY.csv` while it is >24h old |
| sanmar-usa-stock             | go-usa-stock | container startup, or NetSuite SFTP-pulls `sanmar_shopify.csv` while it is >7h old |
| eb-stock-on-hand-file-upload | node-app     | matrixify uploads a file via proftpd and the Shopify push runs (success *or* fail) |

Note: the go image is `FROM scratch` — there is **no shell inside it**, so you
cannot `docker exec` into go-usa-stock. Inspect it via `docker service logs`
and the volume path on the host.

## 1. Quick triage (always start here)

```bash
docker service ls                                   # all replicas 1/1?
docker stack ps sl-app-stack --no-trunc | head -30  # look for Shutdown/Failed tasks = restart loops
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'   # "Up X hours" = when it last restarted
df -h /                                             # disk full breaks temp-file writes
free -h                                             # memory + swap (swapfile should show)
```

A recent container restart matters: the go app downloads (and pings) both
sources at startup, so "Up 2 hours" with a 39h-old chefworks ping means the
startup download itself is failing silently or hanging.

## 2. chefworks-usa-stock silent

First question: is NetSuite even asking for the file?

```bash
# Any SFTP activity at all (sanmar green means there should be plenty):
docker service logs --since 48h sl-app-stack_go-usa-stock 2>&1 | grep -c 'TCP connection accepted'

# Everything the app said about the chefworks file:
docker service logs --since 48h --timestamps sl-app-stack_go-usa-stock 2>&1 \
  | grep -iE 'CWI_INVENTORY|chefworks|healthcheck'
```

How to read what you find:

| log line                                              | meaning                                                                                             |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| *(no mention of CWI_INVENTORY at all)*                | NetSuite stopped pulling this file. Problem is on the NetSuite side (script disabled/erroring).      |
| `File CWI_INVENTORY.csv is fresh (age: 23h...)`       | NetSuite polls, but always just inside MaxAge — the poll race from the Readme. Ping lands every ~48h instead of every ~24h. Fix on healthchecks.io: widen the period/grace (Readme says 25h period; the dashboard currently shows 1 day — verify it wasn't reset). |
| `triggering background refresh` then `chefworks download started` but **no** `Downloaded ... bytes` | Transfer is hanging (FTPS control conn has no read deadline after dial). Restart the service (§5).   |
| `healthcheck ping skipped: chefworks_healthcheck_url not configured` | Secret missing/unreadable in the container. Check `docker secret ls` and the service spec.           |
| `healthcheck ping for chefworks_healthcheck_url failed: ...` | Download ran fine, the ping itself is failing. Test outbound (§4).                                    |
| `failed to dial` / `failed to login` / `failed to retrieve` | Download attempted and failed — but these also ping `/fail`, so last-ping would be recent. Check Sentry for the matching event. |

When did the last *successful* download actually happen? The file's mtime says:

```bash
ls -la --time-style=full-iso /var/lib/docker/volumes/sl-app-stack_go-app/_data/
```

Leftover `CWI_INVENTORY.csv.tmp` here is another sign of a transfer that hung
or died mid-copy.

## 3. eb-stock-on-hand-file-upload silent

Work down the pipeline: matrixify → proftpd → uploads dir → node watcher → Shopify → ping.

```bash
# Has ANY file arrived recently? (newest first — expect hourly arrivals ~:30 past)
ls -lat --time-style=full-iso /var/lib/docker/volumes/sl-app-stack_shared-data/_data/ | head -15

# Did proftpd see login attempts / transfers?
docker service logs --since 72h --timestamps sl-app-stack_pro-ftpd 2>&1 | tail -50

# What did the node app see and do?
docker service logs --since 72h --timestamps sl-app-stack_node-app 2>&1 \
  | grep -iE 'detected new file|healthcheck|error' | tail -40
```

Interpretation:

- **No new files in the volume + nothing in proftpd logs** → matrixify never
  connected. Check the matrixify export schedule/credentials in Shopify, the DO
  firewall allowlist, and fail2ban (§4) in case matrixify's IP got banned.
- **Files arriving but no `Detected new file` in node logs** → the `fs.watch`
  watcher is dead or the container restarted and mounted late. Restart node-app (§5).
- **`Detected new file` present but no ping received** → look for
  `healthcheck ping failed: ... ETIMEDOUT`. That's the node 250ms connect-budget
  bug again — confirm the deployed image actually contains the
  `setDefaultAutoSelectFamilyAttemptTimeout` fix:

```bash
# When was the running image built? (must postdate the fix commit 897ba7b)
docker image inspect node-app:latest --format '{{.Created}}'
# And is the fix in the built JS?
docker exec "$(docker ps -qf name=node-app)" grep -r 'setDefaultAutoSelectFamilyAttemptTimeout' /usr/src/app/dist/ && echo FIX PRESENT
```

## 4. Test the ping path itself

Use the `/log` endpoint — it records an event on healthchecks.io **without
changing the check's status**, so you don't mask a real outage by flipping the
check green. Read the real UUIDs from the secrets first:

```bash
# node container can read its own secret:
docker exec "$(docker ps -qf name=node-app)" cat /run/secrets/eb_stock_on_hand_file_upload_healthcheck_url

# go container has no shell; read a secret via a throwaway one-shot service:
docker service create --name peek --secret chefworks_healthcheck_url \
  --restart-condition none alpine cat /run/secrets/chefworks_healthcheck_url
docker service logs peek; docker service rm peek
```

Then test reachability from each network position:

```bash
# From the host (baseline — this worked even when node was broken):
curl -m 10 -sv "https://hc-ping.com/<uuid>/log" -d "manual test from droplet host"

# From inside the node container with node's DEFAULT 250ms connect budget
# (reproduces the original bug if it's back):
docker exec "$(docker ps -qf name=node-app)" node -e \
  'fetch("https://hc-ping.com/<uuid>/log",{method:"POST",body:"test: default timeouts"}).then(r=>console.log("status",r.status)).catch(e=>console.error(e))'

# Same test with the raised attempt timeout (mirrors the deployed fix):
docker exec "$(docker ps -qf name=node-app)" node --network-family-autoselection-attempt-timeout=5000 -e \
  'fetch("https://hc-ping.com/<uuid>/log",{method:"POST",body:"test: 5s attempt timeout"}).then(r=>console.log("status",r.status)).catch(e=>console.error(e))'
```

If the first node test throws `ETIMEDOUT` on `connect` but the second succeeds,
it's the 250ms budget (fix missing from the running image). If **both** fail
but host curl works, suspect docker overlay/NAT or DNS inside the container.

Also check fail2ban hasn't banned a partner IP (matrixify or NetSuite):

```bash
fail2ban-client status                          # list jails
for j in $(fail2ban-client status | sed -n 's/.*Jail list:\s*//p' | tr ',' ' '); do
  echo "== $j =="; fail2ban-client status "$j" | grep -A2 'Banned IP'
done
```

## 5. Recovery kicks

Restarting a service is also a diagnostic: the go app re-downloads **both**
sources at startup, so a restart that turns chefworks green proves the download
path and points the finger at NetSuite's polling.

```bash
docker service update --force sl-app-stack_go-usa-stock   # re-runs both downloads + pings
docker service update --force sl-app-stack_node-app       # re-arms the fs.watch watcher
docker service update --force sl-app-stack_pro-ftpd       # note: regenerates host key (known issue)
```

Caveat: a successful startup download pings the check green — do this *after*
collecting logs, or you lose the evidence of when things stopped.

## 6. Known swarm gotcha: overlay IP exhaustion

Observed 2026-07-11: tasks Rejected with
`"node is missing network attachments, ip addresses may be exhausted"` during a
restart. Forced service updates allocate the new task's IP before the old one
is released, and on a single-node swarm the overlay subnets can briefly run
dry. Swarm usually retries and recovers, but if a service sticks at 0/1 with
this error:

```bash
docker network inspect sl-app-stack_app_network --format '{{json .IPAM.Config}}'
docker network inspect sl-app-stack_go_network --format '{{json .IPAM.Config}}'
# stale endpoints holding IPs:
docker network inspect sl-app-stack_app_network --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'
```

Last resort: `docker stack rm sl-app-stack`, wait for networks to disappear
(`docker network ls`), then redeploy with `deploy-stack.sh`. This recreates the
overlay networks and releases every leaked IP. (Secrets and volumes survive a
stack rm; the proftpd host key does not persist anyway — see Readme todo.)
