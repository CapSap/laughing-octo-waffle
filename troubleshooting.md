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

Before chasing anything you see in Sentry, read **§7** — the loudest issue in the
project (149 events, `no common algorithm for host key`) is almost certainly scan
noise, and healthcheck ping failures never reach Sentry at all.

## 1. Quick triage (always start here)

```bash
docker service ls                                   # all replicas 1/1?
docker stack ps sl-app-stack --no-trunc | head -30  # look for Shutdown/Failed tasks = restart loops
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'   # "Up X hours" = when it last restarted
ss -lntp | grep -E '2222|2223'                      # BOTH ports must be bound - see §6
df -h /                                             # disk full breaks temp-file writes
free -h                                             # memory + swap (swapfile should show)
```

The `ss` line is not redundant with the `PORTS` column of `docker service ls`.
Swarm will report a published port it has never actually bound, and that state
survives restarts and redeploys — it caused a silent 3-day outage on 2026-07-10.
`ss` is the only view that tells the truth. If a port is missing there, go
straight to §6.

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
| `File CWI_INVENTORY.csv is fresh (age: 23h...)`       | NetSuite polls, but always just inside MaxAge — the poll race from the Readme. Ping lands every ~48h instead of every ~24h. **Confirmed 2026-07-13**: NetSuite polls daily at ~08:04 UTC; each refresh re-anchors mtime to poll time + download duration, so the next poll lands seconds under 24h (observed age 23h59m41s) and skips. Fix in code, not on healthchecks.io: set chefworks MaxAge below the poll interval (e.g. 22h in `fetcher.go`). |
| `triggering background refresh` then `chefworks download started` but **no** `Downloaded ... bytes` | Transfer is hanging (FTPS control conn has no read deadline after dial). Restart the service (§5).   |
| `healthcheck ping skipped: chefworks_healthcheck_url not configured` | Secret missing/unreadable in the container. Check `docker secret ls` and the service spec.           |
| `healthcheck ping for chefworks_healthcheck_url failed: ...` | Download ran fine, the ping itself is failing. Test outbound (§4).                                    |
| `failed to dial` / `failed to login` / `failed to retrieve` | Download attempted and failed — but these also ping `/fail`, so last-ping would be recent. Check Sentry for the matching event. |

Sentry can tell you which of these branches you're in without SSHing anywhere —
a `background download of CWI_INVENTORY.csv failed` event *proves* NetSuite
connected, authenticated and asked for the file at that timestamp (§7). As of
2026-07-13 there has never been one, which points at the first row of the table
(NetSuite is not pulling) — but confirm the pings aren't just failing silently,
because those are log-only and invisible to Sentry:

```bash
docker service logs --since 96h sl-app-stack_go-usa-stock 2>&1 | grep -i 'healthcheck ping'
```

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
  connected. **First** rule out a lost port publish before blaming the outside
  world — swarm reports ports it has not bound, so `docker service ls` cannot
  clear this (§6; it hid a 3-day outage on 2026-07-10). Check the socket, then
  probe from the droplet itself, which bypasses the DO firewall and isolates the
  ingress path:

  ```bash
  ss -lntp | grep -E '2222|2223'   # is the port even bound? 2223 is the control
  ssh -p 2222 -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 probe@127.0.0.1 2>&1 | head -3
  ssh -p 2223 -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 probe@127.0.0.1 2>&1 | head -3   # control
  ```

  Read it like this:

  | result on 2222                                       | meaning                                                                                       |
  | ---------------------------------------------------- | --------------------------------------------------------------------------------------------- |
  | banner, `Permission denied`, **or** `REMOTE HOST IDENTIFICATION HAS CHANGED` | **PASS.** All three prove TCP reached proftpd and it offered a host key. The host-key warning is expected after any container recreate (Readme todo: the key is regenerated every time). Clear it with `ssh-keygen -R '[127.0.0.1]:2222'` and re-probe. Note `StrictHostKeyChecking=no` does *not* suppress it — that flag auto-accepts *unknown* keys; a *changed* key always hard-fails. |
  | **connection refused** + nothing bound in `ss`        | The port was never bound. **§6.** Not a timeout — there is no socket at all. `docker service ls` will still show `*:2222->22/tcp`; ignore it.  |
  | **timeout** (TCP connects, then nothing)              | Different failure: the port is bound but traffic isn't reaching the task. Force-update pro-ftpd (§5), re-probe, escalate to §6 if still dead.  |

  If the probe passes, the problem is upstream: matrixify export schedule/credentials
  in Shopify (its job log shows connection errors with timestamps), the DO
  firewall allowlist, or fail2ban (§4) in case matrixify's IP got banned.
- **Files arriving but no `Detected new file` in node logs** → the `fs.watch`
  watcher is dead or the container restarted and mounted late. Restart node-app (§5).
- **`Detected new file` present but no ping received** → look for
  `healthcheck ping failed: ... ETIMEDOUT`. That's the node 250ms connect-budget
  bug again. Confirm against the **running container**, not the image tag — those
  two drift apart and that drift is itself a known failure (§9):

```bash
# Is the fix in the JS the container is actually executing?
docker exec "$(docker ps -qf name=node-app)" grep -r 'setDefaultAutoSelectFamilyAttemptTimeout' /usr/src/app/dist/ && echo FIX PRESENT
```

  Blank output means the ping is broken. Before rebuilding anything, check
  whether the container is simply on a stale image — the fix may already be
  built and sitting unused on the droplet (§9):

```bash
docker inspect --format '{{.Image}}' "$(docker ps -qf name=node-app)"  # what's running
docker image inspect --format '{{.Id}}' node-app:latest                # what the tag says
```

  Different IDs → **§9**, and `docker service update --force sl-app-stack_node-app`
  is the whole fix. Same IDs and no `FIX PRESENT` → the image genuinely lacks the
  fix; check the droplet's checkout contains `897ba7b` and rebuild.

  A useful timing tell: with the fix absent, the ping fails ~1s after the Shopify
  push (8 connect attempts × the 250ms default). With the fix present a failure
  would take ≥5s per attempt. A sub-second ETIMEDOUT means old code, full stop.

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

`--force` restarts the task but changes no spec, so it emits no events — it
therefore **cannot** repair an unbound published port (§6). If a port is missing
from `ss`, don't reach for this; go to §6.

## 6. Swarm reports a published port it never bound

**Diagnosed 2026-07-13.** This silently killed matrixify uploads for 3 days
(2026-07-10 → 07-13) while every check we had reported the stack healthy. An
earlier version of this section blamed overlay IP exhaustion — that was wrong,
see "the misleading error" below.

The symptom is a contradiction. Service `1/1`, task `Running`, container **is**
attached to the ingress network, `docker service ls` shows `*:2222->22/tcp` —
and the host is not listening on the port:

```bash
ss -lntp | grep -E '2222|2223'    # 2223 present, 2222 absent
```

Clients get an instant **connection refused**, not a timeout, because there is
no socket at all. Nothing appears in the app logs or Sentry.

### Why it happens

Publishing a port in swarm is two pieces of state, maintained by different code
paths:

1. **per-task** — the container attaches to the ingress network (at task start)
2. **per-node** — dockerd binds the host socket, installs the `DOCKER-INGRESS`
   DNAT rule, and programs IPVS inside the ingress sandbox

The second is **edge-triggered and never audited**. Dockerd programs it in
response to events; nothing ever goes back and asks "is 2222 actually bound?"
So if the event is lost, the port stays unbound *permanently* while the service
spec keeps advertising it. Desired state (spec) and actual state (kernel)
diverge silently, and no part of Docker notices or repairs it.

The event gets lost when dockerd restarts: it rebuilds the ingress sandbox
(`Removing stale sandbox cid=ingress-sbox`) while the swarm agent is already
starting tasks against it. Those tasks fail, swarm retries, and they come up
Running — but a service whose port programming got dropped in the shuffle never
gets it back. Which services lose is a coin flip: on 2026-07-10 go-usa-stock
kept 2223 and pro-ftpd lost 2222.

### The misleading error

The rejected tasks report:

```
node is missing network attachments, ip addresses may be exhausted
```

**The second half is a canned guess baked into the message, not a measurement.**
On this single-node swarm with three services the overlay subnets are nowhere
near full. The real condition is the first half: the node has no attachment for
that network *yet*, because the ingress sandbox is still being rebuilt. Don't go
hunting for leaked IPs (the old advice in this section) — it's a startup race,
not exhaustion.

### The fix — and what does *not* work

```bash
# WORKS: a real spec change → real events → the port actually gets programmed
docker service update --publish-rm  published=2222,target=22 sl-app-stack_pro-ftpd
docker service update --publish-add published=2222,target=22 sl-app-stack_pro-ftpd
ss -lntp | grep 2222     # verify HERE. never in `docker service ls`.
```

- `docker service update --force` does **not** fix it. It restarts the task but
  changes no spec, so it emits no event, so nothing reprograms the port.
- `docker stack deploy` / `deploy-stack.sh` does **not** fix it either.
  `docker-compose.yml` already says `2222:22` and swarm already believes it
  applied that, so reconciliation is a no-op on the endpoint.
- Last resort: `docker stack rm sl-app-stack`, wait for networks to disappear
  (`docker network ls`), then redeploy with `deploy-stack.sh`. A full teardown
  does rebuild the publish. (Secrets and volumes survive a stack rm; the proftpd
  host key does not persist anyway — see Readme todo.)

### What actually triggered the 2026-07-10 restart

Worth preventing, not just repairing. The droplet is a 1GB box that also builds
images. Deploying 897ba7b starved it: dockerd's swarmkit raft loop stalled
(`Attempting to transfer leadership`, then `raft.stackDump()`, 01:08:24), the box
went unresponsive (last journal entry 01:20:53, no shutdown sequence logged), and
it was power-cycled at 01:27:18. **No OOM kill fired** — the kernel thrashed
itself to death instead, exactly as `droplet_setup.sh` warns. The swapfile added
4 minutes later turns that hang into a slow build, but raft still shares a 1GB
box with the image builder. Building images off-box and pulling from a registry
would remove this whole class of failure (and the `pull access denied` landmine —
see Readme todos).

Forensics, for next time:

```bash
uptime -s; journalctl --list-boots                               # did the box reboot, and when?
journalctl -u docker --since '<window>' --no-pager | head -20    # raft stall? panic? watchdog?
journalctl -k -b -1 | grep -iE 'oom|killed process'              # OOM kill? (07-10: no)
```

Two traps we fell into: `journalctl -k` implies the *current* boot, so use `-b -1`
to read the boot that died. And don't grep a Go stack dump for a keyword and read
the matching goroutine as the culprit — the dump lists *every* goroutine, so the
grep will always hand back whatever you searched for.

### Monitoring gap

This failure is invisible to every layer we have. healthchecks.io sees only a
missing ping (which reads as "matrixify stopped uploading"), Sentry sees nothing
(node-app doesn't report there, and no app error occurred), and `docker service ls`
actively reassures you. The TCP port monitors on 2222/2223 in the Readme todos are
the *only* thing that would have caught this — that todo is now the highest-value
item on the list.

## 7. Reading Sentry (`entity-brands` / `docker-droplet`)

Findings below are from the MCP server on **2026-07-13**; counts are 30-day.

### What is and isn't instrumented

Everything in this project comes from **go-usa-stock** (node-app doesn't report
here). `sentry.Notify` fires on: startup download failures (`startup download of
X failed`, main.go:22), background download failures (`background download of X
failed`, fetcher.go:109), **every failed inbound SSH handshake** (`SSH handshake
failed`, server.go:102), sftp server errors, and accept failures. Plus an
info-level `Server starting up...` on every boot.

Two gaps that make Sentry misleading if you don't know about them:

- **Healthcheck ping failures never reach Sentry.** `fetcher/healthcheck.go`
  only does `log.Printf("healthcheck ping for %s failed: ...")`. A completely
  broken ping path produces *zero* Sentry events — so Sentry silence never
  proves the pings are working. Grep the service logs (§2) instead.
- **Local dev reports into the same project.** Everything is `release: dev`, so
  a `local-testing.sh` run on your laptop lands in the same issue stream as the
  droplet. Separate them by `server_name` (= container ID) and timestamp.

`server_name` is the go container's ID, which doubles as a restart log:
`0077fd596004` (→07-06) → `06154c87c122` (07-06→07-10) → `a1eb269b7c48`
(current). **Last start: 2026-07-10T01:27:40Z** — 14 boots in 10 days. Startup
downloads both sources, so that timestamp is the last *guaranteed* ping for both
go checks.

### The red herring: DOCKER-DROPLET-M (149 events, ~90% of the project)

Do not chase this. It is inbound SSH junk arriving on the published port 2223:

| error                                                  | 30d | what it is                                                     |
| ------------------------------------------------------ | --- | -------------------------------------------------------------- |
| `EOF`                                                   | 60  | peer negotiated, took the host key, hung up without authing     |
| host key: peer offered **ed25519 only**                 | 27  | peer wants an ed25519 host key; we only have RSA                |
| host key: peer offered **ecdsa only**                   | 26  | same, ecdsa                                                     |
| `ssh: overflow reading version string`                  | 6   | non-SSH traffic (HTTP/TLS) hitting the port                     |
| `no auth passed yet, unauthorized key`                  | 6   | **all on 2026-07-03** — the local rehearsal with throwaway keys |
| `no auth passed yet`                                    | 4   | peer disconnected before auth                                   |
| kex: peer offered `diffie-hellman-group1-sha1`          | 1   | ancient scanner                                                 |
| `connection reset by peer`                              | ~16 | peer RST                                                        |
| `connection lost`                                       | 2   | ← the only *real* application errors (below)                    |

The cause of the host-key errors: the server installs exactly **one** host key,
RSA (`ssh_host_rsa_key_go_usa`, the single `AddHostKey` at server.go:66), so it
can only ever offer `rsa-sha2-256 / rsa-sha2-512 / ssh-rsa`. Any client that
pins ed25519 or ecdsa dies before auth.

Why it's noise rather than a broken NetSuite:

- NetSuite pins an **RSA** host key (`netsuite-sftp-test-plan.md`), so it is not
  one of these peers.
- NetSuite demonstrably completed a full handshake + auth + fileread on
  **2026-07-09 15:02 UTC** (see the oracle below) — *while* these failures were
  already happening daily.
- Zero `login not allowed for user: X` events in 30 days, so no peer has ever
  tried to authenticate under a wrong username either.
- The failures arrive as **ed25519+ecdsa pairs ~1s apart** — one connection per
  host-key type, never an auth attempt. That's the signature of `ssh-keyscan`-
  style host-key probing.

**The one loose end:** it's on a *schedule* — 00:53, 09:53 and 18:52 UTC (±2
min), every day since 2026-07-03, surviving container restarts. That's somebody's
cron, and we can't see whose (below). If it turned out to be NetSuite's chefworks
job pinned to the wrong host key — e.g. someone ran `ssh-keyscan <ip>` *without*
`-p 2223` and pasted the droplet's own OpenSSH ed25519/ecdsa key into the
NetSuite connection config — then this **is** the chefworks root cause. Two ways
to settle it, cheapest first:

1. Get the real source IP (below) and compare against NetSuite's egress IPs.
2. Give the server ed25519 + ecdsa host keys alongside the RSA one (extra
   `AddHostKey` calls). This does **not** break NetSuite's RSA pin — the server
   still offers RSA to a client that asks for it. Then watch what the 3×/day peer
   does: proceeds to authenticate → it's a real client (and if it authenticates
   as `netsuite-client`, it's NetSuite, and chefworks is fixed); takes the key and
   disconnects → it's a scanner. Either way the noise stops.

### Why you can't see who the peer is (swarm ingress SNAT)

Every peer shows up as `10.0.0.2` (`read tcp 10.0.0.4:22->10.0.0.2:48952`).
`10.0.0.2` is the swarm **ingress gateway**, not the client: the ingress mesh
SNATs every inbound connection to 2223. So neither the go logs, nor Sentry, nor
fail2ban on the host can identify or ban these peers.

To recover real client IPs — either tcpdump on the host (no redeploy, just wait
for 00:53 / 09:53 / 18:52 UTC):

```bash
tcpdump -i eth0 -n 'tcp port 2223 and tcp[tcpflags] & tcp-syn != 0'
```

…or publish the port in host mode, which bypasses ingress:

```yaml
  go-usa-stock:
    ports:
      - target: 22
        published: 2223
        mode: host
```

### The oracle: what a "background download" event proves

`EnsureFresh` has exactly one caller — `server/fs.go:87`, inside `Fileread`. So a
`background download of <file> failed` event is *proof* that at that timestamp
NetSuite (a) completed the SSH handshake, (b) authenticated as `netsuite-client`
with the right key, (c) requested that file, and (d) found it past its MaxAge.
The download it kicked off is the only part that failed.

Contrast `startup download of X failed` (main.go:22), which is just the boot-time
fetch and says nothing about NetSuite.

This makes Sentry the only durable record of NetSuite actually pulling files —
the service logs roll. The flip side: a *successful* NetSuite fetch of a *fresh*
file produces no event at all, so absence of events is not absence of NetSuite.

### The only two real errors in 30 days

DOCKER-DROPLET-P / DOCKER-DROPLET-N, both `2026-07-09T15:02:12Z`, container
`06154c87c122`: `background download of sanmar_shopify.csv failed` →
`failed to download file: connection lost` (`sftp.fxerr`, fetcher.go:109) — the
`io.Copy` from sanmar's SFTP server dropped mid-transfer.

Reading it with the oracle: on 07-09 at 15:02 NetSuite pulled `sanmar_shopify.csv`,
found it >7h stale, triggered the refresh, and **sanmar's** server dropped the
connection mid-copy. That pinged sanmar's check `/fail` (so: red with a recent
ping, not silent). One occurrence, transient, upstream — nothing to fix here.

### What Sentry says about the chefworks silence

- **No** `startup download of CWI_INVENTORY.csv failed` event, ever → the
  boot-time chefworks download has been succeeding, including at the last restart
  (2026-07-10T01:27:40Z), which pinged the check.
- **No** `background download of CWI_INVENTORY.csv failed` event, ever →
  `EnsureFresh` has never fired a failing chefworks refresh.

So if the check's last ping is ~2026-07-10 01:27, NetSuite has not requested
`CWI_INVENTORY.csv` while it was stale since that restart — the "NetSuite stopped
pulling" branch of §2. Note the file was legitimately *fresh* for 24h after the
restart (a poll in that window logs `no download needed` and pings nothing), so
silence up to ~48h is expected; ~3 days is not. Two caveats before you blame
NetSuite: ping failures are log-only (grep the logs, §2), and if the scheduled
handshake peer above turns out to be NetSuite, the cause is our missing ed25519/
ecdsa host key, not NetSuite's schedule.

## 8. Verifying the 2026-07-13 fix: what to run, and when

Fix applied **2026-07-13 ~02:45 UTC** — `--publish-rm` + `--publish-add` restored
the 2222 binding (§6). `ss` shows the socket and the localhost probe passes.

What that does **not** prove: that a real matrixify upload completes end to end.
The probe came from `127.0.0.1`, which bypasses the DO firewall, and it only
reached proftpd's SSH banner — it never authenticated or wrote a file. Matrixify
exports **hourly, arriving ~:30 past**. Until one lands, the pipeline is unverified.

### Right now (30 seconds) — clear the stale host key, re-probe

Recreating the container regenerated proftpd's host key (Readme todo), so the
droplet's own `known_hosts` still holds the old one and the probe hard-fails with
`REMOTE HOST IDENTIFICATION HAS CHANGED`:

```bash
ssh-keygen -R '[127.0.0.1]:2222'
ssh -p 2222 -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 probe@127.0.0.1 2>&1 | head -3
```

**PASS** = `Permission denied (publickey)`. Matrixify does not verify the host key
(its Shopify server config has no host-key field, only a private key for auth), so
the regenerated key does not block it.

### At ~03:35 UTC — i.e. ~5 min after the next :30 export — did a real upload land?

```bash
# 1. did a file arrive? (newest first — expect one dated in the last few minutes)
ls -lat --time-style=full-iso /var/lib/docker/volumes/sl-app-stack_shared-data/_data/ | head -5

# 2. did proftpd see matrixify log in? (its egress IP is 54.218.250.7)
docker service logs --since 30m --timestamps sl-app-stack_pro-ftpd 2>&1 | tail -20

# 3. did the node app pick it up and push to shopify?
docker service logs --since 30m --timestamps sl-app-stack_node-app 2>&1 \
  | grep -iE 'detected new file|healthcheck|error'
```

**PASS** = a fresh file in the volume, a proftpd login, `Detected new file` in the
node logs, and `eb-stock-on-hand-file-upload` flipping green on healthchecks.io by
itself. Nothing further to do.

### If nothing arrived by ~03:45 UTC

The port is bound and firewalled correctly (2222 is allowlisted to `54.218.250.7`,
which matches matrixify's stated egress IP), so the fault has moved upstream:

1. **Matrixify's job log in Shopify** — it records connection errors with
   timestamps. Three days of refusals should be visible there, and the entry for
   the ~03:30 run tells you whether it even attempted a connection.
2. **Was the export still scheduled?** Three days of hard failures may have caused
   matrixify to disable or deprioritise the job — re-enable and run it manually.
3. **Confirm the port didn't get dropped again:** `ss -lntp | grep 2222`.

### If a file arrived but the check stayed silent

Then this isn't a port problem and the break is further down the pipeline — go to
§3: no `Detected new file` = the `fs.watch` watcher is dead (restart node-app, §5);
present but no ping = the ping path itself (§4).

### Still open, and unrelated to this fix

**chefworks-usa-stock** is a separate fault — the NetSuite MaxAge poll race in §2,
fixed in `fetcher.go` by dropping chefworks' MaxAge below NetSuite's ~24h poll
interval (e.g. 22h). Nothing done on 2026-07-13 touches it, and it will stay silent
until that lands.

## 9. The deploy said success but the container is running old code

**Diagnosed 2026-07-14.** This hid a *fixed* node-app from production for four
days. The healthcheck fix (`897ba7b`, committed 2026-07-10) was on master, was in
the droplet's checkout, and was compiled into `node-app:latest` — and the running
container was on none of it. Every `./deploy-stack.sh` reported success and
changed nothing.

### The signature

Look for **all** of these at once. Any one alone means something else:

- `./deploy-stack.sh` completes cleanly and prints `node-app: image unchanged —
  leaving service alone`.
- `docker stack ps` shows the task `Running` for far longer than the last deploy
  (e.g. "Running 4 days ago" right after a deploy).
- The image *has* the fix but the container does *not*:

```bash
docker inspect --format '{{.Image}}' "$(docker ps -qf name=node-app)"  # e.g. 0305d07f...
docker image inspect --format '{{.Id}}' node-app:latest                # e.g. 999bb585...  ← differ!

# the tag is fine — it's the container that's stale:
docker run --rm --entrypoint sh node-app:latest -c \
  "grep -r 'setDefaultAutoSelectFamilyAttemptTimeout' /usr/src/app/dist/ && echo IMAGE HAS FIX"
```

### The fix

```bash
docker service update --force sl-app-stack_node-app
```

That's all. The correct image is already on the droplet; Swarm just needs to be
told to restart onto it. Verify with the `docker exec` grep in §3 — it should now
print `FIX PRESENT`.

### Why it happened

All images are tagged `:latest` with no registry digest, so `docker stack deploy`
cannot tell that an image's *content* changed and won't restart a service whose
spec is untouched. `deploy-stack.sh` compensates by force-updating — but until
2026-07-14 it decided *which* services to force by comparing the image ID
**before the build** against **after the build**.

That test answers the wrong question. It asks "did this build change the image?"
when it needs to ask "is the container on the image we just built?". The two come
apart like this:

1. A deploy builds a good image but doesn't restart the service (spec unchanged,
   or the restart is skipped/rejected — see §6, where tasks were rejected with
   `node is missing network attachment`).
2. The container keeps running the old image. The tag now points somewhere else.
3. Every **later** deploy rebuilds from unchanged source, hits the layer cache,
   produces a byte-identical image, sees `pre == post`, and reports "image
   unchanged — leaving service alone."

Step 3 repeats forever. The stale container is permanently invisible to the
script, and the more faithfully you re-run the deploy the more confidently it
tells you there's nothing to do. Note the build log looks *healthy* in this state
— the builder stage genuinely re-runs `npm install` and `tsc`; only the final
`COPY --from=builder /usr/src/app/dist ./dist` comes back `CACHED`, which is the
tell that the fresh compile was identical to what's already in the image.

The script now compares the **running task's image** against the freshly built one
and forces a redeploy whenever they differ (and when it can't identify a running
container at all). That converges no matter how the two drifted apart, so a single
re-run of `./deploy-stack.sh` is now sufficient to repair this class of fault.

### The general lesson

A green deploy proves the *pipeline* ran, not that the *code* is live. When a fix
"doesn't work", check what the container is executing before you doubt the fix:

```bash
docker exec "$(docker ps -qf name=node-app)" grep -r '<the fix>' /usr/src/app/dist/
```

Every layer above that — the commit, the branch, the checkout, the image — can be
correct while the container is not.
