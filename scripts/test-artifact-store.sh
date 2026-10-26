#!/usr/bin/env bash
# Source-tree artifact store regressions (YAN-1153). No generated bundles required.
# shellcheck disable=SC2016 # Inner-shell programs and injection fixtures must stay literal.
set -euo pipefail
export BASH_BIN=${BASH_BIN:-bash}
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)"
HELPER="${SCRIPT_DIR}/../ycc/skills/_shared/scripts/resolve-artifact-store.sh"
PLANS="${SCRIPT_DIR}/../ycc/skills/_shared/scripts/resolve-plans-dir.sh"
# Canonicalize TMPDIR so symlinked temporary roots (including macOS /tmp) do
# not make fixture expectations differ from Git's physical paths.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ycc-artifact-store.XXXXXX")"
SCRATCH="$(CDPATH='' cd -- "$SCRATCH" >/dev/null && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT
# Isolate scratch Git calls even when launched from a hook, and never consult
# the caller's user/system configuration or artifact store settings.
while IFS= read -r git_var; do unset "$git_var"; done < <(git rev-parse --local-env-vars)
unset git_var
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${SCRATCH}/gitconfig"
export HOME="${SCRATCH}/home" XDG_CONFIG_HOME="${SCRATCH}/config"
export GIT_CEILING_DIRECTORIES="$SCRATCH"
mkdir -p "$HOME" "${XDG_CONFIG_HOME}/ycc"
cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
  name = ycc test
  email = ycc-test@example.invalid
[commit]
  gpgsign = false
[init]
  defaultBranch = main
EOF
# Deliberately hostile ancestor settings must not leak across repo boundaries.
printf 'scope: local\nstore: local\nlinear_team: OUTSIDE\n' >"${SCRATCH}/.plans-config"
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*" >&2; }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label: expected '$expected', got '$actual'"; fi
}
assert_ok() {
  local label="$1"; shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}
assert_bad() {
  local label="$1"; shift
  if "$@" >"${SCRATCH}/out" 2>"${SCRATCH}/err"; then fail "$label: unexpectedly succeeded"; else
    pass "$label"
    assert_ok "$label diagnoses on stderr" test -s "${SCRATCH}/err"
  fi
}
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" commit -q --allow-empty -m init
  printf 'scope: local\n' >"${dir}/.plans-config"
}
# Always source from the fixture so auto-resolution cannot see this checkout.
run() { local dir="$1"; shift; (CDPATH='' cd -- "$dir" >/dev/null && "$BASH_BIN" -c 'source "$1"; shift; "$@"' _ "$HELPER" "$@"); }
# shellcheck disable=SC2016 # The inner Bash evaluates the fixture's exported values.
field() { local dir="$1" key="$2"; shift 2; (CDPATH='' cd -- "$dir" >/dev/null && "$BASH_BIN" -c 'source "$1"; key=$2; shift 2; if [[ $# -gt 0 ]]; then resolve_artifact_store "$@" || exit; fi; printf "%s" "${!key}"' _ "$HELPER" "$key" "$@"); }
# Store precedence and sources; resolving and sourcing never create the cache.
repo="${SCRATCH}/repo with space"
make_repo "$repo"
assert_eq 'default store' linear "$(field "$repo" ARTIFACT_STORE)"
assert_eq 'default source' default "$(field "$repo" ARTIFACT_STORE_SOURCE)"
assert_eq 'linear cache path' "${repo}/.ycc/artifacts" "$(field "$repo" ARTIFACT_DIR)"
assert_eq 'artifact root' "$repo" "$(field "$repo" ARTIFACT_ROOT)"
assert_ok 'resolution is read-only' test ! -e "${repo}/.ycc"
assert_eq 'ancestor team outside repo ignored' '' "$(field "$repo" ARTIFACT_LINEAR_TEAM)"
ln -s "$repo" "${SCRATCH}/repo-link"
assert_eq 'symlink checkout ignores ancestor store' linear "$(field "${SCRATCH}/repo-link" ARTIFACT_STORE)"
assert_eq 'symlink checkout ignores ancestor team' '' "$(field "${SCRATCH}/repo-link" ARTIFACT_LINEAR_TEAM)"
assert_eq 'symlink checkout local parity' "$(CDPATH='' cd -- "${SCRATCH}/repo-link" >/dev/null && "$BASH_BIN" "$PLANS")" "$(field "${SCRATCH}/repo-link" ARTIFACT_DIR --store=local)"
printf 'store: local\n' >"${XDG_CONFIG_HOME}/ycc/config"
assert_eq 'global store' local "$(field "$repo" ARTIFACT_STORE)"
assert_eq 'global source' global "$(field "$repo" ARTIFACT_STORE_SOURCE)"
printf 'scope: local\nstore: linear\n' >"${repo}/.plans-config"
assert_eq 'config beats global' linear "$(field "$repo" ARTIFACT_STORE)"
assert_eq 'config source' config "$(field "$repo" ARTIFACT_STORE_SOURCE)"
assert_eq 'flag beats config' local "$(field "$repo" ARTIFACT_STORE --store=local)"
assert_eq 'flag source' flag "$(field "$repo" ARTIFACT_STORE_SOURCE --store=local)"
printf 'store: broken\n' >"${XDG_CONFIG_HOME}/ycc/config"
assert_eq 'config masks invalid global' linear "$(field "$repo" ARTIFACT_STORE)"
assert_bad 'invalid flag' run "$repo" resolve_artifact_store --store=broken
assert_bad 'empty flag' run "$repo" resolve_artifact_store --store=
printf 'scope: local\nstore: broken\n' >"${repo}/.plans-config"
# Executed resolution fails, but sourced auto-resolution must remain non-fatal.
assert_bad 'invalid config' "$BASH_BIN" "$HELPER" "$repo"
assert_ok 'explicit invalid config prints error' grep -q '^ERROR:' "${SCRATCH}/err"
assert_eq 'strict invalid source survives and clears stale exports' 'unset|local' "$(CDPATH='' cd -- "$repo" >/dev/null && "$BASH_BIN" -ec 'export ARTIFACT_STORE=stale ARTIFACT_ROOT=stale ARTIFACT_DIR=stale ARTIFACT_STORE_SOURCE=stale ARTIFACT_LINEAR_WORKSPACE=stale ARTIFACT_LINEAR_TEAM=stale ARTIFACT_LINEAR_PROJECT=stale ARTIFACT_LINEAR_LABEL=stale ARTIFACT_LINEAR_HINT=stale; source "$1"; for key in ARTIFACT_STORE ARTIFACT_ROOT ARTIFACT_DIR ARTIFACT_STORE_SOURCE ARTIFACT_LINEAR_WORKSPACE ARTIFACT_LINEAR_TEAM ARTIFACT_LINEAR_PROJECT ARTIFACT_LINEAR_LABEL ARTIFACT_LINEAR_HINT; do [[ -z ${!key+x} ]]; done; printf "unset|"; resolve_artifact_store --store=local; printf %s "$ARTIFACT_STORE"' _ "$HELPER" 2>"${SCRATCH}/err")"
assert_ok 'sourced invalid config prints warning' grep -q '^WARNING:' "${SCRATCH}/err"
assert_eq 'sourced invalid config warns only once' 1 "$(wc -l <"${SCRATCH}/err" | tr -d ' ')"
printf 'scope: local\nstore:\n' >"${repo}/.plans-config"
assert_bad 'empty config is invalid' "$BASH_BIN" "$HELPER" "$repo"
printf 'scope: local\n' >"${repo}/.plans-config"
assert_bad 'invalid global' "$BASH_BIN" "$HELPER" "$repo"
printf 'store:\n' >"${XDG_CONFIG_HOME}/ycc/config"
assert_bad 'empty global is invalid' "$BASH_BIN" "$HELPER" "$repo"
rm "${XDG_CONFIG_HOME}/ycc/config"
# HOME fallback when XDG_CONFIG_HOME is not set.
mkdir -p "${HOME}/.config/ycc"
printf 'store=local # comment\n' >"${HOME}/.config/ycc/config"
assert_eq 'HOME global fallback' local "$(CDPATH='' cd -- "$repo" >/dev/null && env -u XDG_CONFIG_HOME "$BASH_BIN" "$HELPER" --shell | "$BASH_BIN" -c 'eval "$(cat)"; printf %s "$ARTIFACT_STORE"')"
# Independent nearest-key inheritance, not merely nearest config file.
printf 'scope: local\nstore: local\nlinear_workspace: parent\nlinear_team: YAN\nlinear_project: parent-project\nlinear_label: repo:parent\n' >"${repo}/.plans-config"
child="${repo}/packages/app"
mkdir -p "${child}/src"
printf 'scope: local\nstore: linear\nlinear_workspace: child workspace\nlinear_project: child-project\n' >"${child}/.plans-config"
assert_eq 'nearest store' linear "$(field "${child}/src" ARTIFACT_STORE)"
assert_eq 'nearest workspace' 'child workspace' "$(field "${child}/src" ARTIFACT_LINEAR_WORKSPACE)"
assert_eq 'inherited team' YAN "$(field "${child}/src" ARTIFACT_LINEAR_TEAM)"
assert_eq 'nearest project' child-project "$(field "${child}/src" ARTIFACT_LINEAR_PROJECT)"
assert_eq 'inherited label' repo:parent "$(field "${child}/src" ARTIFACT_LINEAR_LABEL)"
printf 'scope: local\nlinear_team:\n' >"${child}/.plans-config"
assert_eq 'omitted store inherits' local "$(field "${child}/src" ARTIFACT_STORE)"
assert_eq 'empty hint stops inheritance' '' "$(field "${child}/src" ARTIFACT_LINEAR_TEAM)"
# Local output must be byte-for-byte the old resolver in default, custom, and
# monorepo local-scope cases (including directories that do not exist yet).
for fixture in default custom monorepo; do
  local_repo="${SCRATCH}/local-${fixture}"
  make_repo "$local_repo"
  start="$local_repo"
  case "$fixture" in
    custom) printf 'scope: local\nplans_dir: custom plans\n' >"${start}/.plans-config" ;;
    monorepo)
      start="${local_repo}/packages/child"; mkdir -p "${start}/src"
      printf 'scope: local\nplans_dir: child-plans\n' >"${start}/.plans-config"
      start="${start}/src" ;;
  esac
  expected="$(CDPATH='' cd -- "$start" >/dev/null && "$BASH_BIN" "$PLANS")"
  assert_eq "local ${fixture} equals legacy resolver" "$expected" "$(field "$start" ARTIFACT_DIR --store=local)"
done
# A real fresh clone discovers the committed pointer and stays clean on save.
origin="${SCRATCH}/origin"; make_repo "$origin"
printf 'scope: local\nstore: linear\nlinear_workspace: yandy-r\nlinear_team: YAN\nlinear_project: project-id\nlinear_label: repo:ystack\n' >"${origin}/.plans-config"
printf '.ycc/artifacts/\n' >"${origin}/.gitignore"
git -C "$origin" add .plans-config .gitignore
git -C "$origin" commit -q -m pointer
fresh="${SCRATCH}/fresh"
git clone -q "$origin" "$fresh"
for pair in 'STORE linear' 'LINEAR_WORKSPACE yandy-r' 'LINEAR_TEAM YAN' 'LINEAR_PROJECT project-id' 'LINEAR_LABEL repo:ystack'; do
  read -r key value <<<"$pair"
  assert_eq "fresh clone ${key}" "$value" "$(field "$fresh" "ARTIFACT_${key}")"
done
assert_ok 'fresh clone cache remains absent' test ! -e "${fresh}/.ycc/artifacts"
run "$fresh" ensure_artifact_dir
assert_eq 'fresh clone first save keeps Git clean' '' "$(git -C "$fresh" status --porcelain)"
# Branch keys, boundaries, case, and team gating.
for pair in 'yramirez/yan-1152-foo YAN-1152' 'feat/YAN-1152-x YAN-1152' 'YAN-42 YAN-42' 'feat_YAN-43_more YAN-43' 'feat-YAN-44/x YAN-44' 'feat/OTHER-12-x -' 'feat/notYAN-12-x -' 'feat/YAN-12suffix -' 'feature/no-key -'; do
  read -r branch expected <<<"$pair"
  git -C "$fresh" checkout -q -B "$branch"
  [[ "$expected" != - ]] || expected=''
  assert_eq "branch ${branch}" "$expected" "$(field "$fresh" ARTIFACT_LINEAR_HINT)"
done
printf 'scope: local\nlinear_team: Y.N\n' >"${fresh}/.plans-config"
git -C "$fresh" checkout -q -B feat/YAN-1-x
assert_eq 'non-alphanumeric configured team gives no hint' '' "$(field "$fresh" ARTIFACT_LINEAR_HINT)"
printf 'scope: local\n' >"${fresh}/.plans-config"
for pair in 'feat/abc2-123_x ABC2-123' 'feat/A-1-x -' 'feat/ABCDEFGHIJK-1-x -' 'feat/AB-1-x-CD-2 AB-1'; do
  read -r branch expected <<<"$pair"
  git -C "$fresh" checkout -q -B "$branch"
  [[ "$expected" != - ]] || expected=''
  assert_eq "ungated ${branch}" "$expected" "$(field "$fresh" ARTIFACT_LINEAR_HINT)"
done
git -C "$fresh" checkout -q --detach
assert_eq 'detached hint empty' '' "$(field "$fresh" ARTIFACT_LINEAR_HINT)"
no_git="${SCRATCH}/not git"; mkdir -p "$no_git"
printf 'scope: local\n' >"${no_git}/.plans-config"
assert_eq 'no Git hint empty' '' "$(field "$no_git" ARTIFACT_LINEAR_HINT)"
# Gitignore writes only on first save, preserving existing bytes and wider rules.
for variant in missing no-newline exact slash rooted rooted-slash wider; do
  ignore_repo="${SCRATCH}/ignore-${variant}"; make_repo "$ignore_repo"
  case "$variant" in
    no-newline) printf '# existing' >"${ignore_repo}/.gitignore" ;;
    exact) printf '.ycc/artifacts' >"${ignore_repo}/.gitignore" ;;
    slash) printf '.ycc/artifacts/\n' >"${ignore_repo}/.gitignore" ;;
    rooted) printf '/.ycc/artifacts\n' >"${ignore_repo}/.gitignore" ;;
    rooted-slash) printf '/.ycc/artifacts/\n' >"${ignore_repo}/.gitignore" ;;
    wider) printf '.ycc/\n' >"${ignore_repo}/.gitignore" ;;
  esac
  if [[ -f "${ignore_repo}/.gitignore" ]]; then cp "${ignore_repo}/.gitignore" "${SCRATCH}/before"; fi
  run "$ignore_repo" ensure_artifact_gitignore
  run "$ignore_repo" ensure_artifact_gitignore
  case "$variant" in
    missing) assert_eq "ignore ${variant}: one line" '.ycc/artifacts/' "$(cat "${ignore_repo}/.gitignore")" ;;
    no-newline) assert_eq 'ignore inserts newline' $'# existing\n.ycc/artifacts/' "$(cat "${ignore_repo}/.gitignore")" ;;
    *) assert_ok "ignore ${variant}: byte unchanged" cmp -s "${SCRATCH}/before" "${ignore_repo}/.gitignore" ;;
  esac
  assert_ok "ignore ${variant}: no cache created" test ! -e "${ignore_repo}/.ycc/artifacts"
done
sub_repo="${SCRATCH}/subdir-ignore"; make_repo "$sub_repo"
sub_root="${sub_repo}/packages/app"; mkdir -p "$sub_root"
printf 'scope: local\nstore: linear\n' >"${sub_root}/.plans-config"
printf '.ycc/\n' >"${sub_root}/.gitignore"
cp "${sub_root}/.gitignore" "${SCRATCH}/before"
run "$sub_root" ensure_artifact_dir
assert_ok 'scope-local wider ignore stays unchanged' cmp -s "${SCRATCH}/before" "${sub_root}/.gitignore"
ln -s "$sub_repo" "${SCRATCH}/subdir-link"
assert_eq 'symlink scope-local root stays local' "${SCRATCH}/subdir-link/packages/app" "$(field "${SCRATCH}/subdir-link/packages/app" ARTIFACT_ROOT)"
run "${SCRATCH}/subdir-link/packages/app" ensure_artifact_dir
assert_ok 'symlink scope-local ignore stays unchanged' cmp -s "${SCRATCH}/before" "${sub_root}/.gitignore"
# Refuse every write entry point if a tracked or untracked symlink can escape.
for link_kind in gitignore ycc artifacts; do
  link_repo="${SCRATCH}/symlink-${link_kind}"; make_repo "$link_repo"
  target="${SCRATCH}/target-${link_kind}"
  case "$link_kind" in
    gitignore)
      printf '# untouched\n' >"$target"
      ln -s "$target" "${link_repo}/.gitignore"
      git -C "$link_repo" add .gitignore
      git -C "$link_repo" commit -q -m symlink
      ;;
    ycc) mkdir -p "$target"; ln -s "$target" "${link_repo}/.ycc" ;;
    artifacts) mkdir -p "$target" "${link_repo}/.ycc"; ln -s "$target" "${link_repo}/.ycc/artifacts" ;;
  esac
  assert_bad "${link_kind} symlink refuses ignore write" run "$link_repo" ensure_artifact_gitignore
  assert_bad "${link_kind} symlink refuses directory write" run "$link_repo" ensure_artifact_dir
  if [[ "$link_kind" == gitignore ]]; then
    assert_eq 'symlink ignore target untouched' '# untouched' "$(cat "$target")"
    assert_ok 'symlink ignore refusal creates no cache' test ! -e "${link_repo}/.ycc"
  else
    assert_eq "${link_kind} symlink target untouched" '' "$(find "$target" -mindepth 1 -print)"
    assert_ok "${link_kind} symlink refusal creates no ignore" test ! -e "${link_repo}/.gitignore"
  fi
done
global_ignore_repo="${SCRATCH}/global-ignore"; make_repo "$global_ignore_repo"
printf '.ycc/\n' >"${SCRATCH}/global-excludes"
git config --global core.excludesFile "${SCRATCH}/global-excludes"
run "$global_ignore_repo" ensure_artifact_gitignore
assert_eq 'global excludes does not replace repo ignore' '.ycc/artifacts/' "$(cat "${global_ignore_repo}/.gitignore")"
git config --global --unset core.excludesFile
info_ignore_repo="${SCRATCH}/info-ignore"; make_repo "$info_ignore_repo"
printf '.ycc/\n' >"${info_ignore_repo}/.git/info/exclude"
run "$info_ignore_repo" ensure_artifact_gitignore
assert_eq 'Git info excludes does not replace repo ignore' '.ycc/artifacts/' "$(cat "${info_ignore_repo}/.gitignore")"
local_repo="${SCRATCH}/ignore-local"; make_repo "$local_repo"
printf 'scope: local\nstore: local\n' >"${local_repo}/.plans-config"
run "$local_repo" ensure_artifact_gitignore
assert_ok 'local ignore leaves missing file absent' test ! -e "${local_repo}/.gitignore"
printf '# preserve exactly' >"${local_repo}/.gitignore"
cp "${local_repo}/.gitignore" "${SCRATCH}/before"
run "$local_repo" ensure_artifact_dir
assert_ok 'local ensure creates plans dir' test -d "${local_repo}/docs/plans"
assert_ok 'local ensure preserves gitignore' cmp -s "${SCRATCH}/before" "${local_repo}/.gitignore"
run "$fresh" ensure_artifact_dir
assert_ok 'linear ensure creates cache' test -d "${fresh}/.ycc/artifacts"
assert_ok 'linear ensure ignores cache' git -C "$fresh" check-ignore -q -- .ycc/artifacts/probe
assert_eq 'feature path' "${fresh}/.ycc/artifacts/good-slug" "$(run "$fresh" get_feature_artifact_dir good-slug)"
for slug in '' .. . -x ../bad bad/name 'white space'; do assert_bad "invalid slug '${slug}'" run "$fresh" get_feature_artifact_dir "$slug"; done
assert_eq 'embedded dots in slug allowed' "${fresh}/.ycc/artifacts/v1..2" "$(run "$fresh" get_feature_artifact_dir v1..2)"
assert_ok 'feature lookup remains pure' test ! -e "${fresh}/.ycc/artifacts/good-slug"
assert_bad 'non-Git ignore refuses' run "$no_git" ensure_artifact_gitignore
assert_bad 'non-Git cache refuses' run "$no_git" ensure_artifact_dir
assert_ok 'non-Git refusal creates no ignore' test ! -e "${no_git}/.gitignore"
assert_ok 'non-Git refusal creates no cache' test ! -e "${no_git}/.ycc"
# A nested repository must not use the enclosing checkout's artifact root.
outer="${SCRATCH}/outer"; make_repo "$outer"
printf 'plans_dir: docs/plans\n' >"${outer}/.plans-config"
inner="${outer}/nested"; make_repo "$inner"
printf 'store: linear\n' >"${inner}/.plans-config"
assert_eq 'nested linear root remains inside inner repo' "$inner" "$(field "$inner" ARTIFACT_ROOT)"
assert_eq 'nested local mode retains legacy path' "$(CDPATH='' cd -- "$inner" >/dev/null && "$BASH_BIN" "$PLANS")" "$(field "$inner" ARTIFACT_DIR --store=local)"
run "$inner" ensure_artifact_dir
assert_ok 'nested save creates inner cache' test -d "${inner}/.ycc/artifacts"
assert_eq 'nested save writes inner ignore' '.ycc/artifacts/' "$(cat "${inner}/.gitignore")"
assert_ok 'nested save leaves outer ignore absent' test ! -e "${outer}/.gitignore"
assert_ok 'nested save leaves outer cache absent' test ! -e "${outer}/.ycc"
worktree_parent="${SCRATCH}/worktree-parent"; make_repo "$worktree_parent"
printf 'plans_dir: docs/plans\nstore: linear\n' >"${worktree_parent}/.plans-config"
git -C "$worktree_parent" add .plans-config
git -C "$worktree_parent" commit -q -m pointer
worktree="${worktree_parent}/.omp/worktrees/x"
git -C "$worktree_parent" worktree add -q -b feature-worktree "$worktree"
assert_eq 'real nested worktree root is worktree' "$worktree" "$(field "$worktree" ARTIFACT_ROOT)"
run "$worktree" ensure_artifact_dir
assert_ok 'real worktree first save stays inside worktree' test -d "${worktree}/.ycc/artifacts"
assert_ok 'real worktree save leaves parent cache absent' test ! -e "${worktree_parent}/.ycc"
# Strict callers survive sourcing, and non-strict callers do not gain errexit.
assert_eq 'set -e caller survives source' survived "$(CDPATH='' cd -- "$fresh" >/dev/null && "$BASH_BIN" -ec 'source "$1"; printf survived' _ "$HELPER")"
assert_eq 'source does not enable errexit' off "$(CDPATH='' cd -- "$fresh" >/dev/null && "$BASH_BIN" -c 'source "$1"; case $- in *e*) printf on;; *) printf off;; esac' _ "$HELPER")"
# Shell assignments are eval-able, including whitespace and empty values.
printf 'scope: local\nlinear_workspace: a workspace\nlinear_label: repo:quoted\n' >"${fresh}/.plans-config"
assert_eq 'shell output eval roundtrip' "linear|flag|${fresh}/.ycc/artifacts|a workspace|repo:quoted|" "$(CDPATH='' cd -- "$fresh" >/dev/null && "$BASH_BIN" -c 'eval "$("$BASH_BIN" "$1" --shell --store=linear)"; printf "%s|%s|%s|%s|%s|%s" "$ARTIFACT_STORE" "$ARTIFACT_STORE_SOURCE" "$ARTIFACT_DIR" "$ARTIFACT_LINEAR_WORKSPACE" "$ARTIFACT_LINEAR_LABEL" "$ARTIFACT_LINEAR_HINT"' _ "$HELPER")"
assert_eq 'shell output exports all nine fields' 9 "$(CDPATH='' cd -- "$fresh" >/dev/null && "$BASH_BIN" "$HELPER" --shell | wc -l | tr -d ' ')"
# shellcheck disable=SC2016 # Deliberately literal shell injection payload.
unsafe_label='$(touch "'"${SCRATCH}"'/pwned") `id`'
printf 'scope: local\nlinear_label: %s\n' "$unsafe_label" >"${fresh}/.plans-config"
# _parse_config uses xargs, which strips quotes; compare against its parsed value.
# shellcheck disable=SC2016 # Deliberately literal expected parsed payload.
parsed_label='$(touch '"${SCRATCH}"'/pwned) `id`'
assert_eq 'shell output does not execute label' "$parsed_label" "$(CDPATH='' cd -- "$fresh" >/dev/null && "$BASH_BIN" -c 'eval "$("$BASH_BIN" "$1" --shell)"; printf %s "$ARTIFACT_LINEAR_LABEL"' _ "$HELPER")"
assert_ok 'shell eval creates no injected file' test ! -e "${SCRATCH}/pwned"
assert_ok 'help succeeds' "$BASH_BIN" "$HELPER" --help > /dev/null
assert_bad 'unknown CLI flag fails' "$BASH_BIN" "$HELPER" --unknown "$fresh"
assert_bad 'missing start directory fails' "$BASH_BIN" "$HELPER" "${SCRATCH}/missing"
assert_ok 'helper executable' test -x "$HELPER"
printf 'test-artifact-store.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
