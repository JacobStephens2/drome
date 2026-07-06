# Project grouping, resource tag, and the SSH keys. ~15 resources total, no
# IAM/VPC ceremony (plan.md "config-surface simplicity").

locals {
  name_prefix = "drome-${var.environment}"

  # DO Volume names must be lowercase alphanumeric + dashes. Also used to build
  # the /dev/disk/by-id path in cloud-init, so keep it stable.
  volume_name  = "${local.name_prefix}-data"
  volume_label = "drome-data"
}

# Tag the firewall attaches BY (plan.md: cloud firewall attached by tag, so a
# droplet recreate re-inherits the rules automatically).
resource "digitalocean_tag" "this" {
  name = local.name_prefix
}

# Break-glass admin key (console/root). Everyday deploys use the deploy user.
resource "digitalocean_ssh_key" "admin" {
  name       = "${local.name_prefix}-admin"
  public_key = var.ssh_public_key
}

# Project groups the droplet + volume + reserved IP in the DO console.
resource "digitalocean_project" "this" {
  name        = var.project_name
  description = "Drome production server (IaC-managed; plan.md Phase 2)."
  purpose     = "Web Application"
  environment = "Production"

  resources = [
    digitalocean_droplet.app.urn,
    digitalocean_volume.data.urn,
    digitalocean_reserved_ip.app.urn,
  ]
}
