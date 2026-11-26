# infra/ — Drome production infrastructure (OpenTofu)

One root module. Defines the Cloudflare drome.day zone + records, the R2
buckets and their scoped tokens, and the DigitalOcean `/healthz` uptime check.

Files: `versions.tf` (pins) · `backend.tf` (encrypted R2 state) · `providers.tf`
· `variables.tf` · `locals.tf` · `dns.tf` (CF zone, records, R2) ·
`monitoring.tf` (uptime check + alert) · `outputs.tf`.

## Hosting

drome.day runs on the **stephens.page** server (68.183.62.24) since 2026-11-26:
Docker Compose in `/srv/drome` behind Apache, deployed by
`.github/workflows/server-deploy.yml` through `deploy/drome-deploy`. That
server is not managed here; `var.server_ipv4` only points the apex A record at
it.

The original `drome-prod` droplet and its volume, reserved IP, VPC, firewall,
tag, admin SSH key, DO project and CPU/memory/disk alerts were removed from this
code at the same time. The first `tofu apply` after that **destroys** whichever
of them still exist (the volume's old `prevent_destroy` went with its block). If
you already deleted them in the DigitalOcean dashboard, the plan just drops them
from state. Either way, check the plan lists no `cloudflare_*` resource for
destruction: the zone and the R2 buckets hold drome.day's DNS, the Litestream
replica and the photos.

## Local checks (no cloud creds, no apply)

```sh
cd infra
tofu fmt -recursive          # formatting (always works locally)
tofu init -backend=false     # installs providers; NO backend/state touched
tofu validate                # type/reference checks
```

> On this Mac, `tofu init`/`validate` download the DigitalOcean + Cloudflare
> provider plugins, which are unsigned binaries — Santa Lockdown may SIGKILL
> them. If so, that is expected: `tofu fmt` still works locally and the
> `infra-ci.yml` GitHub workflow (Linux, no Santa) runs the real
> `init -backend=false` + `validate` on every PR. **Never run `plan`/`apply`
> locally** — there are no creds and it would touch real cloud.

## Bootstrap order (Jacob, once — do these BEFORE the first apply)

The state bucket and its token must exist before OpenTofu can store state, so
they are made by hand and never managed by the stack that stores state in them.

1. **R2 state bucket (by hand).** In Cloudflare R2, create a bucket, e.g.
   `drome-tofu-state`. Create an **R2 API token** scoped to it; note the S3
   **Access Key ID** and **Secret Access Key** R2 shows you (the secret is
   `sha256(token value)`, which the R2 UI computes for you).
   - **State protection (R2 has no object versioning).** Don't look for a
     versioning toggle — it doesn't exist on R2, and don't put a **Bucket Lock**
     on the whole bucket or the live state key: OpenTofu overwrites the state
     object on every apply, so a lock there bricks the backend. Instead: the
     state is already guarded by `use_lockfile = true` (no concurrent-write
     corruption) + the encryption block (encrypted at rest), and the apply
     workflow snapshots the encrypted state to `backups/<key>.<timestamp>`
     before every apply. Optionally add an R2 **lifecycle rule** on the
     `backups/` prefix to expire old copies (e.g. 90 days). Restore = copy a
     `backups/` object back onto the live key with `aws s3 cp --endpoint-url …`.
2. **State encryption passphrase.** Generate a passphrase (≥ 16 chars), store it
   in the password manager. This is `TF_VAR_state_encryption_passphrase`. **Lose
   it and the state is unrecoverable** — by design.
3. **Backend config.** `cp backend.hcl.example backend.hcl`, fill in the bucket,
   key, and R2 `endpoints.s3` (`https://<ACCOUNT_ID>.r2.cloudflarestorage.com`).
   Export the state creds:
   ```sh
   export AWS_ACCESS_KEY_ID=<r2 state token access key id>
   export AWS_SECRET_ACCESS_KEY=<sha256(r2 state token value)>
   export TF_VAR_state_encryption_passphrase=<passphrase from step 2>
   ```
4. **App/provider secrets.** Provide the rest as `TF_VAR_*` (or a gitignored
   `terraform.tfvars` — see `terraform.tfvars.example`): `do_token`,
   `cloudflare_token`, `cloudflare_account_id`, `alert_email`.
5. **Init + apply.**
   ```sh
   tofu init -backend-config=backend.hcl
   tofu plan -out tfplan     # review
   tofu apply tfplan
   ```
   (In CI this runs in the `infra` environment behind manual approval.)

## After the first apply — DNS (historical, done 2026-07)

- `tofu output cloudflare_nameservers` → those two nameservers are set at
  **Porkbun** (registrar stays Porkbun; Cloudflare hosts DNS).
- The **CAA** record authorizing Let's Encrypt must stay: `.day` is
  HSTS-preloaded, so cert issuance (certbot on stephens.page) is on the critical
  path. Because Universal SSL adds its own partner-CA CAA records, a strict
  LE-only lockdown is not available.
- **DNSSEC** is free: enable it in the Cloudflare dashboard (or uncomment
  `cloudflare_zone_dnssec` in `dns.tf`) and enter the one DS record at Porkbun.
- The Litestream credentials in `/srv/drome/.env` on stephens.page come from
  `tofu output -raw litestream_r2_access_key_id`,
  `tofu output -raw litestream_r2_secret_access_key`, and the bucket names.

## Restore drill

On stephens.page, with `/srv/drome/data/drome` empty:
`sudo -u drome-deploy /usr/local/bin/drome-deploy deploy <sha> restore` runs
`litestream restore` from R2 before starting the server. A normal deploy refuses
to start over an empty data dir, so a blank SQLite never starts a new Litestream
generation over the good replica.
