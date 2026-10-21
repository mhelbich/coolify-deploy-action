#!/usr/bin/env bash
# Runs deploy.sh against test/mock-coolify.py for each scenario and checks the
# exit code, the output and the env PATCH bodies the mock received.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
port=18080
failures=0

# case NAME SCENARIO EXPECTED_EXIT EXPECTED_OUTPUT_REGEX [extra INPUT_*=… assignments]
run_case() {
  local name="$1" scenario="$2" expected_exit="$3" expected_output="$4"
  shift 4

  local dir
  dir="$(mktemp -d)"
  (cd "$dir" && exec python3 "$root/test/mock-coolify.py" "$port" "$scenario" 2>mock.log) &
  local mock_pid=$!
  for _ in $(seq 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/" && break
    sleep 0.1
  done

  local output exit_code=0
  output="$(cd "$dir" && env -i PATH="$PATH" \
    INPUT_URL="http://127.0.0.1:$port/" INPUT_TOKEN=test-token INPUT_UUID=app123 \
    INPUT_POLL_INTERVAL=1 GITHUB_OUTPUT="$dir/output" GITHUB_STEP_SUMMARY="$dir/summary" \
    "$@" bash "$root/deploy.sh" 2>&1)" || exit_code=$?

  kill "$mock_pid" 2>/dev/null || true
  wait "$mock_pid" 2>/dev/null || true

  local ok=true
  [[ "$exit_code" == "$expected_exit" ]] || ok=false
  grep -Eq "$expected_output" <<<"$output" || ok=false
  if [[ "$expected_exit" == 0 ]]; then
    grep -qx "deployment-uuid=dep456" "$dir/output" || ok=false
  fi
  if [[ -n "${EXPECT_PATCHES:-}" ]]; then
    [[ "$(cat "$dir/env-patches.jsonl" 2>/dev/null)" == "$EXPECT_PATCHES" ]] || ok=false
  fi

  if $ok; then
    echo "ok   $name"
  else
    echo "FAIL $name (exit $exit_code, expected $expected_exit)"
    while IFS= read -r l; do echo "     | $l"; done <<<"$output"
    failures=$((failures + 1))
  fi
  rm -rf "$dir"
}

run_case "success" success 0 "Deployment finished"
run_case "failed deployment" failed 1 "ended with status 'failed'"
run_case "cancelled deployment" cancelled 1 "ended with status 'cancelled-by-user'"
run_case "timeout" stuck 1 "Timed out after 3s" INPUT_TIMEOUT=3
run_case "wait=false skips polling" failed 0 "Deployment UUID: dep456" INPUT_WAIT=false
run_case "wrong token" success 1 "Triggering the deployment failed \(HTTP 401\)" INPUT_TOKEN=wrong
run_case "unknown resource" success 1 "HTTP 404" INPUT_UUID=nope
run_case "url without scheme" success 1 "must include the scheme" INPUT_URL=coolify.example.com
run_case "invalid env line" success 1 "expected KEY=value" INPUT_ENV="IMAGE_TAG"
run_case "missing env variable" missing-env 1 "Setting IMAGE_TAG failed \(HTTP 404\)" INPUT_ENV="IMAGE_TAG=v1.0.0"

EXPECT_PATCHES='{"key": "IMAGE_TAG", "value": "v1.0.0"}
{"key": "NOTE", "value": "a=b \"quoted\""}' \
  run_case "env vars are set, values kept verbatim" success 0 "Setting NOTE on app123" \
  INPUT_ENV=$'IMAGE_TAG=v1.0.0\r\n\nNOTE=a=b "quoted"\n'

if ((failures > 0)); then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
