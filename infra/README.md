# infra/ — Drome production infrastructure (OpenTofu)

One root module. Defines the DigitalOcean droplet + volume + reserved IP +
firewall + monitoring, and the Cloudflare drome.day zone + R2 buckets. Authored
now; **applied at the deploy milestone** (plan.md "Server infrastructure (IaC)"
and "GitOps"). Nothing here has been applied — no cloud credentials live in this
repo.

Files: `versions.tf` (pins) · `backend.tf` (encrypted R2 state) · `providers.tf`
· `variables.tf` · `project.tf` · `network.tf` (VPC, reserved IP, firewall) ·
`droplet.tf` · `storage.tf` (data volume) · `dns.tf` (CF zone, records, R2) ·
`monitoring.tf` (alerts, uptime) · `outputs.tf` · `templates/cloud-init.yaml.tftpl`.

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
   `cloudflare_token`, `cloudflare_account_id`, `ssh_public_key`,
   `deploy_user_public_key`, `alert_email`.
5. **Init + apply.**
   ```sh
   tofu init -backend-config=backend.hcl
   tofu plan -out tfplan     # review
   tofu apply tfplan
   ```
   (In CI this runs in the `infra` environment behind manual approval.)

## After the first apply — DNS cutover (timing matters)

- `tofu output cloudflare_nameservers` → set THOSE two nameservers at **Porkbun**
  (registrar stays Porkbun; Cloudflare hosts DNS). **Do the flip within 28 days**
  of the zone being created or Cloudflare may release the free zone (plan.md).
- The **CAA** record authorizing Let's Encrypt is created by the apply and must
  be live **before Caddy's first boot** — `.day` is HSTS-preloaded, so cert
  issuance is on the critical path (plan.md). Because Universal SSL adds its own
  partner-CA CAA records, a strict LE-only lockdown is not available.
- **DNSSEC** is free: enable it in the Cloudflare dashboard (or uncomment
  `cloudflare_zone_dnssec` in `dns.tf`) and enter the one DS record at Porkbun.
- Feed the deploy env from outputs:
  `tofu output -raw litestream_r2_access_key_id`,
  `tofu output -raw litestream_r2_secret_access_key`, and the bucket names.

## Recreate drills (plan.md "Recreate drills")

- **Droplet recreate** (e.g. a cloud-init edit — `user_data` is ForceNew): the
  volume, reserved IP, firewall (by tag), and DNS all survive. `tofu apply`, then
  re-run the deploy workflow. No restore.
- **Full from-zero** (disaster/migration): `tofu apply` builds everything;
  cloud-init installs docker; then `litestream restore` onto the empty volume
  **before** the deploy workflow (`deploy.sh` refuses to start over an empty data
  dir without `--restore`/`--fresh`, so a blank SQLite never overwrites the good
  replica). A fresh reserved IP means the A record updates (one change). This is
  also the quarterly restore drill.
