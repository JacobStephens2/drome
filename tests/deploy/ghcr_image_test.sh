#!/usr/bin/env bash
# Seam: the image server-deploy.yml pushes to GHCR.
#
# GHCR only lets this repo's GITHUB_TOKEN read and write a package that is
# linked to the repo. The link is the OCI source label
# org.opencontainers.image.source. ghcr.io/<owner>/drome-server is already a
# private package this token cannot read (server-deploy run 39736182790,
# permission_denied: read_package), so the published name is
# ghcr.io/<owner>/drome/drome-server, tagged with the git SHA and never
# :latest.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$ROOT/.github/workflows/server-deploy.yml"
DF="$ROOT/server/Dockerfile"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q 'packages: write' "$WF" || fail "workflow does not grant packages: write"

count=$(grep -c 'IMAGE=ghcr.io/${GITHUB_REPOSITORY_OWNER,,}/drome/drome-server' "$WF" || true)
[ "$count" -eq 2 ] || fail "expected the nested image name in both jobs, got ${count}"

if grep -q 'IMAGE=ghcr.io/${GITHUB_REPOSITORY_OWNER,,}/drome-server"' "$WF"; then
	fail "workflow still publishes the unlinked drome-server package"
fi

grep -q 'tags: ${{ env.IMAGE }}:${{ github.sha }}' "$WF" || fail "image is not tagged with the git SHA"

if grep -E 'tags:.*:latest' "$WF" >/dev/null; then
	fail "workflow tags :latest"
fi

grep -q 'org.opencontainers.image.source=https://github.com/${{ github.repository }}' "$WF" \
	|| fail "workflow does not set the OCI source label"

grep -q 'LABEL org.opencontainers.image.source=https://github.com/JacobStephens2/drome' "$DF" \
	|| fail "Dockerfile does not label the runtime image with this repo"

printf 'ok\n'
