#!/usr/bin/env bash
# test.sh — Smoke tests for bigin.sh (no API calls required)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIGIN="$SCRIPT_DIR/../scripts/bigin.sh"
PASS=0
FAIL=0

# Create temporary credentials file (tokens are invalid but structure is valid)
TMPDIR=$(mktemp -d)
trap "rm -rf \"$TMPDIR\"" EXIT

cat > "$TMPDIR/creds.json" << 'EOF'
{
  "client_id": "test",
  "client_secret": "test",
  "refresh_token": "test",
  "access_token": "test",
  "expires_at": 9999999999,
  "token_endpoint": "https://accounts.zoho.eu/oauth/v2/token",
  "api_base": "https://www.zohoapis.eu/bigin/v2"
}
EOF

export BIGIN_CREDS_FILE="$TMPDIR/creds.json"

ok() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== bigin.sh smoke tests ==="

# ── Test: Help output ─────────────────────────────────────────────
echo ""
echo "--- Help ---"
output=$(bash "$BIGIN" help 2>&1) || true
if echo "$output" | grep -q "Usage:"; then
  ok "help shows usage"
else
  fail "help should show usage"
fi

# help should work without credentials
output=$(BIGIN_CREDS_FILE=/nonexistent/path.json bash "$BIGIN" help 2>&1) || true
if echo "$output" | grep -q "Usage:"; then
  ok "help works without credentials"
else
  fail "help should not require credentials"
fi

# ── Test: Unknown command ─────────────────────────────────────────
echo ""
echo "--- Unknown command ---"
output=$(bash "$BIGIN" nonexistent 2>&1) || true
if echo "$output" | grep -q "UNKNOWN_COMMAND"; then
  ok "unknown command returns UNKNOWN_COMMAND error"
else
  fail "unknown command should return UNKNOWN_COMMAND"
fi

# ── Test: Write guardrails ────────────────────────────────────────
echo ""
echo "--- Write Guardrails ---"

# create without BIGIN_WRITE should fail
output=$(BIGIN_WRITE=0 bash "$BIGIN" create Contacts '{}' 2>&1) || true
if echo "$output" | grep -q "WRITE_BLOCKED"; then
  ok "create blocked without BIGIN_WRITE=1"
else
  fail "create should be blocked without BIGIN_WRITE=1"
fi

# delete without BIGIN_CONFIRM should fail
output=$(BIGIN_WRITE=1 BIGIN_CONFIRM=0 bash "$BIGIN" delete Contacts 12345 2>&1) || true
if echo "$output" | grep -q "CONFIRM_REQUIRED"; then
  ok "delete blocked without BIGIN_CONFIRM=1"
else
  fail "delete should be blocked without BIGIN_CONFIRM=1"
fi

# raw POST without BIGIN_WRITE should fail
output=$(BIGIN_WRITE=0 bash "$BIGIN" raw POST /test '{}' 2>&1) || true
if echo "$output" | grep -q "WRITE_BLOCKED"; then
  ok "raw POST blocked without BIGIN_WRITE=1"
else
  fail "raw POST should be blocked without BIGIN_WRITE=1"
fi

# raw DELETE without BIGIN_CONFIRM should fail
output=$(BIGIN_WRITE=1 BIGIN_CONFIRM=0 bash "$BIGIN" raw DELETE /test 2>&1) || true
if echo "$output" | grep -q "CONFIRM_REQUIRED"; then
  ok "raw DELETE blocked without BIGIN_CONFIRM=1"
else
  fail "raw DELETE should be blocked without BIGIN_CONFIRM=1"
fi

# ── Test: JSON validation ────────────────────────────────────────
echo ""
echo "--- JSON Validation ---"
output=$(BIGIN_WRITE=1 bash "$BIGIN" create Contacts 'not-json' 2>&1) || true
if echo "$output" | grep -q "INVALID_JSON"; then
  ok "invalid JSON rejected"
else
  fail "invalid JSON should be rejected"
fi

# Valid JSON should pass validation (will fail on API call, but not on validation)
output=$(BIGIN_WRITE=1 bash "$BIGIN" create Contacts '{"Last_Name":"Test"}' 2>&1) || true
if ! echo "$output" | grep -q "INVALID_JSON"; then
  ok "valid JSON accepted"
else
  fail "valid JSON should not be rejected"
fi

# ── Test: Structured error output ─────────────────────────────────
echo ""
echo "--- Error JSON structure ---"
output=$(BIGIN_WRITE=0 bash "$BIGIN" create Contacts '{}' 2>&1) || true
if echo "$output" | jq -e '.error_code' >/dev/null 2>&1; then
  ok "error output is valid JSON with error_code"
else
  fail "error output should be valid JSON"
fi

if echo "$output" | jq -e '.success == false' >/dev/null 2>&1; then
  ok "error output has success=false"
else
  fail "error output should have success=false"
fi

# ── Test: Missing credentials ────────────────────────────────────
echo ""
echo "--- Config ---"
output=$(BIGIN_CREDS_FILE=/nonexistent/path.json bash "$BIGIN" modules 2>&1) || true
if echo "$output" | grep -q "CONFIG_MISSING"; then
  ok "missing credentials detected"
else
  fail "missing credentials should be detected"
fi

cat > "$TMPDIR/invalid-creds.json" << 'EOF'
{
  "client_id": "test",
  "client_secret": "test",
  "access_token": "test",
  "expires_at": 9999999999,
  "token_endpoint": "https://accounts.zoho.eu/oauth/v2/token",
  "api_base": "https://www.zohoapis.eu/bigin/v2"
}
EOF
output=$(BIGIN_CREDS_FILE="$TMPDIR/invalid-creds.json" bash "$BIGIN" modules 2>&1) || true
if echo "$output" | grep -q "CONFIG_INVALID"; then
  ok "invalid credentials detected"
else
  fail "invalid credentials should be detected"
fi

# empty required fields should be invalid too
cat > "$TMPDIR/empty-creds.json" << 'EOF'
{
  "client_id": "",
  "client_secret": "",
  "refresh_token": "",
  "access_token": "",
  "expires_at": 9999999999,
  "token_endpoint": "https://accounts.zoho.eu/oauth/v2/token",
  "api_base": "https://www.zohoapis.eu/bigin/v2"
}
EOF
output=$(BIGIN_CREDS_FILE="$TMPDIR/empty-creds.json" bash "$BIGIN" modules 2>&1) || true
if echo "$output" | grep -q "CONFIG_INVALID"; then
  ok "empty required credentials detected"
else
  fail "empty required credentials should be detected"
fi

# ── Test: Special characters in error messages ────────────────────
echo ""
echo "--- JSON-safe errors ---"
output=$(BIGIN_WRITE=1 bash "$BIGIN" create Contacts '"bad"json"with"quotes' 2>&1) || true
if echo "$output" | jq -e . >/dev/null 2>&1; then
  ok "error with special chars produces valid JSON"
else
  fail "error with special chars should still be valid JSON"
fi

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
