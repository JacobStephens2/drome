# Provider configuration. Both tokens are secrets with no defaults; they are
# injected as TF_VAR_do_token / TF_VAR_cloudflare_token from the GitHub `infra`
# environment (plan.md GitOps "Secrets").
provider "digitalocean" {
  token = var.do_token
}

provider "cloudflare" {
  api_token = var.cloudflare_token
}
