#!/usr/bin/env bash
# Deploy a Drome server image to stephens.page (plan.md GitOps "App pipeline").
#
# Runs on the CI runner (or a laptop). It SSHes to drome-deploy@stephens.page,
# whose key is pinned to /usr/local/bin/drome-deploy (source: deploy/drome-deploy),
# and asks it to deploy one git SHA. The host script pulls the image, fetches
# deploy/web at that commit, runs the restore-before-up guard, switches
# IMAGE_TAG, waits for /healthz and rolls back on failure. See drome-deploy for
# the details; this script only passes the request and the GHCR pull token.
#
#   DEPLOY_SHA=<40-hex sha> GHCR_PULL_TOKEN=<token> ./deploy/deploy.sh [--fresh|--restore]
#
# GHCR_PULL_TOKEN may be empty when the image is already on the host (e.g. a
# rollback to an image deployed before). In CI it is the job's GITHUB_TOKEN.
#
# Rollback is not a mode: re-run with DEPLOY_SHA set to an earlier SHA. The
# server-deploy workflow exposes that as a workflow_dispatch input.
set -euo pipefail

DEPLOY_HOST="${DEPLOY_HOST:-stephens.page}"
DEPLOY_USER="${DEPLOY_USER:-drome-deploy}"
DEPLOY_SHA="${DEPLOY_SHA:?set DEPLOY_SHA to the 40-hex git SHA of the image to deploy}"
GHCR_PULL_TOKEN="${GHCR_PULL_TOKEN:-}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://drome.day/healthz}"
SSH_OPTS="${SSH_OPTS:-}"
DEPLOY_SHA="$(printf '%s' "$DEPLOY_SHA" | tr 'A-F' 'a-f')" # the host wants lowercase

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

# The host refuses anything else too; failing here gives a clearer CI error.
if [[ ! "$DEPLOY_SHA" =~ ^[0-9a-f]{40}$ ]]; then
	echo "refusing to deploy: DEPLOY_SHA must be a 40-hex lowercase git SHA" >&2
	exit 65
fi

echo "==> Deploying ${DEPLOY_SHA} to ${DEPLOY_USER}@${DEPLOY_HOST} (mode=${MODE})"
# The token goes over stdin, never argv. The forced command ignores anything
# but "deploy <sha> <mode>".
# shellcheck disable=SC2086 # SSH_OPTS is an intentional word-split option list.
printf '%s' "$GHCR_PULL_TOKEN" |
	ssh $SSH_OPTS "${DEPLOY_USER}@${DEPLOY_HOST}" "deploy ${DEPLOY_SHA} ${MODE}"

# Best-effort public smoke test (non-fatal): the host already verified
# /healthz on loopback before reporting success.
if curl -fsS --max-time 10 "$HEALTHCHECK_URL" >/dev/null 2>&1; then
	echo "==> Public smoke test OK: ${HEALTHCHECK_URL}"
else
	echo "note: public ${HEALTHCHECK_URL} is not green; the host reported the container healthy." >&2
fi
