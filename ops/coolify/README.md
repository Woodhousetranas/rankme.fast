# Coolify deployment

This configuration is a deployment candidate. It does not configure live providers,
establish backups or prove production acceptance by itself.

Render from the reviewed upstream Compose definition with PowerShell 7:

```powershell
pwsh -NoProfile -File ops/coolify/render.ps1
pwsh -NoProfile -File ops/coolify/render.ps1 -Check
```

In Coolify, use a Git-based Docker Compose application with base directory `/`
and Compose location `/docker-compose.coolify.rendered.yml`. Select the reviewed
commit and enable **Raw (deploy file as-is)** plus **Preserve repository during
deployment**. Normal Coolify 4.4.6 injects the full runtime env file into every
service; raw mode keeps API/database secrets out of the public web container.
Preservation keeps the read-only `./docs` bind tied to the deployed source.
Set `APP_SOURCE_REVISION` to the full 40-character SHA and
`APP_BUILD_SHA` to its first 12 characters (the application's supported version
format). The full SHA is recorded in the image revision label. Do not deploy another task's
uncommitted working copy. The Dockerfiles include the committed `.npmrc` in both
dependency stages; no lockfile replacement is needed.

The container runtime uses the official digest-pinned Node 24 LTS image. Node 20
is EOL according to https://nodejs.org/en/about/previous-releases (checked
2026-10-18). Verify builds and real runtime behavior with this image.

Hosting uses existing Docker Desktop and containerized Coolify on the mini-PC.
Do not install Linux, create a new WSL distribution or prepare a VM/virtual disk
outside Docker without an explicit owner request.

The rendered file preserves environment interpolation and relative build paths.
It removes host-published ports and generated global volume/network names so
Coolify can give staging and production distinct identities. Keep
`connect_to_docker_network` false unless a separately reviewed integration needs it.

## Private HTTP routing and authentication

Use the same origin for client, API and authentication. Set `RANKME_HOST` to the
private hostname, default `rankme.localhost`. The source-owned Traefik labels
route `/api` to API8080 with priority100 and `/` to web3000 with priority10.
There is no prefix-stripping middleware. The external network name is the unique
`COOLIFY_RESOURCE_UUID` network that Coolify creates and connects to its proxy.
No domain-based proxy configuration is delegated to Coolify in raw mode.
Only web and API join that proxy network. MongoDB, PostgreSQL, Redis and worker
use the separate core network; API joins both. Core permits provider egress for
API/worker, while the public web service cannot directly resolve/access databases.

These labels provide private HTTP verification. Before public production, add and
verify the corresponding HTTPS/TLS routers for the chosen real domain; do not
publish the HTTP-only verifier as a production service.

This preserves the API's single trusted proxy hop and client IP rate limiting.
Routing all API traffic through the web proxy behind another proxy would replace
the client IP with the proxy peer. Do not weaken the existing forwarding-header
guard to compensate. Preserve deep-link routes on the web service, including
paths newly added by upstream; do not maintain a proxy-side SPA route allow-list.

Use the root `.env.example` as the variable inventory. Actual values belong only
in Coolify's resource environment / its protected generated root `.env`. Keep
the existing session and master encryption keys when migrating existing data.
Required private values pass through only explicitly selected runtime environment
keys; they are not required while parsing Compose for an image build. The
deployment preflight and application startup must reject missing values.
`CLIENT_URL`, `SERVER_URL`, optional `APP_URL`, and the Vite build-time origins
must match the chosen origins. Never put secrets in `VITE_*` variables.

## Production acceptance

- `NODE_ENV=production`; `ALLOW_FAKE_PROVIDERS=false`; real configured provider
  and email paths. A labelled staging demo may explicitly use fake providers.
- All six services healthy with the configured memory, CPU, PID and log limits.
- Through HTTPS: web page, `/api/health`, login, verified session, authenticated
  site listing and a refreshed deep link; cookies and cross-origin denial checked.
- Worker queue work and recovery checked with a bounded permitted operation.
  A fixture response does not establish live SEO vendor operation or delivery.
- Consistent MongoDB, PostgreSQL and Redis/queue recovery; encryption/configuration
  recovery files protected and copied outside the host; scheduled restore drill.
- Exact released source and image IDs recorded; source release merged before the
  production release is called finished. Preserve the original stack for rollback.
- Service, network and physical cold-start checks on the designated production host.

The currently installed mini-PC source stack is demo-only and has no live SEO or
email credentials. Publishing this manifest does not change that fact.

## Existing-stack consistent recovery

`recovery.ts` is an explicitly launched operator tool, not a server/worker module.
It runs as UID1000 in a fresh Docker volume with the Docker socket only for
maintenance. It imports no application/provider code. The original root `.env`
remains authoritative; the backup stores its cold copy plus actual per-service
runtime configuration. No `_FILE` resolver or app secret-file mount is introduced.

Build `ops/coolify/Dockerfile.operations` as `local/rankme-operations:20261018`.
Use PowerShell7 and `recovery.ps1 -Mode Prepare -StateFile <private-metadata.json>`
to freeze clean committed source. `-LiveSource` selects the existing original
project; the mini-PC default is its established canonical directory. Then run
`-Mode Preflight` and `-Mode TestGuard` with the same state file. Preflight checks
all six healthy original identities and available exact images, matching private
API/worker/SQL bindings, all24queues and read-only full data/schema proof. The
guard test SIGKILLs only a disposable job and starts three stopped fixtures.

`-Mode Run` requires both checks and an independent ready guard. It pauses API
and web, rejects active work, drains the idle worker and captures PostgreSQL
including non-public migration schemas, MongoDB documents/UUIDs/indexes, and a
consistent Redis RDB with absolute expiry and pending/delayed job data. It compares
the complete data before/after logical dumps, then resumes the same original
application IDs/configuration and verifies health. Databases remain running.
The guard resumes those exact original application IDs if the job dies.

The same job then restores into fresh project-labelled volumes on an internal
network with no ports. Only PostgreSQL, MongoDB and Redis start; no API, worker or
provider executes. Full SQL rows/schema/indexes, MongoDB BSON/index metadata and
byte-safe Redis contents must match. Expired TTL keys may elapse naturally; live
keys must retain their original absolute expiry. Restored Redis first reads the
RDB, builds AOF, and then passes a restart using AOF. All test stores stop and
their recovered data remains until explicitly cleaned. `-Mode Status` reports
only controlled phase logs. A passing local restore does not establish live
SEO/email provider operation or production authentication acceptance.

PostgreSQL logical dumps omit physical attribute slots of previously dropped
columns. The proof normalizes only those gaps, retaining relative column order;
every other byte of the SQL proof remains compared, including large integers.
The complete original raw proof stays in the protected backup.

If a consistent backup exists but a verifier needs repair, prepare fresh committed
code with a **different** state file. Run `-Mode RestoreExisting -StateFile <new>
-BackupStateFile <original>`. The retry mounts no live source, pauses no original
application and uses a fresh isolated project. The original state records the
separate verifier's exact container, volume and source revision. Preserve that
state together with the backup; do not repeat maintenance just to rerun a verifier.

`export-recovery.ps1 -StateFile <original>` requires a completed successful
original or retry verifier. Build the pinned `Dockerfile.backup-crypto` as
`local/coolify-backup-crypto:age-1.3.2`. The exporter checks that the six original
images contain no credential environment values, includes them and the frozen
backup/verifier source, then streams directly to an age encrypted archive under
`%LOCALAPPDATA%/Coolify/application-backups`. The entire decrypted stream must
match its original hash before publication; no plaintext tar is written to Windows.
Wrong-key, corruption and truncation checks run as well. The recovery identity
stays separately at `%LOCALAPPDATA%/Coolify/recovery-keys/mini-pc.agekey`; both
locations allow only the Windows owner and SYSTEM. Store a separate off-host
copy of that identity. A same-PC archive/key is not off-host disaster recovery.
The exporter does not upload data or select a paid storage/alert account.
