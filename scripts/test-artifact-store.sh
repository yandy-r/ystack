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
make_linear_repo() {
  make_repo "$1"
  printf 'scope: local\nstore: linear\n' >"$1/.plans-config"
}
# Always source from the fixture so auto-resolution cannot see this checkout.
run() { local dir="$1"; shift; (CDPATH='' cd -- "$dir" >/dev/null && "$BASH_BIN" -c 'source "$1"; shift; "$@"' _ "$HELPER" "$@"); }
# shellcheck disable=SC2016 # The inner Bash evaluates the fixture's exported values.
field() { local dir="$1" key="$2"; shift 2; (CDPATH='' cd -- "$dir" >/dev/null && "$BASH_BIN" -c 'source "$1"; key=$2; shift 2; if [[ $# -gt 0 ]]; then resolve_artifact_store "$@" || exit; fi; printf "%s" "${!key}"' _ "$HELPER" "$key" "$@"); }
# Store precedence and sources; resolving and sourcing never create the cache.
repo="${SCRATCH}/repo with space"
make_repo "$repo"
assert_eq 'default store' local "$(field "$repo" ARTIFACT_STORE)"
assert_eq 'default source' default "$(field "$repo" ARTIFACT_STORE_SOURCE)"
assert_eq 'default local plans path' "${repo}/docs/plans" "$(field "$repo" ARTIFACT_DIR)"
assert_eq 'artifact root' "$repo" "$(field "$repo" ARTIFACT_ROOT)"
assert_ok 'resolution is read-only' test ! -e "${repo}/.ycc"
assert_eq 'ancestor team outside repo ignored' '' "$(field "$repo" ARTIFACT_LINEAR_TEAM)"
ln -s "$repo" "${SCRATCH}/repo-link"
assert_eq 'symlink checkout ignores ancestor store' local "$(field "${SCRATCH}/repo-link" ARTIFACT_STORE)"
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
  printf 'scope: local\nstore: linear\n' >"${fresh}/.plans-config"
for pair in 'feat/abc2-123_x ABC2-123' 'feat/A-1-x -' 'feat/ABCDEFGHIJK-1-x -' 'feat/AB-1-x-CD-2 AB-1'; do
  read -r branch expected <<<"$pair"
  git -C "$fresh" checkout -q -B "$branch"
  [[ "$expected" != - ]] || expected=''
  assert_eq "ungated ${branch}" "$expected" "$(field "$fresh" ARTIFACT_LINEAR_HINT)"
done
git -C "$fresh" checkout -q --detach
assert_eq 'detached hint empty' '' "$(field "$fresh" ARTIFACT_LINEAR_HINT)"
no_git="${SCRATCH}/not git"; mkdir -p "$no_git"
printf 'scope: local\nstore: linear\n' >"${no_git}/.plans-config"
assert_eq 'no Git hint empty' '' "$(field "$no_git" ARTIFACT_LINEAR_HINT)"
# Gitignore writes only on first save, preserving existing bytes and wider rules.
for variant in missing no-newline exact slash rooted rooted-slash wider; do
  ignore_repo="${SCRATCH}/ignore-${variant}"; make_linear_repo "$ignore_repo"
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
negation_repo="${SCRATCH}/ignore-negation"; make_linear_repo "$negation_repo"
printf '.ycc/artifacts/*\n!.ycc/artifacts/feat/\n' >"${negation_repo}/.gitignore"
run "$negation_repo" ensure_artifact_gitignore
assert_eq 'negated exception gets repo coverage line' $'.ycc/artifacts/*\n!.ycc/artifacts/feat/\n.ycc/artifacts/' "$(cat "${negation_repo}/.gitignore")"
assert_ok 'nested probe ignored after append' git -C "$negation_repo" check-ignore -q -- .ycc/artifacts/feat/cache

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
  link_repo="${SCRATCH}/symlink-${link_kind}"; make_linear_repo "$link_repo"
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
global_ignore_repo="${SCRATCH}/global-ignore"; make_linear_repo "$global_ignore_repo"
printf '.ycc/\n' >"${SCRATCH}/global-excludes"
git config --file "${GIT_CONFIG_GLOBAL}.excludes" core.excludesFile "${SCRATCH}/global-excludes"
if (CDPATH='' cd -- "$global_ignore_repo" >/dev/null && GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL}.excludes" "$BASH_BIN" -c 'source "$1" || exit 1; ensure_artifact_gitignore' _ "$HELPER"); then
  fail 'global excludes unexpectedly accepted as repository ignore'
else
  pass 'global excludes rejected as repository ignore'
fi
assert_ok 'global excludes does not leave partial ignore' test ! -e "${global_ignore_repo}/.gitignore"
rm "${GIT_CONFIG_GLOBAL}.excludes"
info_ignore_repo="${SCRATCH}/info-ignore"; make_linear_repo "$info_ignore_repo"
printf '.ycc/\n' >"${info_ignore_repo}/.git/info/exclude"
if run "$info_ignore_repo" ensure_artifact_gitignore; then
  fail 'Git info excludes unexpectedly accepted as repository ignore'
else
  pass 'Git info excludes rejected as repository ignore'
fi
assert_ok 'Git info excludes does not leave partial ignore' test ! -e "${info_ignore_repo}/.gitignore"
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
path_repo="${SCRATCH}/artifact-paths"; make_repo "$path_repo"
printf 'scope: local\nplans_dir: custom plans\n' >"${path_repo}/.plans-config"
linear_base="${path_repo}/.ycc/artifacts/Feature_1"
local_base="${path_repo}/custom plans/Feature_1"
for pair in \
  "prd|${linear_base}/prd.md|${path_repo}/docs/prps/prds/Feature_1.prd.md" \
  "spec|${linear_base}/spec.md|${path_repo}/docs/prps/specs/Feature_1.spec.md" \
  "prp-plan|${linear_base}/prp-plan.md|${path_repo}/docs/prps/plans/Feature_1.plan.md" \
  "feature-spec|${linear_base}/feature-spec.md|${local_base}/feature-spec.md" \
  "parallel-plan|${linear_base}/parallel-plan.md|${local_base}/parallel-plan.md" \
  "shared|${linear_base}/shared.md|${local_base}/shared.md" \
  "report|${linear_base}/report.md|${local_base}/report.md" \
  "prp-report|${linear_base}/report.md|${path_repo}/docs/prps/reports/Feature_1-report.md" \
  "research-external|${linear_base}/research/research-external.md|${local_base}/research-external.md" \
  "research-deep-research|${linear_base}/research/research-deep-research.md|${local_base}/research-deep-research.md" \
  "analysis-context|${linear_base}/analysis-context.md|${local_base}/analysis-context.md" \
  "prp-research|${linear_base}/.prp-research|${path_repo}/docs/prps/plans/.prp-research/Feature_1" \
  "deep-research|${linear_base}/deep-research|-" \
  "blueprint|${linear_base}/blueprint.md|${path_repo}/docs/blueprint.md" \
  "research-dir|${linear_base}/research|${local_base}" \
  "feature-dir|${linear_base}|${local_base}"; do
  IFS='|' read -r kind linear_expected local_expected <<<"$pair"
  assert_eq "linear ${kind} sourced path" "$linear_expected" "$(CDPATH='' cd -- "$path_repo" >/dev/null && "$BASH_BIN" -c 'source "$1"; resolve_artifact_store --store=linear "$2" && get_artifact_path "$3" Feature_1' _ "$HELPER" "$path_repo" "$kind")"
  assert_eq "linear ${kind} CLI path" "$linear_expected" "$("$BASH_BIN" "$HELPER" --store=linear --kind="$kind" --slug=Feature_1 "$path_repo")"
  if [[ "$local_expected" == - ]]; then
    assert_bad 'local deep-research keeps its own output directory' run "$path_repo" get_artifact_path "$kind" Feature_1
    assert_eq 'local deep-research diagnostic' "ERROR: local mode keeps the skill's own output dir" "$(cat "${SCRATCH}/err")"
  else
    assert_eq "local ${kind} sourced path" "$local_expected" "$(run "$path_repo" get_artifact_path "$kind" Feature_1)"
    assert_eq "local ${kind} CLI path" "$local_expected" "$("$BASH_BIN" "$HELPER" --store=local --kind="$kind" --slug=Feature_1 "$path_repo")"
  fi
done
for bad_kind in '' unknown research- research-Upper research-bad_name analysis- analysis-Upper analysis-bad_name; do
  assert_bad "invalid kind '${bad_kind}'" run "$path_repo" get_artifact_path "$bad_kind" Feature_1
done
assert_bad 'artifact path missing kind' run "$path_repo" get_artifact_path
assert_bad 'artifact path missing slug' run "$path_repo" get_artifact_path prd
for slug in '' .. . -x ../bad bad/name 'white space'; do
  assert_bad "artifact path invalid slug '${slug}'" run "$path_repo" get_artifact_path prd "$slug"
done
assert_bad 'CLI kind requires slug' "$BASH_BIN" "$HELPER" --kind=prd "$path_repo"
assert_bad 'CLI slug requires kind' "$BASH_BIN" "$HELPER" --slug=Feature_1 "$path_repo"
assert_bad 'CLI rejects invalid kind before ensure' "$BASH_BIN" "$HELPER" --store=linear --ensure --kind=unknown --slug=Feature_1 "$path_repo"
assert_ok 'invalid CLI ensure creates no cache' test ! -e "${path_repo}/.ycc"
assert_bad 'CLI rejects local deep-research before ensure' "$BASH_BIN" "$HELPER" --store=local --ensure --kind=deep-research --slug=Feature_1 "$path_repo"
assert_ok 'local deep-research ensure creates no plans directory' test ! -e "${path_repo}/custom plans"
assert_eq 'CLI ensure returns linear path' "$linear_base" "$("$BASH_BIN" "$HELPER" --store=linear --ensure --kind=feature-dir --slug=Feature_1 "$path_repo")"
assert_ok 'CLI linear ensure creates cache' test -d "${path_repo}/.ycc/artifacts"
assert_ok 'CLI linear ensure ignores cache' git -C "$path_repo" check-ignore -q -- .ycc/artifacts/Feature_1/plan.md
assert_eq 'CLI ensure returns local path' "$local_base" "$("$BASH_BIN" "$HELPER" --store=local --ensure --kind=feature-dir --slug=Feature_1 "$path_repo")"
assert_ok 'CLI local ensure creates the feature directory' test -d "$local_base"
rm -rf "${path_repo}/custom plans"
"$BASH_BIN" "$HELPER" --store=local --kind=feature-dir --slug=Feature_1 "$path_repo" >/dev/null
assert_ok 'CLI path without ensure creates no feature directory' test ! -e "${path_repo}/custom plans"
# Local --ensure creates only the parent of the resolved file, never PLANS_DIR.
for kind in prd spec prp-plan prp-report blueprint; do
  "$BASH_BIN" "$HELPER" --store=local --ensure --kind="$kind" --slug=Feature_1 "$path_repo" >/dev/null
done
assert_ok 'local ensure prd leaves plans dir absent' test ! -e "${path_repo}/custom plans"
assert_ok 'local ensure prd creates docs/prps/prds' test -d "${path_repo}/docs/prps/prds"
assert_ok 'local ensure prp-plan creates docs/prps/plans' test -d "${path_repo}/docs/prps/plans"
assert_ok 'local ensure blueprint creates docs' test -d "${path_repo}/docs"
assert_ok 'local ensure creates no prd file' test ! -e "${path_repo}/docs/prps/prds/Feature_1.prd.md"
assert_ok 'local ensure prp-report creates reports parent' test -d "${path_repo}/docs/prps/reports"
assert_ok 'local ensure prp-report creates no file' test ! -e "${path_repo}/docs/prps/reports/Feature_1-report.md"
"$BASH_BIN" "$HELPER" --store=local --ensure --kind=report --slug=Feature_1 "$path_repo" >/dev/null
assert_ok 'local ensure report creates feature parent' test -d "$local_base"
assert_ok 'local ensure report creates no file' test ! -e "${local_base}/report.md"
for kind in report prp-report; do
  assert_eq "linear ensure ${kind} returns report path" "${linear_base}/report.md" "$("$BASH_BIN" "$HELPER" --store=linear --ensure --kind="$kind" --slug=Feature_1 "$path_repo")"
  assert_ok "linear ensure ${kind} creates no file" test ! -e "${linear_base}/report.md"
done
"$BASH_BIN" "$HELPER" --store=local --ensure --kind=shared --slug=Feature_1 "$path_repo" >/dev/null
assert_ok 'local ensure shared creates feature dir' test -d "$local_base"
assert_ok 'local ensure shared creates no file' test ! -e "${local_base}/shared.md"
"$BASH_BIN" "$HELPER" --store=local --ensure --kind=prp-research --slug=Feature_1 "$path_repo" >/dev/null
assert_ok 'local ensure prp-research creates the directory itself' test -d "${path_repo}/docs/prps/plans/.prp-research/Feature_1"
# Repo-level kinds follow the current checkout, not PLANS_ROOT (nested worktree).
wt_parent="${SCRATCH}/wt-parent"; make_repo "$wt_parent"
git -C "$wt_parent" add .plans-config; git -C "$wt_parent" commit -q -m cfg
wt_child="${wt_parent}/.worktrees/feat"
git -C "$wt_parent" worktree add -q -b wt-feat "$wt_child"
mkdir -p "${wt_child}/sub/dir"
for kind in prd spec prp-plan prp-report blueprint; do
  case "$kind" in
    prd) wt_rel="docs/prps/prds/foo.prd.md" ;;
    spec) wt_rel="docs/prps/specs/foo.spec.md" ;;
    prp-plan) wt_rel="docs/prps/plans/foo.plan.md" ;;
    prp-report) wt_rel="docs/prps/reports/foo-report.md" ;;
    blueprint) wt_rel="docs/blueprint.md" ;;
  esac
  assert_eq "worktree ${kind} resolves under worktree toplevel" "${wt_child}/${wt_rel}" "$("$BASH_BIN" "$HELPER" --store=local --kind="$kind" --slug=foo "${wt_child}/sub/dir")"
done
assert_eq 'worktree prp-research resolves under worktree toplevel' "${wt_child}/docs/prps/plans/.prp-research/foo" "$("$BASH_BIN" "$HELPER" --store=local --kind=prp-research --slug=foo "$wt_child")"
nogit_repo="${SCRATCH}/nogit-repo"; mkdir -p "$nogit_repo"
assert_eq 'non-git local prd resolves under start dir' "${nogit_repo}/docs/prps/prds/foo.prd.md" "$("$BASH_BIN" "$HELPER" --store=local --kind=prd --slug=foo "$nogit_repo")"
# get_artifact_path resolves lazily when the caller unset the exports.
assert_eq 'get_artifact_path resolves after exports are unset' "${path_repo}/custom plans/Feature_1/shared.md" "$(CDPATH='' cd -- "$path_repo" >/dev/null && "$BASH_BIN" -c 'source "$1"; unset ARTIFACT_DIR ARTIFACT_STORE ARTIFACT_ROOT; get_artifact_path shared Feature_1' _ "$HELPER")"
# get_plans_feature_dir keeps legacy local names and stays strict in linear mode.
assert_eq 'local feature dir accepts nested name' "${local_base%/Feature_1}/team/auth" "$(run "$path_repo" get_plans_feature_dir team/auth)"
assert_eq 'local feature dir accepts spaces' "${local_base%/Feature_1}/My Feature" "$(run "$path_repo" get_plans_feature_dir 'My Feature')"
for bad_name in '' .. ../x a/../b; do assert_bad "local feature dir rejects '${bad_name}'" run "$path_repo" get_plans_feature_dir "$bad_name"; done
assert_bad 'linear feature dir rejects spaces' "$BASH_BIN" -c 'source "$1"; resolve_artifact_store --store=linear "$2" && get_plans_feature_dir "My Feature"' _ "$HELPER" "$path_repo"
assert_eq 'linear feature dir uses cache' "${linear_base}" "$("$BASH_BIN" -c 'source "$1"; resolve_artifact_store --store=linear "$2" && get_plans_feature_dir Feature_1' _ "$HELPER" "$path_repo")"
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
