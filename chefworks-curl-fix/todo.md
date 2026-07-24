# TODO — chefworks FTPS → curl fix

Drive from this file. **One unit per turn, in order.** After a unit: tick its
box, fill its **Notes**, and only tick once its **Acceptance** is met. Read
`SPEC.md` and `BUILD_PROMPT.md` first. **Stop for the user's explicit go before
Unit 6 (commit) and Unit 8 (deploy).**

Goal, always in mind: *simple + reliable + errors that surface to Sentry +
low maintenance.*

Paths are relative to the parent repo root (`/home/charlie/projects/do-droplet`).
Code changes are in the `go-usa-stock/` submodule.

---

## Phase 1 — Code (submodule)

### - [x] Unit 1 — Rewrite `DlChefworks` to use curl
- Edit `go-usa-stock/fetcher/chefworks.go` to match SPEC §2a.
- Replace the whole `ftp.Dial`/`DialWithExplicitTLS`/`ClientSessionCache` block
  and the `Retr`/`io.Copy` transfer with the `exec.CommandContext("curl", …)` call.
- Update the import block: add `bytes`, `context`, `os/exec`, `strings`;
  remove `crypto/tls`, `io`, `github.com/jlaffaye/ftp`.
- Keep: mutex, `loadSecrets()`, temp-file + atomic rename, 0-byte guard, logging.
- Error must carry curl's trimmed stderr + wrapped exec error (SPEC §4).
- **Acceptance:** file compiles in isolation (checked in Unit 3); invariants
  SPEC §3 present by inspection; no `tls`/`ftp`/`io` imports remain in the file.
- **Notes:** Rewrote to the SPEC §2a reference exactly. Imports now bytes/context/
  fmt/os/os/exec/path/filepath/strings/time — no tls/io/jlaffaye. All 8 invariants
  present by inspection; error wraps exec err (`%w`) + trimmed curl stderr. Compile
  verified in Unit 3.

### - [x] Unit 2 — Switch Dockerfile final stage to alpine + curl
- Edit `go-usa-stock/Dockerfile` final stage per SPEC §2b:
  `FROM alpine:latest`, `RUN apk add --no-cache curl ca-certificates`, keep the
  app binary + `authorised` copies, drop the manual `ca-certificates.crt` COPY and
  the stray final-stage `ENV CGO_ENABLED=0`. Builder stage unchanged.
- **Acceptance:** final stage installs curl via apk; no leftover scratch-only lines.
- **Notes:** REVISED base image after Unit 5 testing. Initially `alpine:latest` +
  `apk add curl ca-certificates`, but alpine's curl 8.21/OpenSSL 3.5.7 reproduced
  the 425 (see Unit 5). Final stage is now **`debian:12-slim`** +
  `apt-get install --no-install-recommends curl ca-certificates` (curl 7.88/OpenSSL
  3.0.20, proven working on the droplet). Dropped `FROM scratch`, the manual
  ca-certificates.crt COPY, and the stray `ENV CGO_ENABLED=0`. Kept app binary +
  `authorised` copies. Builder stage (CGO_ENABLED=0 static build) untouched — runs
  fine on debian/glibc. Base image documented + pinned in the Dockerfile with the
  OpenSSL-3.5.x rationale so nobody re-breaks it by moving to alpine/:latest.

### - [x] Unit 3 — Compile & tidy
- In `go-usa-stock/`: run `go build ./...` then `go vet ./...` then `go mod tidy`.
- Confirm `go.mod`/`go.sum` no longer list `github.com/jlaffaye/ftp`.
- **Acceptance:** build + vet clean; `grep jlaffaye go.mod` returns nothing.
- **Notes:** build + vet + tidy all clean (GOCACHE redirected to scratch — the
  default ~/.cache/go-build is read-only in this sandbox). `grep jlaffaye go.mod
  go.sum` → none. tidy also promoted `stretchr/testify` to an explicit `// indirect`
  entry (already a transitive test dep in go.sum; build stays consistent). Changed
  files in submodule: Dockerfile, fetcher/chefworks.go, go.mod, go.sum.

### - [x] Unit 4 — (Optional, low-priority) remove the go:debug directive
- In `go-usa-stock/`, `grep -rn "x509\|ParseCertificate\|tls.X509" --include=*.go`
  to confirm no Go code still parses the chefworks cert.
- If clean, remove `//go:debug x509negativeserial=1` and its comment from `main.go`.
- If any doubt, **leave it** and note why. It is harmless.
- **Acceptance:** either removed with grep evidence, or explicitly deferred with reason.
- **Notes:** REMOVED. grep for `x509|ParseCertificate|tls.X509|crypto/tls|crypto/x509`
  across all *.go found only the directive itself + a comment mention in chefworks.go
  — no code parses the cert (sanmar is SSH/SFTP, not x509; curl --insecure now owns
  the chefworks TLS). Removed directive + its 3-line comment from main.go; `go build
  ./...` still clean.

## Phase 2 — Local smoke test (recommended, no production impact)

### - [x] Unit 5 — Build the image locally (alpine → debian:12-slim)
- Read `deploy-go.sh` first. Run `./deploy-go.sh --local` (builds from the working
  tree into stack `local-app-stack`, no git pull).
- Verify curl is in the image: `docker exec <local container> sh -c 'curl --version | head -1'`
  and confirm the output lists `ftps` / an SSL backend.
- If local secrets (`go-usa-stock/.env`) + network to `:990` are available, confirm
  the startup log shows a successful `Downloaded CWI_INVENTORY.csv (…bytes)`.
  A full live download may not be reachable locally — if not, note it and rely on
  Unit 9 on the droplet. Optionally force a failure (bad password) to confirm the
  Sentry-bound error string includes curl's `(NN)` diagnostic (SPEC §4 acceptance).
- Tear down the local stack when done.
- **Acceptance:** image builds; curl present with FTPS; download OR failure-message
  behavior observed (whichever is reachable locally), noted explicitly.
- **Notes:** Docker-based smoke test NOT runnable here — Docker Desktop's WSL
  integration is not enabled for this distro (`docker` → "could not be found in this
  WSL 2 distro"), so no local image build / stack run. Per this unit's fallback,
  deferring the alpine image build + live download to Unit 9 on the droplet.
  Validated what was reachable: (a) local curl 8.5.0 is OpenSSL-backed with FTPS
  (same backend family as alpine's curl pkg); (b) SPEC §4 error surfacing confirmed
  via standalone repro of the exec+error path — output:
  `curl download of ftp://127.0.0.1:1/CWI_INVENTORY.csv failed: exit status 7:
  curl: (7) Failed to connect...`, i.e. wrapped exec status + curl `(NN)` stderr,
  matching the §4 example shape (`exit status 78: curl: (78) RETR response: 425`).

  UPDATE — user ran the full local stack (`./deploy-go.sh --local`) and it CAUGHT A
  REAL BUG the plan's premise missed: the curl build on **alpine:latest** (curl
  8.21 / OpenSSL 3.5.7) reproduced the SAME 425 ("RETR response: 425") the Go code
  had. SPEC §4 error surfacing worked perfectly through the retry chain
  (`…failed: exit status 19: curl: (19) RETR response: 425`), and the 0-byte guard
  held (stale CWI file not overwritten). Root cause isolated on the droplet (same
  network as prod, real creds), testing curl in throwaway containers:
    · alpine:latest      curl 8.21.0 / OpenSSL 3.5.7  → 425 (exit 19)  ❌
    · debian:stable-slim curl 8.14.1 / OpenSSL 3.5.6  → (implied same family) ❌
    · debian:12-slim     curl 7.88.1 / OpenSSL 3.0.20 → 305,138 bytes (exit 0) ✅
    · ubuntu:24.04       curl 8.5.0  / OpenSSL 3.0.13 → 305,138 bytes (exit 0) ✅
    · droplet system     curl 8.9.1  / OpenSSL 3.3.1  → 305,138 bytes (exit 0) ✅
  Conclusion: OpenSSL **3.5.x** broke FTPS data-connection TLS session reuse
  (require_ssl_reuse); 3.0.x–3.3.x work. Fix = Dockerfile base image alpine →
  `debian:12-slim` (Unit 2 revised). This is NOT reopening curl-vs-Go: curl is
  still the transfer; only the container's curl/OpenSSL build had to change. Full
  rebuild + live-download re-verify with debian:12-slim still PENDING (droplet
  container test already proves the exact curl/OpenSSL combo downloads the file).

  RESOLVED — full local rebuild on debian:12-slim: multi-stage image built,
  `curl 7.88.1 / OpenSSL 3.0.20`, and DlChefworks logged `Downloaded
  CWI_INVENTORY.csv (305138 bytes) … total time 3.6s` on the LAPTOP too — so the
  earlier 425 was purely the OpenSSL 3.5.x version, never the network. File landed
  fresh + non-zero in /app/downloads. Unit 5 acceptance MET; fix validated
  end-to-end (build + curl + live download + atomic publish).

## Phase 3 — Commit & push BOTH repos  ⚠️ confirm with user first

### - [ ] Unit 6 — Commit submodule, then bump parent pointer  (COMMITTED LOCALLY; PUSH/MERGE PENDING — user-owned)
- **Show the full diff and get the user's explicit OK before committing.**
- In `go-usa-stock/` (branch `fix/chefworks-ftps-tls-resumption`): commit the
  chefworks.go + Dockerfile + go.mod/go.sum (+ main.go if Unit 4 done), then push.
- In the parent repo: `git add go-usa-stock` to record the new submodule SHA,
  commit (message noting the curl+alpine fix), push.
- **Acceptance:** both repos pushed; `git submodule status` shows the parent
  pointing at the new submodule commit; both are on the branch `deploy-go.sh` pulls
  (`GIT_BRANCH` in `deploy.env`).
- **Notes:** Diff shown + approved. Committed on branch
  `fix/chefworks-ftps-tls-resumption` in BOTH repos:
  · submodule `go-usa-stock` @ `2bbda0d` (curl rewrite + alpine Dockerfile + main.go
    directive removal + go.mod/go.sum tidy).
  · parent `do-droplet` @ `1345b0f` — records submodule pointer = 2bbda0d (+ todo.md).
  NOT pushed (user: "you dont need to push") and NOT on the deploy branch yet, so
  acceptance is NOT fully met — box left unticked. REMAINING before deploy is
  possible (all user-owned):
    1. Fix push access: GitHub rejects `~/.ssh/charlie-eb-github` (Permission denied
       (publickey)) — submodule remote `Charlie-EB/usa-stock` can't be pushed from
       here. Root remote is `CapSap/laughing-octo-waffle` (github.com).
    2. Submodule: user will merge `fix/chefworks-ftps-tls-resumption` → `main` and
       push (deploy fetches the recorded SHA; it must be reachable on the remote).
    3. Parent: land the pointer-bump on `master` (merge the feature branch) and push
       — `deploy.env GIT_BRANCH=master`, so the droplet only pulls `master`.
  Aside: user separately committed the fix docs + a deploy-go.sh convergence fix
  directly onto root `master` (30a9b8c, 197ee5d) during this unit.

## Phase 4 — Deploy  ⚠️ confirm with user first

### - [ ] Unit 7 — Pre-deploy sanity
- Confirm `deploy.env` (`DROPLET_HOST`, `SSH_USER`, `PROJECT_DIR`, `STACK_NAME`,
  `GIT_BRANCH`) and that the SSH agent is loaded for `root@stock-levels-app`.
- Confirm `GIT_BRANCH` matches the branch you pushed in Unit 6.
- **Acceptance:** config + SSH access confirmed; branch matches.
- **Notes:**

### - [ ] Unit 8 — Run the deploy
- **Get the user's explicit OK.** Then run `./deploy-go.sh` (touches only the
  go-usa-stock service; leaves pro-ftpd/node-app alone).
- Watch for the convergence step that force-updates the service onto the freshly
  built `:latest` image.
- **Acceptance:** deploy completes; convergence check reports the running task on
  the new image.
- **Notes:**

## Phase 5 — Verify on the droplet

### - [ ] Unit 9 — Confirm the fix live
On `root@stock-levels-app`:
- `docker image inspect go-usa-stock:latest --format 'Created: {{.Created}}'` → just now.
- `CID=$(docker ps -q -f name=sl-app-stack_go-usa-stock); docker exec "$CID" sh -c 'curl --version | head -1'` → curl present.
- `docker service logs sl-app-stack_go-usa-stock -t --since 15m | grep -i chefworks`
  → shows `Downloaded CWI_INVENTORY.csv (…bytes)`, not 425.
- `MP=$(docker volume inspect sl-app-stack_go-app --format '{{.Mountpoint}}'); ls -la --time-style=full-iso "$MP"`
  → `CWI_INVENTORY.csv` fresh (today) and non-zero.
- Chefworks healthchecks.io check is green.
- No new `DOCKER-DROPLET-R` (425) events in Sentry (org `entity-brands`, project `docker-droplet`).
- **Acceptance:** all six checks pass.
- **Notes:**

## Phase 6 — Wrap up

### - [ ] Unit 10 — Record outcome
- Note the result in `CHEFWORKS_FTPS_FIX_HANDOFF.md` (or a short addendum): fixed,
  date, image build time, first successful download size.
- Confirm whether the §5 mitigation file swap is now moot (a fresh real download
  supersedes it).
- **Acceptance:** outcome recorded; SPEC §6 "definition of done" all checked.
- **Notes:**

---

## Rollback (if Unit 8/9 goes wrong)
The old image failed only the chefworks download (served stale-but-valid data),
so a bad deploy is not catastrophic. To revert: point the parent submodule back
to the previous SHA (`git log` on `go-usa-stock`), push, re-run `./deploy-go.sh`.
The immediate mitigation in HANDOFF §5 (atomic-swap a fresh CSV into the volume)
can un-stick NetSuite meanwhile.
