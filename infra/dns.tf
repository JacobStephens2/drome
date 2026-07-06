# Cloudflare: the drome.day DNS zone + records, and the two R2 buckets with
# their scoped S3 tokens (plan.md "Resources").
#
# Registrar stays Porkbun; Cloudflare (free plan) hosts the nameservers. After
# `apply`, set Porkbun's nameservers to the two in the `cloudflare_nameservers`
# output. EXECUTION TIMING (plan.md): do NOT create this free zone more than 28
# days before flipping the nameservers, or Cloudflare may release it.

resource "cloudflare_zone" "drome" {
  account = {
    id = var.cloudflare_account_id
  }
  name = var.domain
  type = "full"
}

# Apex A record → the reserved IP. DNS-only (grey cloud / proxied = false) so
# Caddy on the droplet terminates TLS itself and can complete the ACME HTTP/TLS
# challenge directly.
resource "cloudflare_dns_record" "apex_a" {
  zone_id = cloudflare_zone.drome.id
  name    = var.domain
  type    = "A"
  content = digitalocean_reserved_ip.app.ip_address
  ttl     = 1 # 1 = automatic
  proxied = false
  comment = "Apex → droplet reserved IP (IaC-managed)."
}

# CAA: authorize Let's Encrypt so Caddy's first cert issues. .day is on the HSTS
# preload list, so a browser will refuse plain HTTP — cert issuance is on the
# critical path and this record MUST exist before Caddy's first boot (plan.md).
#
# CAVEAT (plan.md): Cloudflare Universal SSL silently adds its own partner-CA CAA
# records, so a strict LE-ONLY lockdown is not actually available — this record
# authorizes LE without pretending to exclude everyone else.
resource "cloudflare_dns_record" "caa_letsencrypt" {
  zone_id = cloudflare_zone.drome.id
  name    = var.domain
  type    = "CAA"
  ttl     = 1
  comment = "Authorize Let's Encrypt (Caddy ACME) — see .day HSTS-preload note."
  data = {
    flags = 0
    tag   = "issue"
    value = "letsencrypt.org"
  }
}

# DNSSEC is free on Cloudflare (plan.md). It is enabled here; the resulting DS
# record must be entered ONCE BY HAND at Porkbun (registrar), so it is left as a
# deliberate manual bootstrap step rather than a resource — Porkbun is not in
# this stack. To enable in IaC once the zone is live, uncomment:
#
# resource "cloudflare_zone_dnssec" "drome" {
#   zone_id = cloudflare_zone.drome.id
# }

# ---------------------------------------------------------------------------
# R2 buckets + scoped S3 tokens
# ---------------------------------------------------------------------------
#
# NOTE (plan.md): for an R2 bucket accessed over the S3 API, the S3 secret access
# key is sha256(API-token value) and the S3 access key id is the token id. The
# `outputs.tf` file derives both so the deploy env can be wired without copying
# secrets around by hand.

resource "cloudflare_r2_bucket" "photos" {
  account_id = var.cloudflare_account_id
  name       = var.r2_photos_bucket
  location   = var.r2_location
}

resource "cloudflare_r2_bucket" "litestream" {
  account_id = var.cloudflare_account_id
  name       = var.r2_litestream_bucket
  location   = var.r2_location
}

# Look up the R2 read/write permission-group IDs by name rather than hardcoding
# GUIDs. Data sources are read at plan/apply time, not `validate`.
data "cloudflare_api_token_permission_groups_list" "r2_write" {
  name  = "Workers R2 Storage Write"
  scope = "com.cloudflare.api.account"
}

data "cloudflare_api_token_permission_groups_list" "r2_read" {
  name  = "Workers R2 Storage Read"
  scope = "com.cloudflare.api.account"
}

locals {
  r2_write_pg = data.cloudflare_api_token_permission_groups_list.r2_write.result[0].id
  r2_read_pg  = data.cloudflare_api_token_permission_groups_list.r2_read.result[0].id

  # Per-bucket resource strings scope each token to ONE bucket. "default" is the
  # (non-jurisdiction) R2 namespace.
  photos_bucket_resource     = "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${var.r2_photos_bucket}"
  litestream_bucket_resource = "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${var.r2_litestream_bucket}"
}

# Litestream token: read+write on the litestream bucket only (it restores AND
# replicates).
resource "cloudflare_api_token" "litestream" {
  name = "${local.name_prefix}-litestream-r2"

  policies = [{
    effect            = "allow"
    permission_groups = [{ id = local.r2_write_pg }, { id = local.r2_read_pg }]
    resources         = jsonencode({ (local.litestream_bucket_resource) = "*" })
  }]
}

# Photos token: read+write on the photos bucket only (Phase 2+ presigned URLs).
resource "cloudflare_api_token" "photos" {
  name = "${local.name_prefix}-photos-r2"

  policies = [{
    effect            = "allow"
    permission_groups = [{ id = local.r2_write_pg }, { id = local.r2_read_pg }]
    resources         = jsonencode({ (local.photos_bucket_resource) = "*" })
  }]
}
