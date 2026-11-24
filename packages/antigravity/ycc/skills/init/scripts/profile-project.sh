#!/usr/bin/env bash
# profile-project.sh
# Detect project characteristics and emit key=value pairs on stdout.
#
# Usage: profile-project.sh [path]
#   path  Optional directory to profile (defaults to $PWD).
#
# Output: one key=value per line, machine-readable, no shell quoting.
# Python detection needs Python 3.11+ (tomllib); shell entrypoint is Bash 3.2-compatible.
# Requires python3 3.11+ for every stack. Errors stay visible on stderr.
# Exit codes: 0 = success, 1 = argument error (bad/missing path).

set -euo pipefail

# ---------------------------------------------------------------------------
# Python 3.11+ guard: runs before any profiling so an unsupported interpreter
# aborts with a readable message and no partial key=value output.
# ---------------------------------------------------------------------------
_pp_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SHARED_SEG="/_shared/scripts"; _SHARED_SEG_FLAT="/shared/scripts"; _SHARED_SEG_AGENTS="/ycc-shared/scripts"
_pp_shared=""
for _pp_cand in "${_pp_script_dir}/../..${_SHARED_SEG}" \
                "${_pp_script_dir}/../../..${_SHARED_SEG_FLAT}" \
                "${_pp_script_dir}/../../..${_SHARED_SEG_AGENTS}"; do
  if [[ -f "${_pp_cand}/require-python.sh" ]]; then
    _pp_shared="$_pp_cand"
    break
  fi
done
if [[ -z "$_pp_shared" ]]; then
  echo "[profile-project] ERROR: shared require-python.sh not found (broken ycc install)" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "${_pp_shared}/require-python.sh"

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
if [[ $# -gt 1 ]]; then
    echo "[profile-project] ERROR: too many arguments. Usage: profile-project.sh [path]" >&2
    exit 1
fi

target="${1:-$PWD}"

if [[ ! -d "$target" ]]; then
    echo "[profile-project] ERROR: directory not found: ${target}" >&2
    exit 1
fi

# Resolve to absolute path without relying on realpath (POSIX-friendly)
project_root="$(cd "$target" && pwd)"
if [[ "$project_root" == *$'\n'* || "$project_root" == *$'\r'* ]]; then
    echo "[profile-project] ERROR: newline in repository path cannot be represented in key=value output" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
file_exists() { [[ -f "${project_root}/${1}" ]]; }
dir_exists()  { [[ -d "${project_root}/${1}" ]]; }

# Check for glob match at project root (non-recursive, one level)
glob_exists_root() {
    local pattern="$1"
    local match
    match=$(find "$project_root" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | head -n 1)
    [[ -n "$match" ]]
}

# ---------------------------------------------------------------------------
# is_empty detection
# ---------------------------------------------------------------------------
# True iff no tracked source files AND no lockfile/manifest is present.
# We check non-dotfile entries and then git tracked file count.
is_empty=false

# Count non-dot entries at the root
non_dot_count=$(find "$project_root" -maxdepth 1 -not -name ".*" -not -path "$project_root" 2>/dev/null | wc -l | tr -d ' ')

if [[ "$non_dot_count" -eq 0 ]]; then
    is_empty=true
else
    # If git is present, check tracked file count; otherwise fall through.
    if dir_exists ".git" || git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1; then
        tracked=$(git -C "$project_root" ls-files 2>/dev/null | wc -l | tr -d ' ')
        # No tracked files AND no manifest means empty
        has_manifest=false
        for m in Cargo.toml go.mod package.json pyproject.toml requirements.txt; do
            file_exists "$m" && { has_manifest=true; break; }
        done
        glob_exists_root "*.tf" && has_manifest=true
        if [[ "$tracked" -eq 0 && "$has_manifest" == "false" ]]; then
            is_empty=true
        fi
    fi
fi

# ---------------------------------------------------------------------------
# has_git
# ---------------------------------------------------------------------------
has_git=false
if dir_exists ".git" || git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1; then
    has_git=true
fi

# ---------------------------------------------------------------------------
# Language + package manager detection
# ---------------------------------------------------------------------------
primary_language=unknown
secondary_languages=none
package_manager=unknown
test_cmd=unknown
lint_cmd=unknown
build_cmd=unknown

# Track multiple detected stacks for mixed-language handling
detected_langs=()
detected_pms=()

# --- Rust ---
if file_exists "Cargo.toml"; then
    detected_langs+=(rust)
    detected_pms+=(cargo)
fi

# --- Go ---
if file_exists "go.mod"; then
    detected_langs+=(go)
    detected_pms+=(go)
fi

# --- Node / TypeScript / JavaScript ---
if file_exists "package.json"; then
    # Determine package manager from lockfile priority
    node_pm=npm
    if file_exists "pnpm-lock.yaml"; then
        node_pm=pnpm
    elif file_exists "bun.lock" || file_exists "bun.lockb"; then
        node_pm=bun
    elif file_exists "yarn.lock"; then
        node_pm=yarn
    fi

    if file_exists "tsconfig.json"; then
        detected_langs+=(typescript)
    else
        detected_langs+=(javascript)
    fi
    detected_pms+=("$node_pm")
fi

# --- Python (pyproject.toml) ---
if file_exists "pyproject.toml"; then
    detected_langs+=(python)
    py_pm=pip
    if file_exists "uv.lock"; then
        py_pm=uv
    elif file_exists "poetry.lock"; then
        py_pm=poetry
    elif grep -q '\[tool\.hatch\]' "${project_root}/pyproject.toml" 2>/dev/null; then
        py_pm=hatch
    fi
    detected_pms+=("$py_pm")
elif file_exists "requirements.txt"; then
    # Only if pyproject.toml is absent
    detected_langs+=(python)
    detected_pms+=(pip)
fi

# --- Terraform ---
if glob_exists_root "*.tf"; then
    detected_langs+=(terraform)
    detected_pms+=(terraform)
fi

# ---------------------------------------------------------------------------
# Resolve primary vs secondary
# ---------------------------------------------------------------------------
lang_count="${#detected_langs[@]}"

if [[ "$lang_count" -eq 0 ]]; then
    primary_language=unknown
    secondary_languages=none
    package_manager=unknown
elif [[ "$lang_count" -eq 1 ]]; then
    primary_language="${detected_langs[0]}"
    secondary_languages=none
    package_manager="${detected_pms[0]}"
else
    primary_language=mixed
    # First detected becomes primary stack reference; list all in secondary
    package_manager="${detected_pms[0]}"
    secondary_languages=$(IFS=,; echo "${detected_langs[*]}")
fi

# ---------------------------------------------------------------------------
# Resolve test / lint / build commands based on primary stack
# (for mixed, use the first detected stack)
# ---------------------------------------------------------------------------
primary_stack="${detected_langs[0]:-unknown}"
primary_pm="${detected_pms[0]:-unknown}"

# Helper: resolve node pm commands
node_pm_cmd() {
    local pm="$1"
    local subcmd="$2"
    case "$pm" in
        pnpm) echo "pnpm $subcmd" ;;
        bun)  echo "bun $subcmd" ;;
        yarn) echo "yarn $subcmd" ;;
        *)    echo "npm $subcmd" ;;
    esac
}

case "$primary_stack" in
    rust)
        test_cmd="cargo test"
        lint_cmd="cargo clippy --all-targets"
        build_cmd="cargo build"
        ;;
    go)
        test_cmd="go test ./..."
        lint_cmd="go vet ./..."
        for cfg in .golangci.yml .golangci.yaml .golangci.toml .golangci.json; do
            file_exists "$cfg" && { lint_cmd="golangci-lint run"; break; }
        done
        build_cmd="go build ./..."
        ;;
    typescript|javascript)
        # Only stamp commands backed by actual package.json scripts (read-only check).
        if ! command -v jq >/dev/null 2>&1; then
            echo "[profile-project] WARN: jq is unavailable; JS/TS commands cannot be detected" >&2
        fi
        if jq -e '.scripts.test | type == "string" and length > 0' "${project_root}/package.json" >/dev/null 2>&1; then
            test_cmd="$(node_pm_cmd "$primary_pm" "test")"
        fi
        if jq -e '.scripts | (has("lint") or has("lint:check"))' "${project_root}/package.json" >/dev/null 2>&1; then
            for key in lint lint:check; do
                if jq -e --arg k "$key" '.scripts[$k] | type == "string" and length > 0' "${project_root}/package.json" >/dev/null 2>&1; then
                    lint_cmd="$(node_pm_cmd "$primary_pm" "run $key")"
                    break
                fi
            done
        fi
        if jq -e '.scripts.build | type == "string" and length > 0' "${project_root}/package.json" >/dev/null 2>&1; then
            build_cmd="$(node_pm_cmd "$primary_pm" "run build")"
        fi
        ;;
    python)
        # Parse manifest/requirements without matching comments or unrelated words;
        # a bare tests/ directory may be unittest, so check for pytest config/conftest.
        py_runner=""
        case "$primary_pm" in
            uv|poetry) py_runner="$primary_pm run " ;;
        esac
        read -r has_pytest has_ruff has_build < <(python3 - "$project_root" <<'PYEOF'
import re
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
manifest = root / "pyproject.toml"
try:
    data = tomllib.loads(manifest.read_bytes().decode("utf-8-sig")) if manifest.exists() else {}
except (ValueError, OSError) as exc:
    print(f"[profile-project] WARN: cannot parse pyproject.toml: {exc}", file=sys.stderr)
    data = {}
project = data.get("project", {})
deps = list(project.get("dependencies", []))
for group in project.get("optional-dependencies", {}).values():
    deps.extend(group)
for group in data.get("dependency-groups", {}).values():
    deps.extend(item for item in group if isinstance(item, str))
poetry = data.get("tool", {}).get("poetry", {})
deps.extend(poetry.get("dependencies", {}).keys())
for group in poetry.get("group", {}).values():
    deps.extend(group.get("dependencies", {}).keys())
for name in ("requirements.txt", "requirements-dev.txt", "requirements-test.txt"):
    path = root / name
    if path.is_file():
        deps.extend(line.split("#", 1)[0].strip() for line in path.read_bytes().decode("utf-8-sig").splitlines())

def has_dep(pkg: str) -> bool:
    return any(re.match(r"^" + re.escape(pkg) + r"(?:$|[\[\s><=!~;])", item, re.I)
               for item in deps if isinstance(item, str))

tools = data.get("tool", {})
pytest_ok = (
    has_dep("pytest") or "pytest" in tools
    or any((root / n).is_file() for n in ("pytest.ini", ".pytest.ini", "conftest.py", "tests/conftest.py"))
)
ruff_ok = (
    has_dep("ruff") or "ruff" in tools
    or any((root / n).is_file() for n in ("ruff.toml", ".ruff.toml"))
)
build_ok = "build-system" in data
print(int(pytest_ok), int(ruff_ok), int(build_ok))
PYEOF
        )
       [[ "$has_pytest" == "1" ]] && test_cmd="${py_runner}pytest"
        [[ "$has_ruff" == "1" ]] && lint_cmd="${py_runner}ruff check ."
        if [[ "$has_build" == "1" ]]; then
            case "$primary_pm" in
                uv|poetry|hatch) build_cmd="$primary_pm build" ;;
                *) build_cmd="python -m build" ;;
            esac
        fi
        ;;
    terraform)
        test_cmd="terraform validate"
        lint_cmd="terraform fmt -check"
        build_cmd="terraform plan"
        ;;
    *)
        test_cmd=unknown
        lint_cmd=unknown
        build_cmd=unknown
        ;;
esac

# ---------------------------------------------------------------------------
# Contextual checks
# ---------------------------------------------------------------------------
has_github_dir=false
dir_exists ".github" && has_github_dir=true

has_cursor_rules=false
if dir_exists ".cursor/rules" || file_exists ".cursorrules"; then
    has_cursor_rules=true
fi

has_legacy_cursorrules=false
file_exists ".cursorrules" && has_legacy_cursorrules=true

has_modern_cursor_rules=false
dir_exists ".cursor/rules" && has_modern_cursor_rules=true

has_claude_md=false
file_exists "CLAUDE.md" && has_claude_md=true

has_agents_md=false
file_exists "AGENTS.md" && has_agents_md=true

# Query the shared canonical parser before emitting any profile output.
# Capture its status directly (not through a pipeline) so read errors abort.
rules_profile="$("${_pp_shared}/rules-pointer.sh" profile --repo "$project_root")"
agents_md_is_pointer=false
claude_md_imports_agents=false
while IFS='=' read -r key value; do
    case "$key" in
        agents_md_is_pointer) agents_md_is_pointer="$value" ;;
        claude_md_imports_agents) claude_md_imports_agents="$value" ;;
    esac
done <<<"$rules_profile"

has_issue_templates=false
if dir_exists ".github/ISSUE_TEMPLATE"; then
    tmpl_count=$(find "${project_root}/.github/ISSUE_TEMPLATE" -maxdepth 1 \( -name "*.yml" -o -name "*.yaml" -o -name "*.md" \) 2>/dev/null | wc -l | tr -d ' ')
    [[ "$tmpl_count" -gt 0 ]] && has_issue_templates=true
fi

has_pr_template=false
if file_exists ".github/pull_request_template.md" || file_exists "pull_request_template.md" || file_exists "docs/pull_request_template.md"; then
    has_pr_template=true
fi

has_gitmessage=false
file_exists ".gitmessage" && has_gitmessage=true

has_gitignore=false
file_exists ".gitignore" && has_gitignore=true

has_commitlint_config=false
for f in commitlint.config.cjs commitlint.config.js commitlint.config.mjs commitlint.config.ts .commitlintrc .commitlintrc.json .commitlintrc.yml; do
    if file_exists "$f"; then
        has_commitlint_config=true
        break
    fi
done

has_lefthook_config=false
for f in lefthook.yml lefthook.yaml .lefthook.yml .lefthook.yaml; do
    if file_exists "$f"; then
        has_lefthook_config=true
        break
    fi
done
if [[ "$has_lefthook_config" == "false" ]] && dir_exists ".lefthook"; then
    has_lefthook_config=true
fi

# A repo-root RELEASING.md means the project already follows a ycc release
# model; init then skips the ycc:release-model offer.
has_releasing_md=false
file_exists "RELEASING.md" && has_releasing_md=true

# Artifact-store pointer: parse the first root store key like the resolver:
# strip comments, trim spaces/tabs, then one matching quote pair. Preserve CR
# so a CRLF value is invalid rather than disagreeing with store resolution.
artifact_store=none
if file_exists ".plans-config"; then
    _as_re='^store[[:space:]]*[:=]'
    while IFS= read -r _as_line || [[ -n "$_as_line" ]]; do
	if [[ "$_as_line" =~ $_as_re ]]; then
	    _as_value=${_as_line#*[:=]}
	    _as_value=${_as_value%%#*}
	    _as_value="${_as_value#"${_as_value%%[!$' \t']*}"}"
	    _as_value="${_as_value%"${_as_value##*[!$' \t']}"}"
	    case "$_as_value" in
		\"*\") _as_value=${_as_value#\"}; _as_value=${_as_value%\"} ;;
		\'*\') _as_value=${_as_value#\'}; _as_value=${_as_value%\'} ;;
	    esac
	    case "$_as_value" in
		linear) artifact_store=linear ;;
		local) artifact_store=local ;;
	    esac
	    break
	fi
    done < "${project_root}/.plans-config"
fi

# ---------------------------------------------------------------------------
# CI provider detection
# ---------------------------------------------------------------------------
ci_provider=none

if dir_exists ".github/workflows"; then
    # Confirm there is at least one yaml file
    yml_count=$(find "${project_root}/.github/workflows" -maxdepth 1 \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null | wc -l | tr -d ' ')
    [[ "$yml_count" -gt 0 ]] && ci_provider=github-actions
fi

if [[ "$ci_provider" == "none" ]] && file_exists ".gitlab-ci.yml"; then
    ci_provider=gitlab-ci
fi

if [[ "$ci_provider" == "none" ]] && file_exists ".circleci/config.yml"; then
    ci_provider=circleci
fi

# ---------------------------------------------------------------------------
# project_name
# ---------------------------------------------------------------------------
project_name=$(basename "$project_root")

# ---------------------------------------------------------------------------
# Emit output
# ---------------------------------------------------------------------------
echo "project_root=${project_root}"
echo "is_empty=${is_empty}"
echo "has_git=${has_git}"
echo "primary_language=${primary_language}"
echo "secondary_languages=${secondary_languages}"
echo "package_manager=${package_manager}"
echo "test_cmd=${test_cmd}"
echo "lint_cmd=${lint_cmd}"
echo "build_cmd=${build_cmd}"
echo "has_github_dir=${has_github_dir}"
echo "has_cursor_rules=${has_cursor_rules}"
echo "has_legacy_cursorrules=${has_legacy_cursorrules}"
echo "has_modern_cursor_rules=${has_modern_cursor_rules}"
echo "has_claude_md=${has_claude_md}"
echo "has_agents_md=${has_agents_md}"
echo "agents_md_is_pointer=${agents_md_is_pointer}"
echo "claude_md_imports_agents=${claude_md_imports_agents}"
echo "has_issue_templates=${has_issue_templates}"
echo "has_pr_template=${has_pr_template}"
echo "has_gitmessage=${has_gitmessage}"
echo "has_gitignore=${has_gitignore}"
echo "has_commitlint_config=${has_commitlint_config}"
echo "has_lefthook_config=${has_lefthook_config}"
echo "has_releasing_md=${has_releasing_md}"
echo "artifact_store=${artifact_store}"
echo "ci_provider=${ci_provider}"
echo "project_name=${project_name}"
