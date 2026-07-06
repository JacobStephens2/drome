# OpenTofu + provider pins (plan.md "Server infrastructure (IaC)").
#
# OpenTofu (NOT Terraform) is chosen for native state encryption and the MPL
# license; >= 1.12 is required for the state-encryption + S3 `use_lockfile`
# feature set this stack relies on.
terraform {
  required_version = ">= 1.12"

  required_providers {
    # DigitalOcean is a partner-tier provider (weekly releases, first-class
    # monitoring/uptime resources). 2.93 was current at authoring (2026-07).
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.93"
    }

    # Cloudflare v5 is a machine-generated rewrite (occasionally rough); pin
    # >= 5.21 per plan and hold below 6.0 so a major bump can't land silently.
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.21"
    }
  }
}
