# Shared naming. The DigitalOcean droplet, volume, reserved IP, VPC, firewall,
# tag, SSH key and project were removed on 2026-11-26 when drome.day moved to
# the stephens.page server (see README.md "Hosting").

locals {
  name_prefix = "drome-${var.environment}"
}
