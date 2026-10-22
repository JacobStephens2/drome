#!/usr/bin/env bash
# Push-based deploy for the Drome server (plan.md GitOps "App pipeline").
#
# Runs on the CI runner (or a laptop). It SSHes to the droplet as the deploy
# user, rsyncs deploy/, writes .env from the environment (including
# IMAGE_TAG=<git-sha ref>), logs into GHCR with a read-only pull token, then
# `docker compose pull && up -d`, and finally verifies /healthz ON the droplet
# (exec'd inside the new container, not via public DNS) — failing LOUDLY if the
# deploy is unhealthy.
#
# Litestream restore-before-up guard: it REFUSES to `up -d` against an empty
# data dir unless you pass --restore (recover the DB from R2 first) or --fresh
# (accept a brand-new empty DB). This is what stops a blank SQLite from starting
# a NEW Litestream generation over the good replica (plan.md "Recreate drills").
#
# Rollback is not a mode here: re-run this with IMAGE_TAG set to an earlier SHA
# (the image already exists in GHCR). The server-deploy workflow exposes that as
# a workflow_dispatch input.
set -euo pipefail

# --------------------------------------------------------------------------
# Config (from environment; secrets come from the GitHub `deploy` environment)
# --------------------------------------------------------------------------
DEPLOY_HOST="${DEPLOY_HOST:?set DEPLOY_HOST (droplet reserved IP or drome.day)}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
IMAGE_TAG="${IMAGE_TAG:?set IMAGE_TAG to the full GHCR ref pinned to the git SHA}"
GHCR_USER="${GHCR_USER:?set GHCR_USER}"
GHCR_PULL_TOKEN="${GHCR_PULL_TOKEN:?set GHCR_PULL_TOKEN (read:packages)}"

# App runtime config written into the droplet .env.
DATA_DIR="${DATA_DIR:-/mnt/drome-data}"
DROME_DOMAIN="${DROME_DOMAIN:-drome.day}"
ACME_EMAIL="${ACME_EMAIL:?set ACME_EMAIL for Caddy/ACME}"
BETA_ALL_ENTITLED="${BETA_ALL_ENTITLED:-true}"
# Email OTP sign-in (optional). Empty key → the server logs codes instead of
# emailing (email sign-in inert until set). RESEND_FROM must be a verified
# sender on the Resend account.
RESEND_API_KEY="${RESEND_API_KEY:-}"
RESEND_FROM="${RESEND_FROM:-Drome <login@drome.day>}"
LITESTREAM_R2_ENDPOINT="${LITESTREAM_R2_ENDPOINT:?set LITESTREAM_R2_ENDPOINT}"
LITESTREAM_R2_BUCKET="${LITESTREAM_R2_BUCKET:?set LITESTREAM_R2_BUCKET}"
LITESTREAM_R2_ACCESS_KEY_ID="${LITESTREAM_R2_ACCESS_KEY_ID:?set LITESTREAM_R2_ACCESS_KEY_ID}"
LITESTREAM_R2_SECRET_ACCESS_KEY="${LITESTREAM_R2_SECRET_ACCESS_KEY:?set LITESTREAM_R2_SECRET_ACCESS_KEY}"

REMOTE_DIR="${REMOTE_DIR:-/home/${DEPLOY_USER}/drome}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://${DROME_DOMAIN}/healthz}"
SSH_OPTS="${SSH_OPTS:-}"

MODE="normal" # normal | fresh | restore
while [ "$#" -gt 0 ]; do
	case "$1" in
	--fresh) MODE="fresh" ;;
	--restore) MODE="restore" ;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 64
		;;
	esac
	shift
done

# The tag must be a 40-hex git SHA (ghcr.io/<owner>/drome-server:<sha>).
# Refuse anything else (:latest, a branch, a short SHA, or an extra env line)
# before ssh writes the remote .env.
if [[ ! "$IMAGE_TAG" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*:[0-9a-fA-F]{40}$ ]]; then
	printf 'refusing to deploy: IMAGE_TAG must be an image ref pinned to a 40-hex git SHA\n' >&2
	exit 65
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2086 # SSH_OPTS is an intentional word-split option list.
ssh_cmd() { ssh $SSH_OPTS "${DEPLOY_USER}@${DEPLOY_HOST}" "$@"; }

echo "==> Deploying ${IMAGE_TAG}"
echo "    host=${DEPLOY_USER}@${DEPLOY_HOST} remote_dir=${REMOTE_DIR} mode=${MODE}"

# --------------------------------------------------------------------------
# 1. Sync the compose stack (compose.yml, Caddyfile, litestream.yml).
# --------------------------------------------------------------------------
ssh_cmd "mkdir -p '${REMOTE_DIR}'"
# shellcheck disable=SC2086
rsync -az --delete \
	--exclude '.env' --exclude '.env.template' --exclude 'deploy.sh' --exclude '*.md' \
	--exclude 'accept-deploy-inputs.js' \
	-e "ssh ${SSH_OPTS}" \
	"${SCRIPT_DIR}/" "${DEPLOY_USER}@${DEPLOY_HOST}:${REMOTE_DIR}/"

# --------------------------------------------------------------------------
# 2. Write .env on the droplet (0600). Secrets never hit argv/logs — piped
#    over stdin.
# --------------------------------------------------------------------------
render_env() {
	cat <<-ENV
		IMAGE_TAG=${IMAGE_TAG}
		BETA_ALL_ENTITLED=${BETA_ALL_ENTITLED}
		RESEND_API_KEY=${RESEND_API_KEY}
		RESEND_FROM=${RESEND_FROM}
		DATA_DIR=${DATA_DIR}
		DROME_DOMAIN=${DROME_DOMAIN}
		ACME_EMAIL=${ACME_EMAIL}
		LITESTREAM_R2_ENDPOINT=${LITESTREAM_R2_ENDPOINT}
		LITESTREAM_R2_BUCKET=${LITESTREAM_R2_BUCKET}
		LITESTREAM_R2_ACCESS_KEY_ID=${LITESTREAM_R2_ACCESS_KEY_ID}
		LITESTREAM_R2_SECRET_ACCESS_KEY=${LITESTREAM_R2_SECRET_ACCESS_KEY}
	ENV
}
render_env | ssh_cmd "umask 077 && cat > '${REMOTE_DIR}/.env'"

# --------------------------------------------------------------------------
# 3. Remote: GHCR login, restore-before-up guard, pull + up.
#    Done in two SSH calls so the GHCR token can arrive on stdin (a single call
#    can't take BOTH a heredoc script AND a piped secret — the redirect wins):
#      3a. write the runner to the droplet via a heredoc (no secret in it);
#      3b. invoke it with the token piped on stdin, non-secret config via env.
# --------------------------------------------------------------------------
ssh_cmd "cat > '${REMOTE_DIR}/.remote-deploy.sh' && chmod 700 '${REMOTE_DIR}/.remote-deploy.sh'" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail
cd "$REMOTE_DIR"

GHCR_PULL_TOKEN="$(cat)"          # the read-only pull token, piped on stdin
HOST_DB="$DATA_DIR/drome/drome-server.sqlite"
CONTAINER_DB="/data/drome/drome-server.sqlite"

echo "$GHCR_PULL_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

if [ -s "$HOST_DB" ]; then
	echo "[guard] existing DB found ($HOST_DB) — normal deploy."
elif [ "$MODE" = "fresh" ]; then
	echo "[guard] --fresh: accepting a brand-new empty DB (intentional first boot)."
elif [ "$MODE" = "restore" ]; then
	echo "[guard] --restore: restoring DB from Litestream R2 BEFORE starting the server..."
	docker compose pull litestream
	# --no-deps so drome-server does NOT start and create an empty DB first.
	docker compose run --rm --no-deps litestream restore -config /etc/litestream.yml "$CONTAINER_DB"
	if [ ! -s "$HOST_DB" ]; then
		echo "[guard] restore produced no DB at $HOST_DB — aborting." >&2
		exit 1
	fi
	echo "[guard] restore complete."
else
	echo "[guard] REFUSING to 'up -d': data dir is EMPTY and neither --restore nor --fresh was given." >&2
	echo "        A blank SQLite would start a NEW Litestream generation over the good replica." >&2
	echo "        Re-run deploy.sh with --restore (recover from R2) or --fresh (accept a new empty DB)." >&2
	exit 2
fi

docker compose pull
docker compose up -d --remove-orphans
docker image prune -f >/dev/null 2>&1 || true
REMOTE

echo "$GHCR_PULL_TOKEN" | ssh_cmd \
	"REMOTE_DIR='${REMOTE_DIR}' DATA_DIR='${DATA_DIR}' GHCR_USER='${GHCR_USER}' MODE='${MODE}' bash '${REMOTE_DIR}/.remote-deploy.sh'"

# --------------------------------------------------------------------------
# 4. Health gate — verify THIS droplet's new container, NOT public DNS.
#    Curling https://${DROME_DOMAIN} would couple deploy success to the
#    nameserver flip / ACME / DNS TTLs: before the Porkbun cutover the domain
#    still resolves to the OLD parked droplet, so a public curl could false-PASS
#    against the wrong box or false-FAIL a healthy new one, and first-boot ACME on
#    an HSTS-preloaded .day is on the critical path. Exec curl INSIDE the running
#    container over the existing SSH channel — that can only pass on the server we
#    just deployed. (A crash-looping server has no running container to exec into,
#    so the gate correctly never greens.)
# --------------------------------------------------------------------------
echo "==> Waiting for the drome-server container on ${DEPLOY_HOST} to report healthy..."
attempts=0
max_attempts=18 # ~3 min, generous for first-boot startup + migrations
health_cmd="cd '${REMOTE_DIR}' && docker compose exec -T drome-server curl -fsS --max-time 10 http://127.0.0.1:8080/healthz"
until ssh_cmd "$health_cmd" >/dev/null 2>&1; do
	attempts=$((attempts + 1))
	if [ "$attempts" -ge "$max_attempts" ]; then
		echo "DEPLOY FAILED: the drome-server container did not report healthy after ${max_attempts} attempts." >&2
		echo "Recent server logs:" >&2
		ssh_cmd "cd '${REMOTE_DIR}' && docker compose logs --tail 80 drome-server caddy" >&2 || true
		exit 1
	fi
	sleep 10
done
echo "==> Container healthy — ${IMAGE_TAG} is live on ${DEPLOY_HOST}."

# --------------------------------------------------------------------------
# 5. Best-effort PUBLIC smoke test (NON-fatal). Once DNS/ACME have settled this
#    confirms the full public path; a first-boot lag (NS flip pending, cert still
#    issuing) must NOT fail an otherwise-good deploy, so this only warns.
# --------------------------------------------------------------------------
if curl -fsS --max-time 10 "$HEALTHCHECK_URL" >/dev/null 2>&1; then
	echo "==> Public smoke test OK — ${HEALTHCHECK_URL} is serving."
else
	echo "note: public ${HEALTHCHECK_URL} is not green yet (DNS/ACME may still be settling); the deployed container itself is healthy." >&2
fi
