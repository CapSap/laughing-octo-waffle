# Specification — chefworks FTPS download via curl

**Status:** decided, ready to build. **Scope:** `go-usa-stock` submodule (one Go
function + the Dockerfile), plus a submodule-pointer bump in the parent repo.

---

## 0. High-level goal (the thing all of this is in service of)

A **simple, reliable** inventory-sync service. The chefworks inventory file
(`CWI_INVENTORY.csv`) must download successfully on every scheduled refresh so
NetSuite is never served stale stock. When a download **does** fail, the failure
must **surface easily** — a clear error, logged to Sentry, with enough detail to
diagnose without SSHing anywhere. **Low long-term maintenance**: no hand-rolled
TLS, no hand-built binaries, standard boring tooling.

---

## 1. What is wrong today (one paragraph)

`DlChefworks` downloads over explicit FTPS using the Go library `jlaffaye/ftp`.
The chefworks server requires the PROT P data connection to **resume** the
control connection's TLS session. Go's `crypto/tls` cannot do this reliably
(it only offers a keyed session *cache*, not a direct session handoff), so every
download 425s: `Unable to build data connection: TLS session of data connection
not resumed`. The current code already applies the textbook Go workaround
(`ServerName` + `ClientSessionCache` + TLS 1.2 pin) and it still fails. `curl`
(OpenSSL) resumes the session automatically and downloads the file perfectly.

---

## 2. The final shape

### 2a. `go-usa-stock/fetcher/chefworks.go`

`DlChefworks` shells out to `curl` instead of using `jlaffaye/ftp`. It keeps the
exact same responsibilities as today: acquire `downloadMutex`, load secrets,
download to a temp file, guard against a 0-byte result, atomically rename into
place, and log. It no longer imports `crypto/tls`, `io`, or `jlaffaye/ftp`.

**Reference implementation (this is the target; the invariants in §3–4 are what
actually matter — adapt if the tree differs):**

```go
package fetcher

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func DlChefworks() error {
	downloadMutex.Lock()
	defer downloadMutex.Unlock()

	start := time.Now()
	fmt.Printf("chefworks download started at %s\n", start.Format(time.RFC1123))

	secrets, err := loadSecrets()
	if err != nil {
		return fmt.Errorf("failed to load secrets: %w", err)
	}

	host := secrets["chefworks_remote_url"]
	port := secrets["chefworks_remote_port"]
	user := secrets["chefworks_remote_username"]
	pass := secrets["chefworks_remote_password"]
	remotePath := filepath.Join(secrets["chefworks_remote_dir"], secrets["chefworks_remote_filename"])
	url := fmt.Sprintf("ftp://%s:%s%s", host, port, remotePath)

	outputFile := "CWI_INVENTORY.csv"
	downloadsPath := "/app/downloads"
	if err := os.MkdirAll(downloadsPath, 0755); err != nil {
		return fmt.Errorf("failed to create directory %s: %w", downloadsPath, err)
	}
	tempFilePath := filepath.Join(downloadsPath, outputFile+".tmp")
	finalFilePath := filepath.Join(downloadsPath, outputFile)

	// curl performs explicit FTPS (AUTH TLS) and, unlike Go's crypto/tls,
	// reuses the control connection's TLS session on the PROT P data
	// connection as this server requires (require_ssl_reuse). The cert is
	// self-signed so verification is skipped (traffic still encrypted).
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "curl",
		"-fsS",                 // fail on FTP errors (exit != 0), silent, but show error text
		"--ssl-reqd",           // require AUTH TLS (explicit FTPS)
		"--insecure",           // self-signed cert: skip verification
		"--ftp-pasv",           // passive mode
		"--connect-timeout", "30",
		"-u", user+":"+pass,    // credentials NOT in the URL; curl splits on the first ':'
		url,
		"-o", tempFilePath,
	)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		os.Remove(tempFilePath)
		return fmt.Errorf("curl download of %s failed: %w: %s",
			url, err, strings.TrimSpace(stderr.String()))
	}

	info, err := os.Stat(tempFilePath)
	if err != nil {
		return fmt.Errorf("temp file missing after curl download: %w", err)
	}
	if info.Size() == 0 {
		os.Remove(tempFilePath)
		return fmt.Errorf("downloaded 0 bytes for %s, refusing to replace existing file", url)
	}

	// Atomic replace: in-flight SFTP reads keep the old inode; new opens get the new file.
	if err := os.Rename(tempFilePath, finalFilePath); err != nil {
		os.Remove(tempFilePath)
		return fmt.Errorf("failed to rename file: %w", err)
	}

	fmt.Printf("Downloaded %s (%d bytes) to %s (total time: %v)\n",
		outputFile, info.Size(), finalFilePath, time.Since(start))
	return nil
}
```

### 2b. `go-usa-stock/Dockerfile` (final stage only; builder stage unchanged)

```dockerfile
# --- STAGE 2: PRODUCTION ---
FROM alpine:latest
WORKDIR /
RUN apk add --no-cache curl ca-certificates
COPY --from=builder /go/bin/app /usr/local/bin/app
COPY --from=builder /usr/src/app/authorised /authorised
CMD ["/usr/local/bin/app"]
```

- `apk add ca-certificates` provides the CA bundle at `/etc/ssl/certs/` that the
  Go binary needs for its HTTPS calls (healthchecks.io, Sentry) — so the old
  manual `COPY … ca-certificates.crt` line is **removed**.
- The builder stage still uses `CGO_ENABLED=0`; a pure-Go static binary runs fine
  on alpine/musl. Keep `authorised` (SFTP authorized-keys dir). Drop the stray
  `ENV CGO_ENABLED=0` on the final stage (meaningless at runtime).

### 2c. `go-usa-stock/main.go` (optional, low-priority cleanup)

Remove the `//go:debug x509negativeserial=1` directive and its comment. It was
only there so Go's x509 parser would accept chefworks' negative-serial cert on
the FTP path. curl (`--insecure`) now owns that connection and no Go code parses
that cert (sanmar is SSH/SFTP, not x509). **Only remove after grep-verifying** no
other Go code parses the chefworks cert. If unsure, leave it — it is harmless.

---

## 3. Invariants that MUST hold (these are the real spec)

1. **Atomic publish:** download to `CWI_INVENTORY.csv.tmp`, then `os.Rename` to
   `CWI_INVENTORY.csv`. Never write the final path directly.
2. **0-byte guard:** if the download is empty, delete the temp file and return an
   error — never replace a good file with an empty one.
3. **Mutex preserved:** `downloadMutex.Lock()/Unlock()` stays (serializes downloads).
4. **Secrets via `loadSecrets()`:** read the same 7 `chefworks_*` keys already in
   use (see §5). Do not hardcode anything.
5. **Timeout:** the download cannot hang forever (context timeout + connect-timeout).
6. **curl fails loudly:** `-f` so an FTP error (425, 530, …) is a non-zero exit.
7. **No new deps, no new files:** just curl (from the image) + the Go stdlib.
8. **Untouched:** `DlSanmar`, the SFTP server, `Sources` config (`fetcher.go`),
   `withRetry`/`withHealthcheck`, `sentry`, and `main.go`'s error paths.

---

## 4. Error surfacing (the user's explicit priority) — how it must behave

The chain already exists; do not modify it. Your job is only to feed it a good error.

```
DlChefworks()  ──returns error──▶  withRetry(3, 10s)  ──final error──▶  withHealthcheck("chefworks_healthcheck_url")
                                                                          │  pings <url>/fail on failure
                                                                          ▼
                        main.go startup loop / EnsureFresh goroutine  ──▶  sentry.Notify(err, "…download of CWI_INVENTORY.csv failed")
```

Requirement on the returned error:
- On a curl failure, the error MUST contain **both** the wrapped exec error
  (`%w`) **and** curl's trimmed stderr. Example resulting message:
  `curl download of ftp://ftp.chefworks.com:990/CWI_INVENTORY.csv failed: exit status 78: curl: (78) RETR response: 425`
- Transient failures self-heal via `withRetry` (3 attempts, 10s apart) and produce
  **no** Sentry event; only a final, all-retries-exhausted failure alerts.
- Success on any attempt pings the healthcheck OK; final failure pings `/fail`.

Acceptance for "error surfacing works": force a failure (e.g. bad password in a
`--local` run) and confirm the Sentry-bound error string includes the curl `(NN)`
diagnostic, not a generic message.

---

## 5. Facts the implementer needs (verified 2026-07-24)

- **Secret keys** (via `loadSecrets()` → `utils.GetDockerSecret()`):
  `chefworks_remote_url` (=`ftp.chefworks.com`), `chefworks_remote_port` (=`990`),
  `chefworks_remote_dir` (=`/`), `chefworks_remote_filename` (=`CWI_INVENTORY.csv`),
  `chefworks_remote_username`, `chefworks_remote_password` (8 chars),
  `chefworks_healthcheck_url`.
- `filepath.Join("/", "CWI_INVENTORY.csv")` → `/CWI_INVENTORY.csv`, giving URL
  `ftp://ftp.chefworks.com:990/CWI_INVENTORY.csv`.
- Port 990 here is **explicit** FTPS (plaintext connect + AUTH TLS), NOT implicit
  — so the scheme is `ftp://` with `--ssl-reqd`, NOT `ftps://`. (Implicit `ftps://`
  fails against this server with "wrong version number".)
- Proven-working command (from diagnosis, downloaded 305,175 bytes):
  `curl -fsS --ssl-reqd --insecure --ftp-pasv -u "$USER:$PASS" "ftp://$HOST:$PORT/$FILE" -o out.csv`
- Container data volume `sl-app-stack_go-app` is mounted at `/app/downloads`.
- `jlaffaye/ftp` and `crypto/tls` are imported **only** by `chefworks.go`, so after
  the rewrite `go mod tidy` removes `jlaffaye/ftp` from `go.mod`/`go.sum` cleanly.
- Known trade-off (accepted): `-u user:pass` puts the password in the container's
  process argv (`/proc/PID/cmdline`). Single-tenant container → low risk. If it
  ever matters, switch to a temp `--netrc-file`; not required now.

---

## 6. Definition of done

- [ ] `DlChefworks` uses curl per §2a; invariants §3 hold; error surfacing §4 holds.
- [ ] Dockerfile final stage is alpine with curl + ca-certificates (§2b).
- [ ] `go build ./...` succeeds; `go mod tidy` has dropped `jlaffaye/ftp`.
- [ ] Submodule committed & pushed **and** parent-repo pointer bumped, committed & pushed.
- [ ] Deployed via `./deploy-go.sh`; the running container is on the freshly-built image.
- [ ] On the droplet: logs show `Downloaded CWI_INVENTORY.csv (…bytes)`, the volume
      file is fresh and non-zero, the chefworks healthcheck is green, and no new
      `DOCKER-DROPLET-R` (425) events appear in Sentry.

---

## 7. Why curl and not "just fix the Go TLS" (do not relitigate)

The current code already does the canonical Go fix (`ServerName` +
`ClientSessionCache` + TLS 1.2 pin) and 425s every time. Upstream `jlaffaye/ftp`
issues (#203, #223, #323, #342, #425, #435) are a multi-year, still-open graveyard
of this exact failure across FileZilla/pure-ftpd/vsftpd; the `DialWithDialFunc`
escape hatch has its own open hang bug (#425) and TLS 1.3 fails too (#323).
Root reason: curl/OpenSSL performs a **direct** control→data TLS session handoff;
Go's `crypto/tls` only offers a keyed session *cache*, with no API to resume a
specific session on a new connection. That gap is not fixable from outside the
stdlib. curl is the simple, reliable, low-maintenance answer — which is the goal.
