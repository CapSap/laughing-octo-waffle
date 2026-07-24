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

### - [ ] Unit 1 — Rewrite `DlChefworks` to use curl
- Edit `go-usa-stock/fetcher/chefworks.go` to match SPEC §2a.
- Replace the whole `ftp.Dial`/`DialWithExplicitTLS`/`ClientSessionCache` block
  and the `Retr`/`io.Copy` transfer with the `exec.CommandContext("curl", …)` call.
- Update the import block: add `bytes`, `context`, `os/exec`, `strings`;
  remove `crypto/tls`, `io`, `github.com/jlaffaye/ftp`.
- Keep: mutex, `loadSecrets()`, temp-file + atomic rename, 0-byte guard, logging.
- Error must carry curl's trimmed stderr + wrapped exec error (SPEC §4).
- **Acceptance:** file compiles in isolation (checked in Unit 3); invariants
  SPEC §3 present by inspection; no `tls`/`ftp`/`io` imports remain in the file.
- **Notes:**

### - [ ] Unit 2 — Switch Dockerfile final stage to alpine + curl
- Edit `go-usa-stock/Dockerfile` final stage per SPEC §2b:
  `FROM alpine:latest`, `RUN apk add --no-cache curl ca-certificates`, keep the
  app binary + `authorised` copies, drop the manual `ca-certificates.crt` COPY and
  the stray final-stage `ENV CGO_ENABLED=0`. Builder stage unchanged.
- **Acceptance:** final stage installs curl via apk; no leftover scratch-only lines.
- **Notes:**

### - [ ] Unit 3 — Compile & tidy
- In `go-usa-stock/`: run `go build ./...` then `go vet ./...` then `go mod tidy`.
- Confirm `go.mod`/`go.sum` no longer list `github.com/jlaffaye/ftp`.
- **Acceptance:** build + vet clean; `grep jlaffaye go.mod` returns nothing.
- **Notes:**

### - [ ] Unit 4 — (Optional, low-priority) remove the go:debug directive
- In `go-usa-stock/`, `grep -rn "x509\|ParseCertificate\|tls.X509" --include=*.go`
  to confirm no Go code still parses the chefworks cert.
- If clean, remove `//go:debug x509negativeserial=1` and its comment from `main.go`.
- If any doubt, **leave it** and note why. It is harmless.
- **Acceptance:** either removed with grep evidence, or explicitly deferred with reason.
- **Notes:**

## Phase 2 — Local smoke test (recommended, no production impact)

### - [ ] Unit 5 — Build the alpine image locally
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
- **Notes:**

## Phase 3 — Commit & push BOTH repos  ⚠️ confirm with user first

### - [ ] Unit 6 — Commit submodule, then bump parent pointer
- **Show the full diff and get the user's explicit OK before committing.**
- In `go-usa-stock/` (branch `fix/chefworks-ftps-tls-resumption`): commit the
  chefworks.go + Dockerfile + go.mod/go.sum (+ main.go if Unit 4 done), then push.
- In the parent repo: `git add go-usa-stock` to record the new submodule SHA,
  commit (message noting the curl+alpine fix), push.
- **Acceptance:** both repos pushed; `git submodule status` shows the parent
  pointing at the new submodule commit; both are on the branch `deploy-go.sh` pulls
  (`GIT_BRANCH` in `deploy.env`).
- **Notes:**

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
