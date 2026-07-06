# Block-storage volume for the app's durable data: the SQLite DB, Litestream
# state, and Caddy's ACME certs. It is a SEPARATE resource from the droplet, so
# a droplet recreate (ForceNew user_data) detaches and reattaches it with the
# bytes intact — a recreate is a non-event (plan.md).
#
# `initial_filesystem_type` formats it ONCE at creation. Cloud-init additionally
# refuses to reformat an already-formatted device, so the data is safe even if
# this attribute is ever changed. The volume is attached at boot via the
# droplet's `volume_ids` (storage.tf → droplet.tf), so it exists at first boot
# rather than racing cloud-init.
resource "digitalocean_volume" "data" {
  name                     = local.volume_name
  region                   = var.region
  size                     = var.data_volume_size_gb
  initial_filesystem_type  = "ext4"
  initial_filesystem_label = local.volume_label
  description              = "Drome SQLite + Litestream + Caddy certs (durable across droplet recreate)."

  # Belt-and-suspenders: never let a plan silently destroy the data volume.
  lifecycle {
    prevent_destroy = true
  }
}
