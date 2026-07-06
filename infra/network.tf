# VPC, reserved IP, and the cloud firewall.

# A dedicated VPC keeps the droplet off the region's shared default network.
resource "digitalocean_vpc" "this" {
  name     = "${local.name_prefix}-vpc"
  region   = var.region
  ip_range = "10.10.10.0/24"
}

# Reserved (floating) IP. It is a SEPARATE resource from the droplet and the
# assignment, so a droplet recreate re-points the assignment WITHOUT changing
# the address — the DNS A record stays valid (plan.md "Sharp edges").
resource "digitalocean_reserved_ip" "app" {
  region = var.region
}

resource "digitalocean_reserved_ip_assignment" "app" {
  ip_address = digitalocean_reserved_ip.app.ip_address
  droplet_id = digitalocean_droplet.app.id
}

# The ONLY firewall. Attached BY TAG so a recreated droplet re-inherits it, and
# — critically — Docker's iptables port-publishing cannot punch through DO's
# cloud firewall the way it bypasses ufw, so this is a real, sufficient boundary
# (plan.md "Sharp edges").
resource "digitalocean_firewall" "this" {
  name = "${local.name_prefix}-fw"
  tags = [digitalocean_tag.this.name]

  # Inbound: SSH + HTTP + HTTPS (443/udp for HTTP/3/QUIC). Everything else deny.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "udp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Outbound: allow all (package installs, GHCR pulls, R2/Litestream, ACME).
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
