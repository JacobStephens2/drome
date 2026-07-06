# All tunables + secrets. Secrets have NO default (they must be supplied
# explicitly, never fall back to a committed value); non-secret tunables carry
# sensible defaults matching plan.md.

# ---------------------------------------------------------------------------
# Secrets (no defaults — injected via TF_VAR_* from the GitHub `infra` env)
# ---------------------------------------------------------------------------

variable "do_token" {
  description = "DigitalOcean API token (read+write) — creates the droplet, volume, firewall, monitoring, etc."
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

variable "ssh_public_key" {
  description = "Admin SSH public key registered on the droplet (root/console access for break-glass). The everyday deploy path uses the separate deploy user."
  type        = string
}

variable "deploy_user_public_key" {
  description = "SSH public key for the unprivileged `deploy` user that CI SSHes in as (its private key lives ONLY in the GitHub `deploy` environment). Baked into cloud-init."
  type        = string
}

variable "alert_email" {
  description = "Destination email for DO monitor alerts (CPU/mem/disk) and the uptime-down alert. Not secret, but required."
  type        = string
}

# ---------------------------------------------------------------------------
# Droplet / region tunables
# ---------------------------------------------------------------------------

variable "region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "nyc3"
}

variable "droplet_size" {
  description = "Droplet size slug. Default is the Premium AMD 1 GB / 1 vCPU NVMe box (~$7/mo) confirmed for stephens.page (plan.md); bump to s-1vcpu-2gb-amd for 2 GB."
  type        = string
  default     = "s-1vcpu-1gb-amd"
}

variable "droplet_image" {
  description = "Base image slug for the droplet."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "deploy_user" {
  description = "Unprivileged Unix user CI deploys as (docker-group member; the everyday deploy path). Root SSH is key-only break-glass via the admin key, not this user."
  type        = string
  default     = "deploy"
}

variable "data_volume_size_gb" {
  description = "Size of the block-storage volume holding the SQLite DB, Litestream state, and Caddy's ACME certs (~$0.10/GiB-mo)."
  type        = number
  default     = 10
}

variable "data_mount_path" {
  description = "Mount point for the data volume inside the droplet (cloud-init mounts it here; compose binds onto it)."
  type        = string
  default     = "/mnt/drome-data"
}

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

variable "project_name" {
  description = "DigitalOcean project name that groups these resources."
  type        = string
  default     = "Drome"
}

variable "environment" {
  description = "Environment label used in resource names/tags."
  type        = string
  default     = "prod"
}

# ---------------------------------------------------------------------------
# DNS / domain
# ---------------------------------------------------------------------------

variable "domain" {
  description = "Root domain served by the droplet. .day is an HSTS-preloaded TLD (cert issuance on the critical path — see the CAA note in dns.tf)."
  type        = string
  default     = "drome.day"
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
  description = "R2 bucket name for opt-in encrypted progress photos (Phase 2+; blobs go direct via presigned URLs, never through the droplet)."
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

# ---------------------------------------------------------------------------
# Monitor alert thresholds (percent)
# ---------------------------------------------------------------------------

variable "cpu_alert_threshold" {
  description = "CPU utilization %% that trips the monitor alert."
  type        = number
  default     = 80
}

variable "memory_alert_threshold" {
  description = "Memory utilization %% that trips the monitor alert."
  type        = number
  default     = 80
}

variable "disk_alert_threshold" {
  description = "Disk utilization %% that trips the monitor alert."
  type        = number
  default     = 80
}
