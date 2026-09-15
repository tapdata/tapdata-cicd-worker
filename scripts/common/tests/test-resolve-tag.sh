#!/usr/bin/env bash
# Local unit tests for tapdata-rollback/resolve-tag.sh
# (run: bash scripts/common/tests/test-resolve-tag.sh)
#
# 回归重点：校验必须完全走本地 git + origin，不碰 GitHub REST API。
# 旧实现把 https://api.github.com 硬编码为多租户模式的入口，在内网 GHES 的
# self-hosted runner 上 DNS 必然解析失败（curl exit 6），而且传输层失败会被
# 伪装成"tag 不存在"，把人引到错误的方向。Test 5 和 Test 7 就是守这两条线的。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/../../tapdata-rollback/resolve-tag.sh"
FAILS=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

setup() {
  WORK="$(mktemp -d)"
  ORIGIN="${WORK}/origin.git"
  REPO="${WORK}/repo"
  {
    git init -q --bare "${ORIGIN}"
    git init -q "${WORK}/seed"
    cd "${WORK}/seed"
    echo seed > f.txt
    git add f.txt
    git -c user.name=t -c user.email=t@example.com commit -qm init
    git tag 1.0.0
    git remote add origin "${ORIGIN}"
    git push -q origin HEAD:refs/heads/main --tags
    cd "${SCRIPT_DIR}"
    git -C "${ORIGIN}" symbolic-ref HEAD refs/heads/main
    git clone -q "${ORIGIN}" "${REPO}"
  } >/dev/null 2>&1
  export REPO_ROOT="${REPO}"
  export GITHUB_OUTPUT="${WORK}/gh_output"; : > "${GITHUB_OUTPUT}"
  export LAST_STABLE_TAG="1.0.0"
}
teardown() { rm -rf "${WORK}"; }
run_sut() { RC=0; bash "${SUT}" >"${WORK}/out.log" 2>&1 || RC=$?; }
out() { grep "^$1=" "${GITHUB_OUTPUT}" | tail -1 | cut -d= -f2-; }
logged() { grep -q "$1" "${WORK}/out.log"; }

# Test 1: 未提供 tag => exit 1
setup
export LAST_STABLE_TAG=""
run_sut
if [[ ${RC} -ne 0 ]] && logged "LAST_STABLE_TAG is not set"; then
  pass "空 LAST_STABLE_TAG => exit 1"
else fail "空 LAST_STABLE_TAG => exit 1"; fi
teardown

# Test 2: tag 在本地 checkout 里 => 通过，且不需要回远端
setup
run_sut
if [[ ${RC} -eq 0 ]] && [[ "$(out last_stable_tag)" == "1.0.0" ]] && ! logged "confirming against"; then
  pass "本地有 tag => 通过，不访问 origin"
else fail "本地有 tag => 通过，不访问 origin"; fi
teardown

# Test 3: 本地没有但远端有（浅克隆 / 没 fetch tags）=> 通过并告警
setup
git -C "${REPO}" tag -d 1.0.0 >/dev/null 2>&1
run_sut
if [[ ${RC} -eq 0 ]] && [[ "$(out last_stable_tag)" == "1.0.0" ]] && logged "::warning::"; then
  pass "本地缺 tag、origin 有 => 通过并告警"
else fail "本地缺 tag、origin 有 => 通过并告警"; fi
teardown

# Test 4: 两边都没有 => exit 1，报 tag 不存在
setup
export LAST_STABLE_TAG="9.9.9"
run_sut
if [[ ${RC} -ne 0 ]] && logged "does not exist"; then
  pass "tag 确实不存在 => exit 1"
else fail "tag 确实不存在 => exit 1"; fi
teardown

# Test 5【核心回归】: origin 不可达 => 必须报"连不上"，绝不能伪装成"tag 不存在"
setup
git -C "${REPO}" tag -d 1.0.0 >/dev/null 2>&1
git -C "${REPO}" remote set-url origin "${WORK}/no-such-repo.git" >/dev/null 2>&1
run_sut
if [[ ${RC} -ne 0 ]] && logged "Failed to reach" && ! logged "does not exist"; then
  pass "origin 不可达 => 报传输失败，不误报 tag 不存在"
else fail "origin 不可达 => 报传输失败，不误报 tag 不存在"; fi
teardown

# Test 6: REPO_ROOT 不是 git 工作区 => exit 1 且信息明确
setup
export REPO_ROOT="${WORK}/plain"; mkdir -p "${REPO_ROOT}"
run_sut
if [[ ${RC} -ne 0 ]] && logged "not a git work tree"; then
  pass "REPO_ROOT 非 git 工作区 => exit 1"
else fail "REPO_ROOT 非 git 工作区 => exit 1"; fi
teardown

# Test 7【核心回归】: 脚本的代码里不得再出现任何硬编码的 GitHub API 主机
# （整行注释除外——脚本头部特意留了这段历史教训的说明）
if grep -v '^[[:space:]]*#' "${SUT}" | grep -q "api\.github\.com"; then
  fail "resolve-tag.sh 不得硬编码 api.github.com"
else pass "resolve-tag.sh 不含硬编码 api.github.com"; fi

# Test 8: 单仓库模式（不传 REPO_ROOT，cwd 即数据仓库）=> 回落到 \$PWD 仍然通过
setup
unset REPO_ROOT
( cd "${REPO}" && bash "${SUT}" >"${WORK}/out.log" 2>&1 ); RC=$?
if [[ ${RC} -eq 0 ]] && [[ "$(out last_stable_tag)" == "1.0.0" ]]; then
  pass "未设 REPO_ROOT => 回落 \$PWD 通过"
else fail "未设 REPO_ROOT => 回落 \$PWD 通过"; fi
teardown

echo
if [[ ${FAILS} -eq 0 ]]; then echo "ALL TESTS PASSED"; exit 0; else echo "${FAILS} TEST(S) FAILED"; exit 1; fi
