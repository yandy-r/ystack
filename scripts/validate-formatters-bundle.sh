#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_ROOT="${REPO_ROOT}/ycc/skills/formatters/scripts/bundle"
PROFILE_SCRIPT="${REPO_ROOT}/ycc/skills/formatters/scripts/profile-style.sh"
STYLE_SCRIPT="${BUNDLE_ROOT}/style.sh"

# Git hooks (pre-push) export GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE. Every
# fixture below is a throwaway directory that must be judged on its own — with
# those inherited, git resolves them against the host repository instead, so the
# non-git fixtures look like work trees and enumerate the wrong file list.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "validate-formatters-bundle: ${message}: expected '${expected}', got '${actual}'" >&2
    exit 1
  fi
}

read_profile_value() {
  local profile_file="$1"
  local key="$2"
  awk -F= -v target="$key" '$1 == target { print $2 }' "$profile_file"
}

assert_package_deps() {
  local package_json="$1"
  local expect_prettier="$2"
  python3 - "$package_json" "$expect_prettier" <<'PY'
import json, sys
path, expect_prettier = sys.argv[1], sys.argv[2] == "true"
data = json.load(open(path, encoding="utf-8"))
deps = data.get("devDependencies", {})

assert deps.get("@biomejs/biome") == "2.3.11", deps
assert deps.get("typescript") == "^5.6.3", deps

has_prettier = "prettier" in deps
has_markdownlint = "markdownlint-cli" in deps
if expect_prettier:
    assert has_prettier and has_markdownlint, deps
else:
    assert not has_prettier and not has_markdownlint, deps
PY
}

tmp_root="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

# The non-git fixtures below rely on tmp_root NOT living inside a git work tree
# (otherwise profile-style.sh would enumerate via the parent repo's git index).
# Fail loudly rather than silently mis-test if TMPDIR points inside a repo.
if git -C "$tmp_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "validate-formatters-bundle: TMPDIR ($tmp_root) is inside a git work tree; set TMPDIR to a non-repo path." >&2
  exit 1
fi

python3 - "${REPO_ROOT}/scripts/style.sh" "${BUNDLE_ROOT}/style.sh" <<'PY'
import re, sys

def extract(path: str) -> list[str]:
    text = open(path, encoding="utf-8").read()
    match = re.search(r'BUNDLE_MANAGED_FILES=\(\n(.*?)\n\)', text, re.S)
    if not match:
        raise SystemExit(f"validate-formatters-bundle: could not parse BUNDLE_MANAGED_FILES from {path}")
    return re.findall(r'"([^"]+)"', match.group(1))

root_files = extract(sys.argv[1])
bundle_files = extract(sys.argv[2])
if root_files != bundle_files:
    raise SystemExit(
        "validate-formatters-bundle: root scripts/style.sh managed files are out of sync with source-of-truth bundle"
    )
PY

ts_auto_dir="${tmp_root}/ts-auto"
mkdir -p "${ts_auto_dir}/src"
cat > "${ts_auto_dir}/package.json" <<'EOF'
{
  "name": "ts-auto",
  "private": true
}
EOF
cat > "${ts_auto_dir}/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "strict": true
  },
  "include": ["src"]
}
EOF
cat > "${ts_auto_dir}/src/main.ts" <<'EOF'
export const value = 1;
EOF

ts_auto_profile="${tmp_root}/ts-auto.profile"
"${PROFILE_SCRIPT}" "${ts_auto_dir}" > "${ts_auto_profile}"
assert_eq "$(read_profile_value "${ts_auto_profile}" detect_ts)" "true" "ts-auto detect_ts"
assert_eq "$(read_profile_value "${ts_auto_profile}" detect_docs)" "false" "ts-auto detect_docs"

pkg_docs_dir="${tmp_root}/pkg-docs"
mkdir -p "${pkg_docs_dir}"
cat > "${pkg_docs_dir}/package.json" <<'EOF'
{
  "name": "pkg-docs",
  "private": true
}
EOF
cat > "${pkg_docs_dir}/config.json" <<'EOF'
{
  "name": "pkg-docs"
}
EOF

pkg_docs_profile="${tmp_root}/pkg-docs.profile"
"${PROFILE_SCRIPT}" "${pkg_docs_dir}" > "${pkg_docs_profile}"
assert_eq "$(read_profile_value "${pkg_docs_profile}" detect_ts)" "false" "pkg-docs detect_ts"
assert_eq "$(read_profile_value "${pkg_docs_profile}" detect_docs)" "true" "pkg-docs detect_docs"

ts_scaffold_dir="${tmp_root}/ts-scaffold"
mkdir -p "${ts_scaffold_dir}"
"${STYLE_SCRIPT}" init --copy --yes --target "${ts_scaffold_dir}" --ts >/dev/null
assert_package_deps "${ts_scaffold_dir}/package.json" "false"
test ! -f "${ts_scaffold_dir}/.prettierrc" || {
  echo "validate-formatters-bundle: TS-only scaffold should not create .prettierrc" >&2
  exit 1
}

ts_docs_scaffold_dir="${tmp_root}/ts-docs-scaffold"
mkdir -p "${ts_docs_scaffold_dir}"
"${STYLE_SCRIPT}" init --copy --yes --target "${ts_docs_scaffold_dir}" --ts --docs >/dev/null
assert_package_deps "${ts_docs_scaffold_dir}/package.json" "true"
test -f "${ts_docs_scaffold_dir}/.prettierrc" || {
  echo "validate-formatters-bundle: TS+docs scaffold should create .prettierrc" >&2
  exit 1
}
test -f "${ts_docs_scaffold_dir}/.markdownlint.json" || {
  echo "validate-formatters-bundle: TS+docs scaffold should create .markdownlint.json" >&2
  exit 1
}

docs_json_dir="${tmp_root}/docs-json"
mkdir -p "${docs_json_dir}"
cat > "${docs_json_dir}/config.json" <<'EOF'
{
  "name": "docs-json"
}
EOF

docs_json_profile="${tmp_root}/docs-json.profile"
"${PROFILE_SCRIPT}" "${docs_json_dir}" > "${docs_json_profile}"
assert_eq "$(read_profile_value "${docs_json_profile}" detect_ts)" "false" "docs-json detect_ts"
assert_eq "$(read_profile_value "${docs_json_profile}" detect_docs)" "true" "docs-json detect_docs"

templates_dir="${tmp_root}/templates-docs"
mkdir -p "${templates_dir}/scripts/templates"
cat > "${templates_dir}/scripts/templates/readme.md" <<'EOF'
# Template docs
EOF

template_paths="$(
  PROJECT_ROOT="${templates_dir}" \
  bash -lc '. "'"${BUNDLE_ROOT}"'/lib/modified-files.sh"; list_repo_paths "" ".md"'
)"
if ! printf '%s\n' "${template_paths}" | grep -Fq "${templates_dir}/scripts/templates/readme.md"; then
  echo "validate-formatters-bundle: scripts/templates/readme.md should remain lintable when user-authored" >&2
  exit 1
fi

# --- git-mode detection is ignore-aware: stray source under gitignored / nested
#     vendored dirs must NOT flip detect_* (the reported false-positive bug). ---
git_vendored_dir="${tmp_root}/git-vendored"
mkdir -p "${git_vendored_dir}/src" \
  "${git_vendored_dir}/node_modules/pkg" \
  "${git_vendored_dir}/dist/dev" \
  "${git_vendored_dir}/packages/app/node_modules"
git -C "${git_vendored_dir}" init -q
printf 'node_modules/\ndist/\n' > "${git_vendored_dir}/.gitignore"
printf 'export const v = 1;\n' > "${git_vendored_dir}/src/main.ts"
printf 'fn main() {}\n' > "${git_vendored_dir}/node_modules/pkg/fixture.rs"
printf 'print(1)\n' > "${git_vendored_dir}/dist/dev/gen.py"
printf 'print(2)\n' > "${git_vendored_dir}/packages/app/node_modules/dep.py"
printf '{ "name": "git-vendored", "private": true }\n' > "${git_vendored_dir}/package.json"
git -C "${git_vendored_dir}" add -A >/dev/null 2>&1

git_vendored_profile="${tmp_root}/git-vendored.profile"
"${PROFILE_SCRIPT}" "${git_vendored_dir}" > "${git_vendored_profile}"
assert_eq "$(read_profile_value "${git_vendored_profile}" detect_ts)" "true" "git-vendored detect_ts"
assert_eq "$(read_profile_value "${git_vendored_profile}" detect_rust)" "false" "git-vendored detect_rust (node_modules/*.rs must not count)"
assert_eq "$(read_profile_value "${git_vendored_profile}" detect_python)" "false" "git-vendored detect_python (gitignored + nested node_modules/*.py must not count)"

# --- git-mode: generic-word dirs (env/) match root-relative only, so a tracked
#     NESTED env/ source dir is still detected (no over-exclusion regression). ---
git_env_dir="${tmp_root}/git-env"
mkdir -p "${git_env_dir}/src/env"
git -C "${git_env_dir}" init -q
printf 'ENV = 1\n' > "${git_env_dir}/src/env/settings.py"
git -C "${git_env_dir}" add -A >/dev/null 2>&1

git_env_profile="${tmp_root}/git-env.profile"
"${PROFILE_SCRIPT}" "${git_env_dir}" > "${git_env_profile}"
assert_eq "$(read_profile_value "${git_env_profile}" detect_python)" "true" "git-env detect_python (tracked nested env/*.py must still count)"

# --- user excludes: a COMMITTED, non-gitignored vendored tree is dropped from
#     detection and linting via .style-excludes / STYLE_EXTRA_EXCLUDES. ---
user_ex_dir="${tmp_root}/user-excludes"
mkdir -p "${user_ex_dir}/src" "${user_ex_dir}/config/data/trash" "${user_ex_dir}/third_party"
git -C "${user_ex_dir}" init -q
printf 'export const v = 1;\n' > "${user_ex_dir}/src/main.ts"
printf 'print(1)\n' > "${user_ex_dir}/config/data/trash/gen.py"
printf 'fn main() {}\n' > "${user_ex_dir}/third_party/lib.rs"
printf '# vendored reference data\n./config/data/trash/  # trailing comment\n\n' > "${user_ex_dir}/.style-excludes"
git -C "${user_ex_dir}" add -A >/dev/null 2>&1

user_ex_profile="${tmp_root}/user-excludes.profile"
STYLE_EXTRA_EXCLUDES="third_party:nope" "${PROFILE_SCRIPT}" "${user_ex_dir}" > "${user_ex_profile}"
assert_eq "$(read_profile_value "${user_ex_profile}" detect_python)" "false" "user-excludes detect_python (.style-excludes entry)"
assert_eq "$(read_profile_value "${user_ex_profile}" detect_rust)" "false" "user-excludes detect_rust (STYLE_EXTRA_EXCLUDES entry)"
assert_eq "$(read_profile_value "${user_ex_profile}" detect_ts)" "true" "user-excludes detect_ts"

# A '#' inside an entry is part of the path, not a comment.
printf 'print(3)\n' > "${user_ex_dir}/a#b.py"
printf 'a#b.py\n' > "${user_ex_dir}/.style-excludes"
user_ex_hash_paths="$(
  PROJECT_ROOT="${user_ex_dir}" \
  bash -c '. "'"${BUNDLE_ROOT}"'/lib/modified-files.sh"; style_load_extra_excludes "$PROJECT_ROOT"; list_repo_paths ""'
)"
assert_eq "$(printf '%s\n' "${user_ex_hash_paths}" | grep -c 'a#b.py' || true)" "0" "user-excludes keeps '#' inside entries"
printf '# vendored reference data\n./config/data/trash/  # trailing comment\n\n' > "${user_ex_dir}/.style-excludes"

user_ex_paths="$(
  PROJECT_ROOT="${user_ex_dir}" \
  bash -c '. "'"${BUNDLE_ROOT}"'/lib/modified-files.sh"; style_load_extra_excludes "$PROJECT_ROOT"; list_repo_paths ""'
)"
assert_eq "$(printf '%s\n' "${user_ex_paths}" | grep -c 'config/data/trash' || true)" "0" "user-excludes linting drops .style-excludes paths"
assert_eq "$(printf '%s\n' "${user_ex_paths}" | grep -c 'src/main.ts' || true)" "1" "user-excludes linting keeps project source"

# --- symlinks: tools (notably Prettier) reject explicitly named symlinks, so
#     they never reach a lint file list. The skip is silent only when the
#     resolved target is a tracked path this same filter includes; otherwise it
#     must warn on stderr so unlinted targets stay visible. ---
git_link_dir="${tmp_root}/git-symlink"
mkdir -p "${git_link_dir}"
git -C "${git_link_dir}" init -q
printf '# real\n' > "${git_link_dir}/real.md"
ln -s real.md "${git_link_dir}/link.md"
printf '# untracked\n' > "${git_link_dir}/untracked.md"
ln -s untracked.md "${git_link_dir}/link-untracked.md"
printf '# outside\n' > "${tmp_root}/outside-target.md"
ln -s ../outside-target.md "${git_link_dir}/link-outside.md"
git -C "${git_link_dir}" add real.md link.md link-untracked.md link-outside.md

git_link_stdout="${tmp_root}/git-symlink.stdout"
git_link_stderr="${tmp_root}/git-symlink.stderr"
PROJECT_ROOT="${git_link_dir}" \
  bash -c '. "'"${BUNDLE_ROOT}"'/lib/modified-files.sh"; list_repo_paths "" ".md"' \
  > "${git_link_stdout}" 2> "${git_link_stderr}"

if ! grep -Fq "${git_link_dir}/real.md" "${git_link_stdout}"; then
  echo "validate-formatters-bundle: symlinked repo should still list the real target" >&2
  exit 1
fi
if grep -Fq "${git_link_dir}/link.md" "${git_link_stdout}"; then
  echo "validate-formatters-bundle: tracked symlink must not appear on a lint file list" >&2
  exit 1
fi
if ! grep -Fq 'skipping symlink link-untracked.md' "${git_link_stderr}"; then
  echo "validate-formatters-bundle: symlink to untracked target should warn on stderr" >&2
  exit 1
fi
if ! grep -Fq 'skipping symlink link-outside.md' "${git_link_stderr}"; then
  echo "validate-formatters-bundle: symlink to out-of-repo target should warn on stderr" >&2
  exit 1
fi
if grep -Fq 'skipping symlink link.md' "${git_link_stderr}"; then
  echo "validate-formatters-bundle: tracked-and-linted symlink target should skip silently" >&2
  exit 1
fi

# --- CI template contract: lint-autofix.yml keeps PR code away from the App token. ---
"${SCRIPT_DIR}/test-formatters-autofix-template.sh" >/dev/null || {
  echo "validate-formatters-bundle: test-formatters-autofix-template.sh failed" >&2
  exit 1
}

echo "OK: formatter bundle smoke checks passed."
