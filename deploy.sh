#!/usr/bin/env bash
# Sets env vars on a Coolify resource, triggers a deployment and (optionally)
# waits for it. Inputs come from action.yml as INPUT_* environment variables.
# Requires bash, curl and jq (all preinstalled on GitHub-hosted runners).
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

# ── Inputs ──────────────────────────────────────────────────────────────────

url="${INPUT_URL:-}"
token="${INPUT_TOKEN:-}"
uuid="${INPUT_UUID:-}"
env_lines="${INPUT_ENV:-}"
wait="${INPUT_WAIT:-true}"
timeout="${INPUT_TIMEOUT:-600}"
poll_interval="${INPUT_POLL_INTERVAL:-10}"

[[ -n "$token" ]] || fail "Input 'token' is required"
echo "::add-mask::$token"

[[ "$url" =~ ^https?://[^/]+ ]] || fail "Input 'url' must include the scheme, e.g. https://coolify.example.com (got '$url')"
url="${url%/}"
[[ "$uuid" =~ ^[A-Za-z0-9_-]+$ ]] || fail "Input 'uuid' must be a Coolify resource UUID (got '$uuid')"
[[ "$wait" == "true" || "$wait" == "false" ]] || fail "Input 'wait' must be 'true' or 'false' (got '$wait')"
[[ "$timeout" =~ ^[0-9]+$ ]] || fail "Input 'timeout' must be a number of seconds (got '$timeout')"
[[ "$poll_interval" =~ ^[1-9][0-9]*$ ]] || fail "Input 'poll-interval' must be a positive number of seconds (got '$poll_interval')"

api="$url/api/v1"
response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

# api METHOD PATH [JSON_BODY] → prints the HTTP status; body lands in $response_file.
# Prints 000 on network errors instead of exiting, so callers decide.
api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(--silent --show-error --max-time 30 --output "$response_file" --write-out "%{http_code}"
    -X "$method" -H "Authorization: Bearer $token" -H "Accept: application/json")
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi
  local code
  code="$(curl "${args[@]}" "$api$path")" || code="000"
  echo "$code"
}

is_success() { [[ "$1" =~ ^2[0-9][0-9]$ ]]; }

# ── 1. Environment variables ────────────────────────────────────────────────

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -z "${line//[[:space:]]/}" ]] && continue
  [[ "$line" == *=* ]] || fail "Input 'env': expected KEY=value, got '$line'"
  key="${line%%=*}"
  value="${line#*=}"
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "Input 'env': invalid variable name '$key'"

  echo "Setting $key on $uuid"
  body="$(jq -cn --arg key "$key" --arg value "$value" '{key: $key, value: $value}')"
  status="$(api PATCH "/applications/$uuid/envs" "$body")"
  if ! is_success "$status"; then
    fail "Setting $key failed (HTTP $status): $(cat "$response_file"). The variable must already exist on the Coolify resource, and the token needs the 'write' permission."
  fi
done <<<"$env_lines"

# ── 2. Trigger the deployment ───────────────────────────────────────────────

status="$(api GET "/deploy?uuid=$uuid")"
is_success "$status" || fail "Triggering the deployment failed (HTTP $status): $(cat "$response_file")"

# Response shape: {"deployments":[{"message":…,"resource_uuid":…,"deployment_uuid":…}]}
deployment_uuid="$(jq -r '.deployments[0].deployment_uuid // empty' "$response_file" 2>/dev/null || true)"
[[ -n "$deployment_uuid" ]] || fail "Unexpected response from the deploy endpoint: $(cat "$response_file")"

jq -r '.deployments[0].message // "Deployment queued."' "$response_file"
echo "Deployment UUID: $deployment_uuid"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "deployment-uuid=$deployment_uuid" >>"$GITHUB_OUTPUT"
fi

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "Coolify deployment \`$deployment_uuid\`: **$1**" >>"$GITHUB_STEP_SUMMARY"
  fi
}

if [[ "$wait" == "false" ]]; then
  summary "triggered (not waited for)"
  exit 0
fi

# ── 3. Wait for the result ──────────────────────────────────────────────────

started="$(date +%s)"
while true; do
  elapsed=$(($(date +%s) - started))
  if ((elapsed >= timeout)); then
    summary "timed out after ${timeout}s"
    fail "Timed out after ${timeout}s waiting for deployment $deployment_uuid"
  fi
  sleep "$poll_interval"

  status="$(api GET "/deployments/$deployment_uuid")"
  if ! is_success "$status"; then
    # Transient errors shouldn't fail a deploy that may still succeed; the timeout bounds this.
    echo "::warning::Status check failed (HTTP $status), retrying: $(cat "$response_file")"
    continue
  fi

  # Statuses: queued, in_progress, finished, failed, cancelled-by-user
  deploy_status="$(jq -r '.status // "unknown"' "$response_file" 2>/dev/null || echo unknown)"
  echo "[$(($(date +%s) - started))s] Status: $deploy_status"

  case "$deploy_status" in
    finished)
      summary "finished"
      echo "Deployment finished."
      exit 0
      ;;
    failed | cancelled-by-user)
      summary "$deploy_status"
      fail "Deployment $deployment_uuid ended with status '$deploy_status'. See the deployment logs in Coolify."
      ;;
    queued | in_progress) ;;
    *) echo "::warning::Unknown deployment status '$deploy_status', still waiting" ;;
  esac
done
