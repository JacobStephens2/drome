#!/usr/bin/env bash
# Seam: deploy/deploy.sh refuses a DEPLOY_SHA that is not a 40-hex git SHA, and
# does so before ssh. When it does reach ssh, the remote command is exactly
# "deploy <lowercase sha> <mode>" and the GHCR token travels on stdin, never in
# argv. (The host's forced command, deploy/drome-deploy, re-checks all of it.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY="$ROOT/deploy/deploy.sh"
SHA="0123456789abcdef0123456789abcdef01234567"
TOKEN="pull-token-value"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# The ssh stub records its argv and stdin, then fails so curl never runs.
cat >"$tmpdir/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh\n' >>"$STUB_LOG"
printf '%s\n' "$@" >"$STUB_ARGS"
cat >"$STUB_STDIN"
exit 99
EOF
cat >"$tmpdir/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl\n' >>"$STUB_LOG"
exit 99
EOF
chmod +x "$tmpdir/ssh" "$tmpdir/curl"

export PATH="$tmpdir:$PATH"
export STUB_LOG="$tmpdir/log" STUB_ARGS="$tmpdir/args" STUB_STDIN="$tmpdir/stdin"
export DEPLOY_HOST="203.0.113.10"
export GHCR_PULL_TOKEN="$TOKEN"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

# Run deploy.sh with DEPLOY_SHA=$1. Extra args are passed through.
run() {
	local sha="$1"
	shift
	: >"$STUB_LOG"
	: >"$STUB_ARGS"
	: >"$STUB_STDIN"
	set +e
	DEPLOY_SHA="$sha" "$DEPLOY" "$@" >"$tmpdir/out" 2>"$tmpdir/err"
	code=$?
	set -e
}

assert_refused() {
	local label="$1"
	[ "$code" -eq 65 ] || fail "$label: exit $code, want 65. stderr=$(cat "$tmpdir/err")"
	[ ! -s "$STUB_LOG" ] || fail "$label: ssh/curl ran before refusal: $(cat "$STUB_LOG")"
	grep -q '40-hex' "$tmpdir/err" || fail "$label: stderr did not say 40-hex: $(cat "$tmpdir/err")"
}

assert_reached() {
	local label="$1" want_cmd="$2"
	[ "$code" -eq 99 ] || fail "$label: exit $code, want 99 (ssh reached). stderr=$(cat "$tmpdir/err")"
	[ "$(cat "$STUB_LOG")" = "ssh" ] || fail "$label: ssh was not the only stub call: $(cat "$STUB_LOG")"
	[ "$(tail -n 1 "$STUB_ARGS")" = "$want_cmd" ] ||
		fail "$label: remote command was '$(tail -n 1 "$STUB_ARGS")', want '$want_cmd'"
	grep -q "drome-deploy@203.0.113.10" "$STUB_ARGS" || fail "$label: wrong ssh target: $(cat "$STUB_ARGS")"
	grep -qF "$TOKEN" "$STUB_ARGS" && fail "$label: token leaked into ssh argv"
	[ "$(cat "$STUB_STDIN")" = "$TOKEN" ] || fail "$label: token did not arrive on stdin"
}

run "main"
assert_refused "branch name"

run "latest"
assert_refused "latest"

run "abcdef0"
assert_refused "short sha"

run "ghcr.io/jacobstephens2/drome-server:${SHA}"
assert_refused "full image ref"

run "$(printf '%s\nEVIL=1' "$SHA")"
assert_refused "newline injection"

run "${SHA};touch /tmp/pwned"
assert_refused "metacharacters after the sha"

run "${SHA} restore"
assert_refused "extra word after the sha"

run "$SHA"
assert_reached "pinned sha" "deploy $SHA normal"

run "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
assert_reached "uppercase sha" "deploy abcdef0123456789abcdef0123456789abcdef01 normal"

run "$SHA" --restore
assert_reached "restore mode" "deploy $SHA restore"

run "$SHA" --fresh
assert_reached "fresh mode" "deploy $SHA fresh"

run "$SHA" --bogus
[ "$code" -eq 64 ] || fail "unknown flag: exit $code, want 64"
[ ! -s "$STUB_LOG" ] || fail "unknown flag: ssh ran"

printf 'ok\n'
