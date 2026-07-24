# Chefworks FTPS 425 — Diagnosis & Fix Handoff

**Date:** 2026-07-24
**Repo:** `do-droplet` (this repo). App lives in the `go-usa-stock` submodule.
**Status:** Root cause confirmed. Fix approach decided (not yet implemented). Immediate
mitigation available.

---

## 1. TL;DR

Two Sentry issues were investigated on the `go-usa-stock` service:

| Issue | What | Verdict |
|-------|------|---------|
| **DOCKER-DROPLET-M** | `net.OpError … connection reset by peer`, "SSH handshake failed", 382 events | **Benign.** Internet port-scanner noise on the publicly-exposed port 2223. NetSuite always authenticates fine. No functional impact. Optional hygiene only. |
| **DOCKER-DROPLET-R / -S** | `425 "Unable to build data connection: TLS session of data connection not resumed."` on `CWI_INVENTORY.csv` | **REAL BUG.** chefworks FTPS downloads have failed on every attempt since ~2026-07-17. NetSuite has been served **8-day-stale** chefworks inventory. |

**Root cause of R:** the chefworks FTPS server *requires* the data connection to reuse the
control connection's TLS session (`require_ssl_reuse`). Go's `crypto/tls` (via
`jlaffaye/ftp`) does not do this reliably. The 2026-07-19 "fix" (pin TLS 1.2 +
`ClientSessionCache`) did **not** work — still 425 on every attempt. **`curl` (OpenSSL)
downloads the file perfectly** with a trivial default config.

**Chosen fix (decided with the user):** stop hand-rolling TLS in Go. Replace the chefworks
transfer with a `curl` call, and switch the image base from `scratch` to `alpine` so curl
is available. TLS itself is mandatory (the server enforces it) — only the fragile Go TLS
*workaround code* gets removed. `sanmar` (SFTP) is untouched.

**Next action:** implement the fix (§6), then deploy (§7) and verify (§8). Optionally run
the immediate mitigation first (§5) to un-stick NetSuite now.

---

## 2. Environment & access cheat-sheet

- **Droplet:** `root@stock-levels-app` (DigitalOcean, single-node Docker Swarm). SSH in as root.
- **Stack:** `sl-app-stack`. Services:
  - `sl-app-stack_go-usa-stock` — image `go-usa-stock:latest`, ports `*:2223->22/tcp` (SFTP server NetSuite pulls from; also runs the FTP/SFTP downloaders)
  - `sl-app-stack_node-app`
  - `sl-app-stack_pro-ftpd` — ports `*:2222->22/tcp`
- **⚠️ The go-usa-stock image is `FROM scratch`** — it has **only the Go binary**. No `ls`,
  `cat`, or shell. `docker exec … ls` fails with `executable file not found`. **Inspect from
  the host instead** (this is *why* the fix switches to alpine — debuggability).
- **Data volume:** `sl-app-stack_go-app` → host path
  `/var/lib/docker/volumes/sl-app-stack_go-app/_data`. Holds `CWI_INVENTORY.csv` (chefworks)
  and `sanmar_shopify.csv` (sanmar).
  ```bash
  MP=$(docker volume inspect sl-app-stack_go-app --format '{{.Mountpoint}}')
  ls -la --time-style=full-iso "$MP"
  ```
- **Reading swarm secrets from the host** (`docker cp` fails — `/run/secrets` is tmpfs; read
  via the process mount namespace instead):
  ```bash
  CID=$(docker ps -q -f name=sl-app-stack_go-usa-stock)
  PID=$(docker inspect --format '{{.State.Pid}}' "$CID")
  cat /proc/$PID/root/run/secrets/chefworks_remote_password   # etc.
  ```
- **chefworks connection facts (confirmed):** `host=ftp.chefworks.com` (`216.240.184.183`),
  `port=990`, `dir=/`, `file=CWI_INVENTORY.csv`, `user=CWOZ`, password = 8 chars.
  Server cert is **self-signed** (`CN=ftp.chefworks.com`, EC prime256v1) → verification must
  be skipped (`--insecure` / current Go uses `InsecureSkipVerify: true`).
  **Port 990 here is EXPLICIT FTPS** (plaintext connect + `AUTH TLS`), *not* implicit —
  implicit `ftps://` fails with `wrong version number`.

- **Sentry:** org `entity-brands` (region `https://de.sentry.io`), project `docker-droplet`.

---

## 3. Root cause detail (Issue R)

Timeline from `docker service logs sl-app-stack_go-usa-stock`:

- Last **successful** chefworks download: **2026-07-16 08:02** (304,985 bytes).
- 07-17, 07-18: failed `425`.
- **07-19 12:20** the "fix" image was deployed (`Image Created: 2026-07-19T12:20:47Z`); the
  new retry code is confirmed live (`download attempt 1/3 … 2/3 … 3/3`).
- 07-19, 07-20, 07-23: **still 425 on every attempt**, all 3 retries fail.
- `EnsureFresh` serves the last-good file while the background refresh fails, so NetSuite
  keeps getting the frozen 2026-07-16 file.

**The decisive test** (run on the droplet, creds loaded from `/proc/$PID/root/run/secrets`):

```bash
# A) Implicit FTPS  → FAILS: "SSL routines::wrong version number"  (server is NOT implicit)
curl -sv --insecure --ftp-pasv -u "$USER:$PASS" "ftps://$HOST:$PORT/$FILE" -o /tmp/cwi_implicit.csv

# B) Explicit FTPS  → SUCCEEDS: "226 Operation successful", 305,175 bytes
curl -sv --ssl-reqd --insecure --ftp-pasv -u "$USER:$PASS" "ftp://$HOST:$PORT/$FILE" -o /tmp/cwi_explicit.csv
```

Test B's log showed the smoking gun: on the **data** connection,
`* SSL reusing session ID`, negotiated **TLS 1.3**, then `150 Starting data transfer` →
`226`. So:

> **The chefworks server is healthy. curl/OpenSSL reuses the control TLS session on the data
> connection automatically (even on TLS 1.3). Go's `crypto/tls` does not, and pinning TLS 1.2
> did not fix it. Conclusion: use curl for the transfer; delete the Go TLS workaround.**

---

## 4. Why not just "remove TLS"?

TLS to chefworks is **not optional** — the server enforces it (implicit test A proves the
listener speaks TLS; a plain-FTP attempt is expected to return `530 … SSL/TLS required`,
optionally confirm with
`curl -fsS --ftp-pasv -u "$USER:$PASS" "ftp://$HOST:$PORT/$FILE" -o /tmp/plain.csv; echo exit=$?`).
What gets removed is the **~40 lines of hand-rolled Go TLS workaround**, not TLS.

---

## 5. Immediate mitigation (optional, un-sticks NetSuite for ~22h)

A fresh, valid file was downloaded during diagnosis to `/tmp/cwi_explicit.csv` (305,175
bytes, dated 2026-07-24). Atomically swap it into the volume so NetSuite stops getting
8-day-old stock immediately (and, being fresh, it pauses the failing background refresh +
425 spam for ~22h):

```bash
head -2 /tmp/cwi_explicit.csv; echo "lines: $(wc -l < /tmp/cwi_explicit.csv)"   # sanity check
MP=$(docker volume inspect sl-app-stack_go-app --format '{{.Mountpoint}}')
cp /tmp/cwi_explicit.csv "$MP/CWI_INVENTORY.csv.new"
mv -f "$MP/CWI_INVENTORY.csv.new" "$MP/CWI_INVENTORY.csv"    # atomic; in-flight reads keep old inode
ls -la --time-style=full-iso "$MP/CWI_INVENTORY.csv"
```
> NOTE: if `/tmp/cwi_explicit.csv` is gone (fresh session), re-download it first with test B
> in §3. **Confirm whether this was already run** — it may or may not have been applied.

---

## 6. Permanent fix — implementation checklist

All changes in the **`go-usa-stock` submodule** unless noted.

### 6a. `go-usa-stock/fetcher/chefworks.go`
- Delete the entire `ftp.Dial` / `ftp.DialWithExplicitTLS` / `ClientSessionCache` /
  `MinVersion=MaxVersion=tls.VersionTLS12` block **and its long explanatory comment**.
- Replace the transfer with a `curl` invocation writing to the existing temp file. Keep the
  existing **atomic rename**, **0-byte guard**, and (from the wrappers) **retry** +
  **healthcheck ping** — those stay.
- Suggested curl call (proven working against this server):
  ```
  curl -fsS --ssl-reqd --insecure --ftp-pasv \
       -u "<user>:<pass>" "ftp://<host>:<port>/<file>" -o <tempfile>
  ```
  - `-f` makes curl exit non-zero on an FTP error (e.g. 425) → the error propagates to the
    retry wrapper and Sentry, preserving current behaviour.
  - Read the same secrets it already loads (`chefworks_remote_url/port/username/password/
    dir/filename`) via the existing `loadSecrets()`; build the URL from them. `dir=/` means
    the file is at the FTP root — mirror `filepath.Join(dir, file)` → path `/CWI_INVENTORY.csv`.
  - Pass the password via `curl -u user:pass`. (If you want to avoid it in argv, use
    `--netrc-file` written to a temp file; optional.)
- Result: `DlChefworks` shrinks to ~15 lines and no longer imports `crypto/tls`.

### 6b. `go-usa-stock/Dockerfile`
Current final stage is `FROM scratch`. Change to alpine so curl exists:
```dockerfile
# --- STAGE 2: PRODUCTION ---
FROM alpine:latest
WORKDIR /
RUN apk add --no-cache curl ca-certificates
COPY --from=builder /go/bin/app /usr/local/bin/app
COPY --from=builder /usr/src/app/authorised /authorised
CMD ["/usr/local/bin/app"]
```
- Drop the manual `COPY … ca-certificates.crt` line — `apk add ca-certificates` provides them.
- Keep the `authorised` copy (SFTP authorized keys dir).
- Builder stage is unchanged (`CGO_ENABLED=0` static binary still fine on alpine).

### 6c. `go-usa-stock/main.go`
- The `//go:debug x509negativeserial=1` directive at the top existed to let Go's x509 parser
  accept chefworks' negative-serial cert. With curl `--insecure` handling that connection,
  it can be removed **iff** no other Go code parses that cert. (sanmar is SFTP/ssh, not
  x509 — safe.) Low priority; remove for cleanliness or leave it (harmless).

---

## 7. Deploy

Deployment is via **`./deploy-go.sh`** (run from a local machine with the SSH agent loaded;
it only touches the go-usa-stock service, leaving pro-ftpd/node-app alone). Mechanics:

1. On the droplet it runs `git pull origin $GIT_BRANCH && git submodule sync && git submodule
   update --init`. **→ You must commit AND push both:** the `go-usa-stock` submodule commit,
   **and** the parent `do-droplet` commit that bumps the submodule pointer. Otherwise the
   droplet builds old code.
2. Creates any missing swarm secrets (existing ones untouched).
3. Builds on the droplet: `docker build -t go-usa-stock:latest .../go-usa-stock`.
4. `docker stack deploy` + a convergence check that force-updates the service if the running
   container isn't on the freshly-built image (`:latest` has no digest, so this guard is what
   actually rolls the new image out).

Config comes from `deploy.env` (`DROPLET_HOST`, `SSH_USER`, `PROJECT_DIR`, `STACK_NAME`,
`GIT_BRANCH`) and secrets from `go-usa-stock/.env`.

**Local smoke test option:** `./deploy-go.sh --local` builds from the working tree into stack
`local-app-stack` (no git pull) — good for validating the alpine build + curl download before
shipping.

---

## 8. Verification after deploy

```bash
# On the droplet:
docker image inspect go-usa-stock:latest --format 'Created: {{.Created}}'   # should be just now
CID=$(docker ps -q -f name=sl-app-stack_go-usa-stock)
docker exec "$CID" sh -c 'curl --version | head -1'                          # curl now present (alpine)
docker service logs sl-app-stack_go-usa-stock -t --since 15m | grep -i chefworks
MP=$(docker volume inspect sl-app-stack_go-app --format '{{.Mountpoint}}')
ls -la --time-style=full-iso "$MP"                                           # CWI_INVENTORY.csv fresh, non-zero
```
The startup download (main.go fetches all sources on boot) should now log
`Downloaded CWI_INVENTORY.csv (…bytes)` instead of the 425. Confirm the chefworks
healthchecks.io check goes green and no new DOCKER-DROPLET-R events appear in Sentry.

---

## 9. Issue M (SSH handshake noise) — optional hygiene, not urgent

Port 2223 is internet-exposed; the handshake failures are scanners (fingerprints in logs:
`peer offered: [ssh-ed25519 / ecdsa / ssh-dss]`, `overflow reading version string`,
`login not allowed for user: probe`). Source shows as `10.0.0.2` only because Swarm's ingress
mesh SNATs external traffic. NetSuite (`netsuite-client`) authenticates successfully every
time — **no functional impact.**

If you want the Sentry noise gone:
- **Network:** restrict port 2223 to NetSuite's source IP(s) via a DigitalOcean cloud
  firewall (or `ufw`).
- **Code:** in `server/server.go`, stop calling `sentry.Notify(err, "SSH handshake failed")`
  for handshake failures (or downgrade below error level) — they're expected background noise
  on an exposed port, not actionable.

---

## 10. Command appendix

```bash
# Service / image state
docker service ls
docker service ps sl-app-stack_go-usa-stock --no-trunc
docker image inspect go-usa-stock:latest --format 'Created: {{.Created}}'

# Volume contents (host side — the container has no shell on the scratch image)
MP=$(docker volume inspect sl-app-stack_go-app --format '{{.Mountpoint}}'); ls -la --time-style=full-iso "$MP"

# Read swarm secrets from host (docker cp does NOT work on /run/secrets tmpfs)
CID=$(docker ps -q -f name=sl-app-stack_go-usa-stock)
PID=$(docker inspect --format '{{.State.Pid}}' "$CID")
rd(){ cat "/proc/$PID/root/run/secrets/$1"; }
HOST=$(rd chefworks_remote_url); PORT=$(rd chefworks_remote_port)
DIR=$(rd chefworks_remote_dir);  FILE=$(rd chefworks_remote_filename)
USER=$(rd chefworks_remote_username); PASS=$(rd chefworks_remote_password)

# Proven-working chefworks download (explicit FTPS)
curl -fsS --ssl-reqd --insecure --ftp-pasv -u "$USER:$PASS" "ftp://$HOST:$PORT/$FILE" -o /tmp/cwi.csv
```
