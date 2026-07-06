# Non-secret outputs for wiring the deploy step + the Porkbun nameserver flip.
# The two sensitive R2 outputs derive the S3 credentials so no secret is ever
# copied by hand.

output "reserved_ip" {
  description = "The droplet's reserved (floating) IP — this is what the drome.day A record points at."
  value       = digitalocean_reserved_ip.app.ip_address
}

output "droplet_id" {
  description = "DigitalOcean droplet id."
  value       = digitalocean_droplet.app.id
}

output "droplet_urn" {
  description = "Droplet URN (for the DO project / references)."
  value       = digitalocean_droplet.app.urn
}

output "cloudflare_zone_id" {
  description = "drome.day Cloudflare zone id."
  value       = cloudflare_zone.drome.id
}

output "cloudflare_nameservers" {
  description = "Set THESE as the nameservers at Porkbun to activate the zone (plan.md: within 28 days of zone creation)."
  value       = cloudflare_zone.drome.name_servers
}

output "r2_photos_bucket" {
  description = "Photos R2 bucket name."
  value       = cloudflare_r2_bucket.photos.name
}

output "r2_litestream_bucket" {
  description = "Litestream R2 bucket name."
  value       = cloudflare_r2_bucket.litestream.name
}

# --- Litestream S3 credentials (derived; feed these into the deploy env) ---
# S3 access key id == the API token id; S3 secret == sha256(token value).
output "litestream_r2_access_key_id" {
  description = "S3 access key id for the Litestream R2 token (the token id)."
  value       = cloudflare_api_token.litestream.id
}

output "litestream_r2_secret_access_key" {
  description = "S3 secret access key for Litestream = sha256(token value). Feed into the deploy env as LITESTREAM_R2_SECRET_ACCESS_KEY."
  value       = sha256(cloudflare_api_token.litestream.value)
  sensitive   = true
}

output "photos_r2_access_key_id" {
  description = "S3 access key id for the photos R2 token (the token id)."
  value       = cloudflare_api_token.photos.id
}

output "photos_r2_secret_access_key" {
  description = "S3 secret access key for photos = sha256(token value)."
  value       = sha256(cloudflare_api_token.photos.value)
  sensitive   = true
}
