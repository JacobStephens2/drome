# The application droplet.

resource "digitalocean_droplet" "app" {
  name   = local.name_prefix
  region = var.region
  size   = var.droplet_size
  image  = var.droplet_image

  vpc_uuid = digitalocean_vpc.this.id
  ssh_keys = [digitalocean_ssh_key.admin.id]
  tags     = [digitalocean_tag.this.name]

  # monitoring = true installs the metrics agent that feeds the CPU/mem/disk
  # alerts in monitoring.tf (plan.md).
  monitoring = true

  # ipv6 for a modern dual-stack box; the firewall covers both families.
  ipv6 = true

  # Attach the data volume AT CREATION so it exists at first boot instead of
  # racing cloud-init (plan.md).
  volume_ids = [digitalocean_volume.data.id]

  # cloud-init: docker + compose, mount the data volume, create the deploy user.
  #
  # user_data is ForceNew: ANY edit here recreates the droplet. That is a
  # DESIGNED non-event — the volume (data), reserved IP (address), firewall
  # (by tag), and DNS all survive, so a recreate + re-run of the deploy workflow
  # restores service with no data movement. Rotating the deploy key is exactly
  # such an edit (plan.md "Sharp edges").
  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    deploy_user            = var.deploy_user
    deploy_user_public_key = var.deploy_user_public_key
    volume_name            = local.volume_name
    volume_label           = local.volume_label
    data_mount             = var.data_mount_path
  })
}
