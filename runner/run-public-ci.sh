#!/usr/bin/env bash
set -Eeuo pipefail

readonly WORKSPACE="${RUNNER_TEMP:?}/sandy-private"
readonly MODE="${1:-}"
if [[ "$MODE" == fetch ]]; then exec 3>&1; fi
readonly REQUEST_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
readonly SAFE_PATH='/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'
export PATH="$SAFE_PATH"
unset BASH_ENV ENV CDPATH GLOBIGNORE || true
mkdir -p "$WORKSPACE" >/dev/null 2>&1
chmod 700 "$WORKSPACE" >/dev/null 2>&1
status=1
stage=0
finish() {
  local code=$?
  if [[ "$status" == 0 && "$code" == 0 ]]; then
    if [[ "$MODE" == fetch ]]; then
      echo 'Sandy private validation: succeeded' >&3
    else
      echo 'Sandy private validation: succeeded'
    fi
  else
    # Fixed codes identify the failing operation without exposing private
    # paths, repository metadata, command output, or credentials.
    if [[ "$MODE" == fetch ]]; then
      echo "Sandy private validation: failed (stage $stage)" >&3
    else
      echo 'Sandy private validation: failed'
    fi
    exit 1
  fi
}
trap finish EXIT
fail() { return 1; }

# Reject diagnostic mode before evaluating any private checkout path.
[[ "${ACTIONS_STEP_DEBUG:-false}" != true && "${RUNNER_DEBUG:-0}" != 1 ]] || exit 1
[[ "${GITHUB_RUN_ATTEMPT:-1}" == 1 ]] || exit 1

private_exec() {
  local entrypoint="$WORKSPACE/trusted/private_lane.py"
  [[ -f "$entrypoint" ]] || fail
  /usr/bin/env -i \
    PATH="$SAFE_PATH" \
    HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
    DEVELOPER_DIR="${DEVELOPER_DIR:-}" RUNNER_TEMP="$RUNNER_TEMP" \
    SANDY_SOURCE_ROOT="$WORKSPACE/source" SANDY_PRIVATE_ROOT="$WORKSPACE" \
    SANDY_TEST_ARTIFACTS="$WORKSPACE/results" SANDY_TEST_DERIVED_DATA="$WORKSPACE/derived" \
    PREPARE_RESULT="${PREPARE_RESULT:-}" LANE_A_RESULT="${LANE_A_RESULT:-}" \
    LANE_B_RESULT="${LANE_B_RESULT:-}" LANE_C_RESULT="${LANE_C_RESULT:-}" \
    PUBLIC_RUN_ID="${PUBLIC_RUN_ID:-}" \
    python3 "$entrypoint" "$@"
}

recipient_certificate() {
  local output="$WORKSPACE/recipient.pem"
  [[ -n "${SANDY_CI_RECIPIENT_CERT:-}" ]] || fail
  printf '%s\n' "$SANDY_CI_RECIPIENT_CERT" > "$output"
  chmod 600 "$output"
  openssl x509 -in "$output" -noout >/dev/null 2>&1 || fail
  printf '%s' "$output"
}

encrypt_cms() {
  local input="$1" output="$2" certificate
  certificate="$(recipient_certificate)"
  openssl cms -encrypt -aes-256-gcm -binary -outform DER \
    -in "$input" -out "$output" "$certificate" >/dev/null 2>&1 || fail
  [[ -s "$output" ]] || fail
}

safe_result_id() {
  local value="${SANDY_RESULT_ID:-}"
  [[ "$value" =~ ^(a|b-[123]|c-[12])$ ]] || fail
  printf '%s' "$value"
}

write_products_manifest() {
  python3 - "$WORKSPACE/products" "$WORKSPACE/products-evidence/products-manifest.json" <<'PY'
import hashlib, json
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
if not root.is_dir():
    raise SystemExit(1)
files = [
    {"path": p.relative_to(root).as_posix(), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
    for p in sorted(root.rglob("*")) if p.is_file()
]
manifest = {
    "file_count": len(files),
    "sha256": hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
}
output.write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
PY
}

{
  request_id="${SANDY_REQUEST_ID:-}"
  request_run_id="${SANDY_REQUEST_RUN_ID:-}"
  [[ "$request_id" =~ $REQUEST_RE ]] || fail
  [[ "$MODE" =~ ^(fetch|prepare|run-lane|encrypt-prepare|encrypt-result)$ ]] || fail
  [[ "${GITHUB_RUN_ATTEMPT:-1}" == 1 ]] || fail
  [[ "${ACTIONS_STEP_DEBUG:-false}" != true && "${RUNNER_DEBUG:-0}" != 1 ]] || fail

  if [[ "$MODE" == fetch ]]; then
    [[ -n "${SANDY_SOURCE_TOKEN:-}" ]] || fail
    command -v gh >/dev/null 2>&1 || fail
    stage=1
    private_repository="$(GH_TOKEN="$SANDY_SOURCE_TOKEN" gh api repositories/1217636338 --jq .full_name 2>/dev/null)"
    [[ "$private_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail
    stage=2
    rm -rf "$WORKSPACE/request-artifact"
    GH_TOKEN="$SANDY_SOURCE_TOKEN" gh run download "$request_run_id" --repo "$private_repository" --name "sandy-private-request-$request_id" --dir "$WORKSPACE/request-artifact" >/dev/null 2>&1
    cp "$WORKSPACE/request-artifact/request.json" "$WORKSPACE/request.json"
    stage=3
    python3 - "$WORKSPACE/request.json" "$request_id" "${GITHUB_SHA:-}" <<'PY'
import json, re, sys, time
d = json.load(open(sys.argv[1], encoding="utf-8"))
if d.get("request_id") != sys.argv[2] or d.get("repository_id") != 1217636338: raise SystemExit(1)
for key in ("head_sha", "base_sha", "public_workflow_sha"):
    if not re.fullmatch(r"[0-9a-f]{40}", d.get(key, "")): raise SystemExit(1)
if d["public_workflow_sha"] != sys.argv[3]: raise SystemExit("unapproved public workflow SHA")
now = int(time.time())
created_at, expires_at = d.get("created_at"), d.get("expires_at")
if not isinstance(created_at, int) or not isinstance(expires_at, int): raise SystemExit("request timestamps are invalid")
if created_at > now + 300 or expires_at <= now or expires_at <= created_at or expires_at - created_at > 86400: raise SystemExit("request is expired or has an invalid lifetime")
if not isinstance(d.get("expected_jobs"), list) or not d["expected_jobs"]: raise SystemExit(1)
PY
    head_sha="$(python3 -c 'import json; print(json.load(open("'"$WORKSPACE"'/request.json"))["head_sha"])')"
    base_sha="$(python3 -c 'import json; print(json.load(open("'"$WORKSPACE"'/request.json"))["base_sha"])')"
    merge_date="$(python3 -c 'import datetime,json; d=json.load(open("'"$WORKSPACE"'/request.json")); print(datetime.datetime.fromtimestamp(d["created_at"],datetime.timezone.utc).isoformat())')"
    stage=4
    git clone --no-checkout --filter=blob:none "https://x-access-token:${SANDY_SOURCE_TOKEN}@github.com/$private_repository.git" "$WORKSPACE/source" >/dev/null 2>&1
    stage=5
    git -C "$WORKSPACE/source" fetch --quiet --no-tags origin "$head_sha" "$base_sha"
    stage=6
    git -C "$WORKSPACE/source" checkout --quiet --detach "$base_sha"
    stage=7
    trusted_paths="$(git -C "$WORKSPACE/source" ls-tree -r --name-only "$base_sha" | awk '/private_lane\.py$/ {print}')"
    [[ "$(printf '%s\n' "$trusted_paths" | sed '/^$/d' | wc -l | tr -d ' ')" == 1 ]] || fail
    mkdir -p "$WORKSPACE/trusted"
    trusted_path="$(printf '%s\n' "$trusted_paths" | sed -n '1p')"
    git -C "$WORKSPACE/source" show "$base_sha:$trusted_path" > "$WORKSPACE/trusted/private_lane.py"
    stage=8
    GIT_AUTHOR_DATE="$merge_date" GIT_COMMITTER_DATE="$merge_date" git -C "$WORKSPACE/source" -c user.name='Sandy CI' -c user.email='ci@namiai.com' merge --no-ff --no-edit "$head_sha" >/dev/null 2>&1 || fail
    stage=9
    git -C "$WORKSPACE/source" remote set-url origin "https://github.com/$private_repository.git"
    [[ "$(git -C "$WORKSPACE/source" remote get-url origin)" == "https://github.com/$private_repository.git" ]] || fail
    python3 - "$WORKSPACE/source" "$WORKSPACE/candidate.json" "$head_sha" "$base_sha" <<'PY'
import json, subprocess, sys
source, output, head_sha, base_sha = sys.argv[1:]
tree_sha = subprocess.check_output(["git", "-C", source, "rev-parse", "HEAD^{tree}"], text=True).strip()
json.dump({"head_sha": head_sha, "base_sha": base_sha, "candidate_tree_sha": tree_sha}, open(output, "w", encoding="utf-8"), sort_keys=True)
PY
    status=0
    exit 0
  fi

  mkdir -p "$WORKSPACE/results" "$WORKSPACE/products"
  case "$MODE" in
    prepare)
      private_exec prepare
      [[ -d "$WORKSPACE/products" ]] || fail
      ;;
    run-lane)
      [[ -n "${SANDY_OPAQUE_LANE:-}" ]] || fail
      # Lane B used to consume products from the prepare runner. Rebuild locally
      # so no products need to cross runner boundaries.
      if [[ "$SANDY_OPAQUE_LANE" =~ ^b-[123]$ ]]; then
        private_exec prepare
      fi
      private_exec run --lane "$SANDY_OPAQUE_LANE"
      ;;
    encrypt-prepare)
      mkdir -p "$WORKSPACE/products-evidence"
      [[ -f "$WORKSPACE/private.log" && -f "$WORKSPACE/candidate.json" ]] || fail
      cp "$WORKSPACE/private.log" "$WORKSPACE/products-evidence/private.log"
      cp "$WORKSPACE/candidate.json" "$WORKSPACE/products-evidence/candidate.json"
      write_products_manifest
      tar -czf "$WORKSPACE/prepare.bundle.tar.gz" -C "$WORKSPACE" products-evidence >/dev/null 2>&1
      encrypt_cms "$WORKSPACE/prepare.bundle.tar.gz" "$WORKSPACE/prepare.bundle.cms"
      ;;
    encrypt-result)
      [[ -f "$WORKSPACE/private.log" && -f "$WORKSPACE/candidate.json" ]] || fail
      [[ -d "$WORKSPACE/results" ]] || fail
      mkdir -p "$WORKSPACE/results"
      cp "$WORKSPACE/private.log" "$WORKSPACE/results/private.log"
      cp "$WORKSPACE/candidate.json" "$WORKSPACE/results/candidate.json"
      result_id="$(safe_result_id)"
      tar -czf "$WORKSPACE/result-$result_id.bundle.tar.gz" -C "$WORKSPACE" results >/dev/null 2>&1
      encrypt_cms "$WORKSPACE/result-$result_id.bundle.tar.gz" "$WORKSPACE/result-$result_id.bundle.cms"
      ;;
  esac
  status=0
} >>"$WORKSPACE/private.log" 2>&1
