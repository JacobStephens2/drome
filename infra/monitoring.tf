# Uptime check on /healthz (plan.md "Resources"), notifying var.alert_email.
# It probes the public URL, so it does not care which server hosts drome.day.
# (The droplet CPU/memory/disk alerts went away with the droplet.)

# Free uptime check on the real health endpoint (which touches the DB, so it
# can't read green over a wedged server — see server /healthz, docs/PHASE2.md).
resource "digitalocean_uptime_check" "healthz" {
  name    = "${local.name_prefix}-healthz"
  target  = var.healthcheck_url
  type    = "https"
  regions = var.uptime_regions
  enabled = true
}

# Alert when the check reports down.
resource "digitalocean_uptime_alert" "healthz_down" {
  check_id   = digitalocean_uptime_check.healthz.id
  name       = "${local.name_prefix}-healthz-down"
  type       = "down"
  period     = "2m"
  comparison = "greater_than"
  threshold  = 1

  notifications {
    email = [var.alert_email]
  }
}
