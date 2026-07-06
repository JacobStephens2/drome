# State backend + encryption (plan.md "State").
#
# State lives in a DEDICATED R2 bucket, S3-compatible. That bucket and its
# access token are bootstrapped ONCE BY HAND (see README.md) and are never
# managed by this stack — a stack must not own the store that holds its own
# state.
#
# Backend blocks cannot reference input variables (they are read before the
# variable graph exists), so the bucket / key / endpoint / credentials are
# supplied at `tofu init` time via `-backend-config` (see backend.hcl.example)
# and the standard AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY environment
# variables (the R2 state token). Nothing secret is committed here.
terraform {
  backend "s3" {
    # R2-specific constants. `region = "auto"` + the skip_* flags disable the
    # AWS-only preflight calls R2 does not implement. `use_lockfile = true`
    # takes a lock object in the same bucket (R2 supports the conditional
    # writes S3-native locking needs) — no DynamoDB table required.
    region                      = "auto"
    use_lockfile                = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true

    # Supplied at init via -backend-config (README.md):
    #   bucket        = "drome-tofu-state"
    #   key           = "drome/prod/terraform.tfstate"
    #   endpoints     = { s3 = "https://<ACCOUNT_ID>.r2.cloudflarestorage.com" }
    #   access_key    = <R2 state token access key id>   (or AWS_ACCESS_KEY_ID)
    #   secret_key    = <R2 state token secret>          (or AWS_SECRET_ACCESS_KEY)
  }

  # State + plan encryption (AES-GCM, key derived from a PBKDF2 passphrase).
  # The passphrase is NEVER a literal: it comes from the input variable
  # `state_encryption_passphrase` (fed by TF_VAR_state_encryption_passphrase,
  # kept in the password manager). Lose it and the state is unrecoverable — a
  # deliberate property, not a footgun to route around.
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_encryption_passphrase
    }

    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method = method.aes_gcm.state
    }

    plan {
      method = method.aes_gcm.state
    }
  }
}
