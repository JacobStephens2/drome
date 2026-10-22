#!/usr/bin/env bash
# Seam: deploy/deploy.sh refuses an IMAGE_TAG that is not a ref pinned to a
# 40-hex git SHA, and it does so before ssh (the path that writes remote .env).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY="$ROOT/deploy/deploy.sh"
SHA="0123456789abcdef0123456789abcdef01234567"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh\n' >>"$STUB_LOG"
exit 99
EOF
cat >"$tmpdir/rsync" <<'EOF'
#!/usr/bin/env bash
printf 'rsync\n' >>"$STUB_LOG"
exit 99
EOF
cat >"$tmpdir/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl\n' >>"$STUB_LOG"
exit 99
EOF
chmod +x "$tmpdir/ssh" "$tmpdir/rsync" "$tmpdir/curl"

export PATH="$tmpdir:$PATH"
export STUB_LOG="$tmpdir/log"
export DEPLOY_HOST="203.0.113.10"
export GHCR_USER="deployer"
export GHCR_PULL_TOKEN="pull-token"
export ACME_EMAIL="acme@example.com"
export LITESTREAM_R2_ENDPOINT="https://example.test"
export LITESTREAM_R2_BUCKET="bucket"
export LITESTREAM_R2_ACCESS_KEY_ID="access"
export LITESTREAM_R2_SECRET_ACCESS_KEY="secret"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

# Run deploy.sh with IMAGE_TAG=$1. Extra args are passed through.
run() {
	local tag="$1"
	shift
	: >"$STUB_LOG"
	set +e
	IMAGE_TAG="$tag" "$DEPLOY" "$@" >"$tmpdir/out" 2>"$tmpdir/err"
	code=$?
	set -e
}

assert_refused() {
	local label="$1"
	[ "$code" -eq 65 ] || fail "$label: exit $code, want 65. stderr=$(cat "$tmpdir/err")"
	[ ! -s "$STUB_LOG" ] || fail "$label: ssh/rsync/curl ran before refusal: $(cat "$STUB_LOG")"
	grep -q '40-hex' "$tmpdir/err" || fail "$label: stderr did not say 40-hex: $(cat "$tmpdir/err")"
}

run "ghcr.io/jacobstephens2/drome-server:main"
assert_refused "branch tag"

run "ghcr.io/jacobstephens2/drome-server:latest"
assert_refused ":latest"

run "ghcr.io/jacobstephens2/drome-server:abcdef0"
assert_refused "short sha"

run "$SHA"
assert_refused "bare sha"

run "$(printf 'ghcr.io/jacobstephens2/drome-server:%s\nEVIL=1' "$SHA")"
assert_refused "newline injection"

run "ghcr.io/jacobstephens2/drome-server:${SHA};touch /tmp/pwned"
assert_refused "metacharacters after the sha"

run "ghcr.io/jacobstephens2/drome-server:${SHA}"
[ "$code" -eq 99 ] || fail "pinned ref: exit $code, want 99 (ssh reached). stderr=$(cat "$tmpdir/err")"
grep -qx 'ssh' "$STUB_LOG" || fail "pinned ref: ssh was not the only stub call: $(cat "$STUB_LOG")"
grep -q 'refusing to deploy' "$tmpdir/err" && fail "pinned ref: refused a 40-hex tag" || true

run "ghcr.io/jacobstephens2/drome-server:ABCDEF0123456789ABCDEF0123456789ABCDEF01"
[ "$code" -eq 99 ] || fail "uppercase sha: exit $code, want 99. stderr=$(cat "$tmpdir/err")"

printf 'ok\n'
