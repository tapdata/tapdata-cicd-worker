#!/usr/bin/env bash
# Every deploy workflow variant must carry the serving-index leg (TAP-12057)
# (run: bash scripts/common/tests/test-deploy-variants-parity.sh)
#
# .github/deploy/ holds selection-library copies of the deploy workflow: docs tell a GHES
# operator to `cp` the artifact-v3 one over .github/workflows/tapdata-deploy.yml. P4-3 added
# the index leg to the live workflow only, so following that instruction silently dropped the
# entire leg -- pipeline still green, indexes just never created. Silent, because a missing
# leg produces no output at all.
#
# What this pins, for EVERY variant (not just the live one):
#   * the `Preview Serving Indexes` step exists and calls preview-resource.sh indexes
#   * preview-all exports indexes_has_changes
#   * the Build Deploy Matrix script really produces an `indexes` leg when run
#   * the Deploy Plan table shows the Serving Indexes row and the APIs index-only note
#   * the variants stay in parity with the live workflow apart from artifact v3/v4 and comments
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}/../../.."
LIVE="${ROOT}/.github/workflows/tapdata-deploy.yml"
VARIANTS=(
  "${ROOT}/.github/deploy/tapdata-deploy-matrix.yml"
  "${ROOT}/.github/deploy/tapdata-deploy-matrix-artifact-v3.yml"
)
FAILS=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

# Lift the Build Deploy Matrix `run:` block out of a workflow and swap each
# ${{ steps.preview_X.outputs.has_changes }} for env var X, so it can be executed.
extract_matrix_script() {
  python3 - "$1" <<'PY'
import re, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for step in doc['jobs']['preview-all']['steps']:
    if step.get('id') == 'build_matrix':
        print(re.sub(r'\$\{\{\s*steps\.preview_(\w+)\.outputs\.has_changes\s*\}\}',
                     lambda m: '${%s:-false}' % m.group(1).upper(), step['run']))
        break
else:
    raise SystemExit('build_matrix step not found')
PY
}

run_matrix() {  # $1 = workflow file; env vars set by caller
  local work; work="$(mktemp -d)"
  extract_matrix_script "$1" > "${work}/build_matrix.sh" 2>/dev/null
  GITHUB_OUTPUT="${work}/out" bash "${work}/build_matrix.sh" >/dev/null 2>&1
  grep '^deploy_matrix=' "${work}/out" 2>/dev/null | tail -1 | cut -d= -f2-
  rm -rf "${work}"
}

# Structural + behavioural checks, applied to the live workflow and every variant alike.
for WF in "${LIVE}" "${VARIANTS[@]}"; do
  NAME="$(basename "${WF}")"

  if grep -q 'id: preview_indexes' "${WF}" \
     && grep -q 'preview-resource.sh indexes' "${WF}"; then
    pass "${NAME}: Preview Serving Indexes step present"
  else fail "${NAME}: Preview Serving Indexes step present"; fi

  if grep -q 'indexes_has_changes:' "${WF}"; then
    pass "${NAME}: preview-all exports indexes_has_changes"
  else fail "${NAME}: preview-all exports indexes_has_changes"; fi

  # Behavioural: the leg is only real if the lifted script actually emits it. A grep would
  # pass on a workflow whose interpolation is broken -- that failure mode is silent.
  MATRIX=$(CONNECTIONS=true MIGRATE_TASKS=true SYNC_TASKS=true APIS=true INDEXES=true run_matrix "${WF}")
  KEYS=$(jq -r '[.include[].key] | join(",")' <<<"${MATRIX}" 2>/dev/null)
  if [[ "${KEYS}" == "connections,migrate-tasks,sync-tasks,apis,indexes" ]]; then
    pass "${NAME}: matrix really builds the indexes leg, last after apis"
  else fail "${NAME}: matrix really builds the indexes leg, last after apis (got: ${KEYS:-<none>})"; fi

  ENTRY=$(jq -c '.include[] | select(.key=="indexes")' <<<"${MATRIX}" 2>/dev/null)
  if [[ "$(jq -r '.archive' <<<"${ENTRY}" 2>/dev/null)" == "apis-export.tar" \
     && "$(jq -r '.import_arg' <<<"${ENTRY}" 2>/dev/null)" == "indexes" ]]; then
    pass "${NAME}: indexes leg reuses apis-export.tar with import_arg=indexes"
  else fail "${NAME}: indexes leg reuses apis-export.tar with import_arg=indexes (got: ${ENTRY:-<none>})"; fi

  if grep -q '| Serving Indexes |' "${WF}"; then
    pass "${NAME}: Deploy Plan lists Serving Indexes"
  else fail "${NAME}: Deploy Plan lists Serving Indexes"; fi

  # Ticking an index checkbox is a real Module change, so it shows up as an APIs change.
  # Without the note an approver reads that row as "the interface changed".
  if grep -q 'index_only_note' "${WF}"; then
    pass "${NAME}: APIs row carries the index-only note"
  else fail "${NAME}: APIs row carries the index-only note"; fi
done

# Parity: a variant may differ from the live workflow only in comments, the artifact
# action major version, and the TLS opt-out that rides along with it. Anything else means the
# copies have drifted -- which is exactly how the leg went missing in the first place.
# Widening this whitelist is a deliberate act.
#
# NODE_TLS_REJECT_UNAUTHORIZED belongs to the v3 variant alone and must never reach the live
# workflow: the artifact actions are the only Node-based steps that talk to the GHES over
# HTTPS, and that GHES serves a self-signed certificate. Turning certificate verification off
# on github.com would be a downgrade bought for nothing. The `> ` anchors matter -- a variant
# ADDING these lines is expected, the live workflow growing them is not, and neither is a
# variant LOSING an env block the live workflow has.
parity_diff() {
  diff "${LIVE}" "$1" | grep '^[<>]' \
    | grep -vE '^[<>] *#' \
    | grep -vE '^[<>] name: ' \
    | grep -vE 'actions/(upload|download)-artifact@v[0-9]+' \
    | grep -vE 'name: (Upload|Download) vault \(artifact v[0-9]+\)' \
    | grep -vE '^> *env:$' \
    | grep -vE '^> *NODE_TLS_REJECT_UNAUTHORIZED: '
}
for WF in "${VARIANTS[@]}"; do
  NAME="$(basename "${WF}")"
  EXTRA="$(parity_diff "${WF}")"
  if [[ -z "${EXTRA}" ]]; then
    pass "${NAME}: in parity with the live workflow (comments + artifact version aside)"
  else
    fail "${NAME}: drifted from the live workflow -- unexpected differences:"
    echo "${EXTRA}" | sed 's/^/        /'
  fi
done

# run-name parity across EVERY deploy copy, including the two the diff above does not cover
# (multi-job variant + the tenant-side callers). The caller's run-name is the one GitHub actually
# displays for a run, so a copy left behind here is invisible drift: the run still succeeds, it
# just stops naming the PR it deployed.
RUNNAME_FILES=(
  "${LIVE}"
  "${VARIANTS[@]}"
  "${ROOT}/.github/deploy/tapdata-deploy-multi-job.yml"
  "${ROOT}/tenant-template/.github/workflows/tapdata-deploy.yml"
  "${ROOT}/tenant-template/.github/disabled/tapdata-deploy.yml"
)
DISTINCT=$(for f in "${RUNNAME_FILES[@]}"; do grep -m1 '^run-name:' "${f}"; done | sort -u | wc -l | tr -d ' ')
# The PR title must stay at the TAIL. It resolves to github.event.head_commit.message on push, which
# is the WHOLE message (subject + body) -- GitHub expressions have no split(), so a squash commit with
# a body runs to hundreds of characters. Leading, it pushes project/env past the truncation point in
# the runs list; trailing, only its own tail gets cut. Hence the anchored check on the opening segment.
if [[ "${DISTINCT}" == "1" ]] \
  && grep -q 'github.event.pull_request.title || github.event.head_commit.message' "${LIVE}" \
  && grep -q '^run-name: "🚀 \${{ inputs.project' "${LIVE}"; then
  pass "all deploy copies share one run-name; it carries the PR title, and leads with project -> env"
else
  fail "deploy run-name drift (${DISTINCT} distinct), PR title missing, or title moved off the tail:"
  for f in "${RUNNAME_FILES[@]}"; do echo "        $(basename "${f}"): $(grep -m1 '^run-name:' "${f}")"; done
fi

echo ""
if [[ "${FAILS}" -eq 0 ]]; then
  echo "All tests passed."
else
  echo "${FAILS} test(s) failed."
  exit 1
fi
