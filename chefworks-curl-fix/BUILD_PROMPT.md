# Build prompt — chefworks FTPS → curl fix

> Paste this whole file as the opening message to a fresh Claude Code session
> working in `/home/charlie/projects/do-droplet`.

You are implementing a decided, investigated fix. The investigation is done — do
**not** re-open the "curl vs. a Go TLS fix" question. If you feel tempted to try
fixing the Go `crypto/tls` session-reuse path instead, stop: that exact approach
(ServerName + `ClientSessionCache` + TLS 1.2 pin) is **already in production and
has failed every day for a week**. curl is the chosen fix because OpenSSL hands
the control-connection TLS session directly to the data connection, which is the
one thing Go's `crypto/tls` cannot reliably do. Background is in
`chefworks-curl-fix/SPEC.md` §7 if you need it.

## The North Star (the user's own words — keep these in mind at every step)

> "I want a simple service that is reliable. When it fails I want the error to
> surface easily and log to Sentry for troubleshooting. I do not want the
> long-term maintenance to become a chore."

Every decision serves **simple + reliable + easy-to-diagnose + low-maintenance**,
in that order. When in doubt, choose the boring, standard, obvious option.

## First: read these files (in this order) before touching anything

1. `chefworks-curl-fix/SPEC.md`   — the target shape and the invariants that must hold.
2. `chefworks-curl-fix/todo.md`   — the ordered units of work; you will drive from this.
3. `CHEFWORKS_FTPS_FIX_HANDOFF.md` — full diagnosis, environment, deploy & verify details.
4. `go-usa-stock/fetcher/chefworks.go`   — the function you are rewriting (`DlChefworks`).
5. `go-usa-stock/fetcher/fetcher.go`      — the retry wrapper + `Sources` config (do NOT change).
6. `go-usa-stock/fetcher/healthcheck.go`  — how failures ping healthchecks.io (do NOT change).
7. `go-usa-stock/main.go`                 — startup download loop + Sentry notify + the go:debug directive.
8. `go-usa-stock/Dockerfile`              — the image you are switching scratch → alpine.
9. `deploy-go.sh`                         — how deploy works. READ IT before you ever run it.

## The Sentry error-surfacing requirement (non-negotiable)

The whole point of the retry/healthcheck/Sentry chain already exists and works.
Your rewrite of `DlChefworks` must return an error that makes a failure
**diagnosable from the Sentry event alone**. Concretely: capture curl's stderr
and include it (trimmed) plus the wrapped exec error in the returned error. curl
run with `-fsS` prints things like `curl: (78) RETR response: 425` to stderr —
that string is what makes Sentry useful. Do not swallow it, do not return a
generic message. See SPEC.md §4.

## How to work

- Drive from `chefworks-curl-fix/todo.md`. Do **one unit of work per turn**, in
  order. After finishing a unit, tick its checkbox `- [x]` and add a one-line
  note (what you did / what you verified) in that unit's **Notes**.
- Each unit lists an **Acceptance** line — do not tick the box until it is met.
- **Show the diff and stop for confirmation before Unit 6 (commit) and Unit 8
  (deploy).** These are production-affecting and require the user's explicit go.
- The real code lives in the `go-usa-stock` **submodule**. Deploy pulls BOTH the
  submodule commit AND the parent-repo pointer bump — committing only one ships
  old code. This is the single most common way this deploy goes wrong.
- Do not touch: sanmar (`DlSanmar`, SFTP), the SFTP server, the `Sources` config,
  the retry/healthcheck wrappers, or `main.go`'s error handling. The only Go
  function you rewrite is `DlChefworks`. (The go:debug directive removal in
  main.go is a separate, clearly-scoped, optional unit.)

Start by reading the files above, then begin at Unit 1 of `todo.md`.
