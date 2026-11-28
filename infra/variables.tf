# All tunables + secrets. Secrets have NO default (they must be supplied
# explicitly, never fall back to a committed value); non-secret tunables carry
# sensible defaults matching plan.md.

# ---------------------------------------------------------------------------
# Secrets (no defaults — injected via TF_VAR_* from the GitHub `infra` env)
# ---------------------------------------------------------------------------

variable "do_token" {
  description = "DigitalOcean API token — only the /healthz uptime check and its alert live on DigitalOcean now."
  type        = string
  sensitive   = true
}

variable "cloudflare_token" {
  description = "Cloudflare API token scoped to Zone:Edit + DNS:Edit + Workers R2 Storage:Edit + API Tokens:Edit for the drome.day zone and R2. Distinct from the DO token so DNS/R2 is outside the DO token's blast radius (plan.md)."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the drome.day zone and the R2 buckets."
  type        = string
}

variable "state_encryption_passphrase" {
  description = "PBKDF2 passphrase for OpenTofu state/plan encryption (min 16 chars). Kept in the password manager; state is unrecoverable without it. Consumed by the encryption block in backend.tf."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_encryption_passphrase) >= 16
    error_message = "state_encryption_passphrase must be at least 16 characters (OpenTofu PBKDF2 minimum)."
  }
}

variable "alert_email" {
  description = "Destination email for the uptime-down alert. Not secret, but required."
  type        = string
}

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

variable "environment" {
  description = "Environment label used in resource names/tags."
  type        = string
  default     = "prod"
}

# ---------------------------------------------------------------------------
# DNS / domain
# ---------------------------------------------------------------------------

variable "domain" {
  description = "Root domain served by the stephens.page server. .day is an HSTS-preloaded TLD (cert issuance on the critical path — see the CAA note in dns.tf)."
  type        = string
  default     = "drome.day"
}

variable "server_ipv4" {
  description = "Public IPv4 of the server that hosts drome.day (stephens.page). The apex A record points here."
  type        = string
  default     = "68.183.62.24"
}

variable "healthcheck_url" {
  description = "URL the DO uptime check probes."
  type        = string
  default     = "https://drome.day/healthz"
}

variable "uptime_regions" {
  description = "Regions the DO uptime check probes from."
  type        = list(string)
  default     = ["us_east", "eu_west"]
}

# ---------------------------------------------------------------------------
# R2 (Cloudflare object storage)
# ---------------------------------------------------------------------------

variable "r2_photos_bucket" {
  description = "R2 bucket name for opt-in encrypted progress photos (Phase 2+; blobs go direct via presigned URLs, never through the server)."
  type        = string
  default     = "drome-photos"
}

variable "r2_litestream_bucket" {
  description = "R2 bucket name Litestream continuously replicates the SQLite DB to."
  type        = string
  default     = "drome-litestream"
}

variable "r2_location" {
  description = "R2 bucket location hint (only honored at first creation). One of: apac, eeur, enam, weur, wnam, oc."
  type        = string
  default     = "enam"
}

