#!/usr/bin/env bash
# Analyze conf/Task_Run_Order.json and list rebuild tasks with execution order
# Required env vars: TASK_NAMES, RESET_REASON, NEED_DROP_TABLE
# Output: rebuild_task_list, rebuild_task_order (via GITHUB_OUTPUT)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_ORDER_JSON="${SCRIPT_DIR}/../../conf/Task_Run_Order.json"

echo "=== Listing Rebuild Tasks ==="

if [[ ! -f "${TASK_ORDER_JSON}" ]]; then
  echo "::error::Task_Run_Order.json not found at ${TASK_ORDER_JSON}"
  exit 1
fi

# Parse input task names (comma separated) into array
IFS=',' read -ra INPUT_TASKS <<< "${TASK_NAMES}"
# Trim whitespace from each task name
TRIMMED_TASKS=()
for task in "${INPUT_TASKS[@]}"; do
  trimmed=$(echo "${task}" | xargs)
  if [[ -n "${trimmed}" ]]; then
    TRIMMED_TASKS+=("${trimmed}")
  fi
done

if [[ ${#TRIMMED_TASKS[@]} -eq 0 ]]; then
  echo "::error::No valid task names provided after parsing"
  exit 1
fi

# Read all nodes from Task_Run_Order.json
ALL_NODES=$(jq -r '.nodes[].name' "${TASK_ORDER_JSON}")

# Validate that all input tasks exist in Task_Run_Order.json
for task in "${TRIMMED_TASKS[@]}"; do
  if ! echo "${ALL_NODES}" | grep -qxF "${task}"; then
    echo "::error::Task '${task}' not found in Task_Run_Order.json"
    exit 1
  fi
done

# Build the execution order using topological sort based on edges
# Only consider tasks that are in the rebuild list
# A task should run before another if there's an edge: source -> target
# and both are in the rebuild list

# Create a JSON array of rebuild task names
REBUILD_TASKS_JSON=$(printf '%s\n' "${TRIMMED_TASKS[@]}" | jq -R . | jq -s .)

# Use jq to perform topological sort on the rebuild tasks
# 1. Filter edges to only include those where both source and target are in rebuild list
# 2. Compute in-degree for each rebuild task
# 3. Output tasks in topological order
ORDERED_TASKS=$(jq -r --argjson rebuild "${REBUILD_TASKS_JSON}" '
  .edges as $edges |
  # Filter edges where both source and target are in rebuild list
  [$edges[] | select(.source as $s | .target as $t | ($rebuild | index($s)) and ($rebuild | index($t)))] as $filtered_edges |
  # Kahn algorithm: compute in-degree
  ($rebuild | map({(.): 0}) | add) as $initial_indegree |
  (reduce $filtered_edges[] as $e ($initial_indegree; .[$e.target] += 1)) as $indegree |
  # BFS topological sort
  {
    queue: [$rebuild[] | select(. as $n | $indegree[$n] == 0)],
    result: [],
    indegree: $indegree
  } |
  until(.queue | length == 0;
    .queue[0] as $current |
    .result += [$current] |
    .queue = .queue[1:] |
    . as $state |
    reduce ($filtered_edges[] | select(.source == $current)) as $e ($state;
      .indegree[$e.target] -= 1 |
      if .indegree[$e.target] == 0 then .queue += [$e.target] else . end
    )
  ) |
  .result[]
' "${TASK_ORDER_JSON}")

# Build display list
echo ""
echo "=========================================="
echo "  Rebuild Task List (Execution Order)"
echo "=========================================="
echo "  Reset Reason: ${RESET_REASON}"
echo "  Need Drop Table: ${NEED_DROP_TABLE:-false}"
echo "=========================================="

TASK_LIST=""
ORDER_INDEX=1
while IFS= read -r task; do
  echo "  ${ORDER_INDEX}. ${task}"
  if [[ -n "${TASK_LIST}" ]]; then
    TASK_LIST="${TASK_LIST}\n${ORDER_INDEX}. ${task}"
  else
    TASK_LIST="${ORDER_INDEX}. ${task}"
  fi
  ORDER_INDEX=$((ORDER_INDEX + 1))
done <<< "${ORDERED_TASKS}"

echo "=========================================="
echo ""

# Build ordered task list as JSON array for downstream jobs
ORDERED_JSON=$(echo "${ORDERED_TASKS}" | jq -R . | jq -s .)

# Set outputs
{
  echo "rebuild_task_list<<EOF"
  echo -e "${TASK_LIST}"
  echo "EOF"
} >> "${GITHUB_OUTPUT}"

echo "rebuild_task_order=${ORDERED_JSON}" >> "${GITHUB_OUTPUT}"

echo "=== Rebuild Tasks Listed Successfully ==="

