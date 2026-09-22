#!/usr/bin/env bash
set -Eeuo pipefail

readonly WORKSPACE="${RUNNER_TEMP:?}/sandy-private"
readonly MODE="${1:-}"
readonly REQUEST_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
readonly SAFE_PATH='/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'
export PATH="$SAFE_PATH"
unset BASH_ENV ENV CDPATH GLOBIGNORE || true
mkdir -p "$WORKSPACE"; chmod 700 "$WORKSPACE"; status=1
finish() { local code=$?; if [[ "$status" == 0 && "$code" == 0 ]]; then echo 'Sandy private validation: succeeded'; else echo 'Sandy private validation: failed'; exit 1; fi; }
trap finish EXIT
fail() { return 1; }
# Reject diagnostics before any private checkout path is even evaluated.
[[ "${ACTIONS_STEP_DEBUG:-false}" != true && "${RUNNER_DEBUG:-0}" != 1 ]] || exit 1
[[ "${GITHUB_RUN_ATTEMPT:-1}" == 1 ]] || exit 1

payload_hmac() {
  local input="$1" output="$2"
  SANDY_PAYLOAD_KEY="$SANDY_PAYLOAD_KEY" python3 - "$input" "$output" <<'PY'
import hashlib, hmac, os
from pathlib import Path
import sys
key = os.environ["SANDY_PAYLOAD_KEY"].encode()
Path(sys.argv[2]).write_text(hmac.new(key, Path(sys.argv[1]).read_bytes(), hashlib.sha256).hexdigest() + "\n", encoding="ascii")
PY
}
derive_key() {
  local domain="$1"
  SANDY_PAYLOAD_KEY="$SANDY_PAYLOAD_KEY" python3 - "$domain" <<'PY'
import hashlib
import hmac
import os
import sys

master = os.environ["SANDY_PAYLOAD_KEY"].encode()
domain = ("sandy-public-ci/" + sys.argv[1]).encode()
print(hmac.new(master, domain, hashlib.sha256).hexdigest())
PY
}
verify_payload_hmac() {
  local input="$1" hmac_path="$2"
  SANDY_PAYLOAD_KEY="$SANDY_PAYLOAD_KEY" python3 - "$input" "$hmac_path" <<'PY'
import hashlib, hmac, os
from pathlib import Path
import sys
key = os.environ["SANDY_PAYLOAD_KEY"].encode()
actual = hmac.new(key, Path(sys.argv[1]).read_bytes(), hashlib.sha256).hexdigest()
expected = Path(sys.argv[2]).read_text(encoding="ascii").strip()
if not hmac.compare_digest(actual, expected): raise SystemExit("payload authentication failed")
PY
}
encrypt_payload() {
  local encryption_key mac_key
  encryption_key="$(derive_key encryption)"
  mac_key="$(derive_key hmac)"
  SANDY_ENCRYPTION_KEY="$encryption_key" openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -in "$1" -out "$2" -pass env:SANDY_ENCRYPTION_KEY >/dev/null 2>&1
  SANDY_PAYLOAD_KEY="$mac_key" payload_hmac "$2" "$2.hmac"
}
decrypt_payload() {
  local encryption_key mac_key
  encryption_key="$(derive_key encryption)"
  mac_key="$(derive_key hmac)"
  SANDY_PAYLOAD_KEY="$mac_key" verify_payload_hmac "$1" "$1.hmac"
  SANDY_ENCRYPTION_KEY="$encryption_key" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "$1" -out "$2" -pass env:SANDY_ENCRYPTION_KEY >/dev/null 2>&1
}
safe_result_id() { local value="${SANDY_RESULT_ID:-result}"; value="${value//[^A-Za-z0-9_.-]/-}"; [[ -n "$value" ]] || fail; printf '%s' "$value"; }
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
safe_extract() {
  local archive="$1" destination="$2"
  python3 - "$archive" "$destination" <<'PY'
from pathlib import Path, PurePosixPath
import shutil, sys, tarfile

archive, root = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
root.mkdir(parents=True, exist_ok=True)
seen = set()
with tarfile.open(archive, "r:*") as bundle:
    for member in bundle.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in path.parts):
            raise SystemExit("unsafe archive path")
        relative = path.as_posix()
        if relative in seen or member.issym() or member.islnk() or not (member.isdir() or member.isreg()):
            raise SystemExit("unsupported archive member")
        seen.add(relative)
        output = root.joinpath(*path.parts)
        if root not in output.parents and output != root:
            raise SystemExit("archive path escaped destination")
        if output.exists() or output.is_symlink():
            raise SystemExit("archive path collision")
        if member.isdir():
            output.mkdir(parents=True)
            continue
        output.parent.mkdir(parents=True, exist_ok=True)
        source = bundle.extractfile(member)
        if source is None:
            raise SystemExit("archive member is unreadable")
        with source, output.open("xb") as target:
            shutil.copyfileobj(source, target)
PY
}

{
  request_id="${SANDY_REQUEST_ID:-}"; request_run_id="${SANDY_REQUEST_RUN_ID:-}"
  [[ "$request_id" =~ $REQUEST_RE ]] || fail
  [[ "$MODE" =~ ^(fetch|prepare|encrypt-products|decrypt-products|decrypt-final-inputs|run-lane|encrypt-result|finalize|encrypt-final)$ ]] || fail
  [[ "${GITHUB_RUN_ATTEMPT:-1}" == 1 ]] || fail
  # Never let a debug or rerun execution reach the private checkout.
  [[ "${ACTIONS_STEP_DEBUG:-false}" != true ]] || fail
  [[ "${RUNNER_DEBUG:-0}" != 1 ]] || fail
  if [[ "$MODE" == fetch || "$MODE" == fetch-request ]]; then
    [[ -n "${SANDY_SOURCE_TOKEN:-}" ]] || fail; command -v gh >/dev/null || fail
    private_repository="$(GH_TOKEN="$SANDY_SOURCE_TOKEN" gh api repositories/1217636338 --jq .full_name 2>/dev/null)"
    [[ "$private_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail
    rm -rf "$WORKSPACE/request-artifact"
    GH_TOKEN="$SANDY_SOURCE_TOKEN" gh run download "$request_run_id" --repo "$private_repository" --name "sandy-private-request-$request_id" --dir "$WORKSPACE/request-artifact" >/dev/null 2>&1
    cp "$WORKSPACE/request-artifact/request.json" "$WORKSPACE/request.json"
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
    if [[ "$MODE" == fetch ]]; then
      head_sha=$(python3 -c 'import json; print(json.load(open("'"$WORKSPACE"'/request.json"))["head_sha"])')
      base_sha=$(python3 -c 'import json; print(json.load(open("'"$WORKSPACE"'/request.json"))["base_sha"])')
      merge_date=$(python3 -c 'import datetime,json; d=json.load(open("'"$WORKSPACE"'/request.json")); print(datetime.datetime.fromtimestamp(d["created_at"],datetime.timezone.utc).isoformat())')
      git clone --no-checkout --filter=blob:none "https://x-access-token:${SANDY_SOURCE_TOKEN}@github.com/$private_repository.git" "$WORKSPACE/source" >/dev/null 2>&1
      git -C "$WORKSPACE/source" fetch --quiet --no-tags origin "$head_sha" "$base_sha"
      git -C "$WORKSPACE/source" checkout --quiet --detach "$base_sha"
      trusted_paths="$(git -C "$WORKSPACE/source" ls-tree -r --name-only "$base_sha" | awk '/private_lane\.py$/ {print}')"
      [[ "$(printf '%s\n' "$trusted_paths" | sed '/^$/d' | wc -l | tr -d ' ')" == 1 ]] || fail
      mkdir -p "$WORKSPACE/trusted"
      trusted_path="$(printf '%s\n' "$trusted_paths" | sed -n '1p')"
      git -C "$WORKSPACE/source" show "$base_sha:$trusted_path" > "$WORKSPACE/trusted/private_lane.py"
      GIT_AUTHOR_DATE="$merge_date" GIT_COMMITTER_DATE="$merge_date" git -C "$WORKSPACE/source" -c user.name='Sandy CI' -c user.email='ci@namiai.com' merge --no-ff --no-edit "$head_sha" >/dev/null 2>&1 || fail
      # Authentication is kept only while Git materializes the merge candidate.
      # No PR-controlled process runs before the remote is scrubbed.
      git -C "$WORKSPACE/source" remote set-url origin "https://github.com/$private_repository.git"
      [[ "$(git -C "$WORKSPACE/source" remote get-url origin)" == "https://github.com/$private_repository.git" ]] || fail
      python3 - "$WORKSPACE/source" "$WORKSPACE/candidate.json" "$head_sha" "$base_sha" <<'PY'
import json, subprocess, sys
source, output, head_sha, base_sha = sys.argv[1:]
tree_sha = subprocess.check_output(["git", "-C", source, "rev-parse", "HEAD^{tree}"], text=True).strip()
json.dump({"head_sha": head_sha, "base_sha": base_sha, "candidate_tree_sha": tree_sha}, open(output, "w", encoding="utf-8"), sort_keys=True)
PY
    else status=0; exit 0; fi
  fi
  mkdir -p "$WORKSPACE/results" "$WORKSPACE/products"
  case "$MODE" in
    prepare)
      private_exec prepare >"$WORKSPACE/private.log" 2>&1; test -d "$WORKSPACE/products" || fail ;;
    encrypt-products)
      [[ -n "${SANDY_PAYLOAD_KEY:-}" ]] || fail; mkdir -p "$WORKSPACE/products-evidence"; [[ ! -f "$WORKSPACE/private.log" ]] || cp "$WORKSPACE/private.log" "$WORKSPACE/products-evidence/private.log"; cp "$WORKSPACE/candidate.json" "$WORKSPACE/products-evidence/candidate.json"; tar -czf "$WORKSPACE/products.tar.gz" -C "$WORKSPACE" products products-evidence >/dev/null 2>&1; encrypt_payload "$WORKSPACE/products.tar.gz" "$WORKSPACE/products.enc" ;;
    decrypt-products)
      [[ -n "${SANDY_PAYLOAD_KEY:-}" ]] || fail; decrypt_payload "$WORKSPACE/products.enc" "$WORKSPACE/products.tar.gz"; rm -rf "$WORKSPACE/products" "$WORKSPACE/products-evidence"; safe_extract "$WORKSPACE/products.tar.gz" "$WORKSPACE" ;;
    decrypt-final-inputs)
      [[ -n "${SANDY_PAYLOAD_KEY:-}" ]] || fail
      mkdir -p "$WORKSPACE/evidence/prepare" "$WORKSPACE/evidence/results"
      product_path=$(find "$WORKSPACE/final-inputs/payload" -type f -name 'products.enc' -print -quit)
      [[ -n "$product_path" ]] || fail
      product_stage="$WORKSPACE/products-final"
      mkdir -p "$product_stage"
      decrypt_payload "$product_path" "$WORKSPACE/products-final.tar.gz"
      safe_extract "$WORKSPACE/products-final.tar.gz" "$product_stage"
      mkdir -p "$WORKSPACE/evidence/prepare/products-evidence"
      cp "$product_stage/products-evidence/private.log" "$WORKSPACE/evidence/prepare/products-evidence/private.log"
      cp "$product_stage/products-evidence/candidate.json" "$WORKSPACE/evidence/prepare/products-evidence/candidate.json"
      python3 - "$product_stage/products" "$WORKSPACE/evidence/prepare/products-evidence/products-manifest.json" <<'PY'
import hashlib, json
from pathlib import Path
import sys
root, output = Path(sys.argv[1]), Path(sys.argv[2])
files = [{"path": p.relative_to(root).as_posix(), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(root.rglob("*")) if p.is_file()]
output.write_text(json.dumps({"file_count": len(files), "sha256": hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()}, sort_keys=True) + "\n", encoding="utf-8")
PY
      expected_results=(result-a.enc result-b-1.enc result-b-2.enc result-b-3.enc result-c-1.enc result-c-2.enc)
      mapfile -t encrypted_results < <(find "$WORKSPACE/final-inputs/results" -type f -name 'result-*.enc' -print | sort)
      [[ "${#encrypted_results[@]}" == 6 ]] || fail
      for expected_result in "${expected_results[@]}"; do
        match_count=0
        for encrypted in "${encrypted_results[@]}"; do [[ "$(basename "$encrypted")" == "$expected_result" ]] && match_count=$((match_count + 1)); done
        [[ "$match_count" == 1 ]] || fail
      done
      for encrypted in "${encrypted_results[@]}"; do
        result_name="$(basename "$encrypted" .enc)"
        destination="$WORKSPACE/evidence/results/$result_name"
        mkdir -p "$destination"
        decrypt_payload "$encrypted" "$destination/result.tar.gz"
        safe_extract "$destination/result.tar.gz" "$destination"
        rm -f "$destination/result.tar.gz"
      done
      ;;
    run-lane)
      [[ -n "${SANDY_OPAQUE_LANE:-}" ]] || fail
      private_exec run --lane "$SANDY_OPAQUE_LANE" >"$WORKSPACE/private.log" 2>&1 ;;
    encrypt-result)
      [[ -n "${SANDY_PAYLOAD_KEY:-}" ]] || fail; [[ ! -f "$WORKSPACE/private.log" ]] || cp "$WORKSPACE/private.log" "$WORKSPACE/results/private.log"; cp "$WORKSPACE/candidate.json" "$WORKSPACE/results/candidate.json"; tar -czf "$WORKSPACE/result.tar.gz" -C "$WORKSPACE" results >/dev/null 2>&1; result_id=$(safe_result_id); encrypt_payload "$WORKSPACE/result.tar.gz" "$WORKSPACE/result-$result_id.enc" ;;
    finalize)
      private_exec finalize --request "$WORKSPACE/request.json" --result "$WORKSPACE/result.json" --manifest "$WORKSPACE/evidence_manifest.json" ;;
    encrypt-final)
      [[ -n "${SANDY_PAYLOAD_KEY:-}" ]] || fail; tar -czf "$WORKSPACE/result.bundle.tar.gz" -C "$WORKSPACE" result.json evidence_manifest.json evidence >/dev/null 2>&1; encrypt_payload "$WORKSPACE/result.bundle.tar.gz" "$WORKSPACE/result.bundle.enc"; mv "$WORKSPACE/result.bundle.enc.hmac" "$WORKSPACE/result.bundle.hmac" ;;
  esac
  status=0
} >>"$WORKSPACE/private.log" 2>&1
