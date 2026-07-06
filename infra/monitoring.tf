# Monitor alerts (fed by the droplet's monitoring agent) + the uptime check on
# /healthz (plan.md "Resources"). All notify var.alert_email.

resource "digitalocean_monitor_alert" "cpu" {
  alerts {
    email = [var.alert_email]
  }
  window      = "5m"
  type        = "v1/insights/droplet/cpu"
  compare     = "GreaterThan"
  value       = var.cpu_alert_threshold
  enabled     = true
  entities    = [digitalocean_droplet.app.id]
  description = "Drome: CPU high"
}

resource "digitalocean_monitor_alert" "memory" {
  alerts {
    email = [var.alert_email]
  }
  window      = "5m"
  type        = "v1/insights/droplet/memory_utilization_percent"
  compare     = "GreaterThan"
  value       = var.memory_alert_threshold
  enabled     = true
  entities    = [digitalocean_droplet.app.id]
  description = "Drome: memory high"
}

resource "digitalocean_monitor_alert" "disk" {
  alerts {
    email = [var.alert_email]
  }
  window      = "5m"
  type        = "v1/insights/droplet/disk_utilization_percent"
  compare     = "GreaterThan"
  value       = var.disk_alert_threshold
  enabled     = true
  entities    = [digitalocean_droplet.app.id]
  description = "Drome: disk high"
}

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
