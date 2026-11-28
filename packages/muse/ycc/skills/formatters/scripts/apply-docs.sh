#!/usr/bin/env bash
# apply-docs.sh
# Render the "Linting & Formatting" section from readme-section.md.tmpl and
# append or replace it in the highest-precedence docs file:
#   README.md  >  CONTRIBUTING.md  >  AGENTS.md  >  AGENTS.md
#
# Usage: apply-docs.sh --target <dir> --profile-file <path>
#                      [--template-dir <dir>] [--dry-run] [--force]

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DEFAULT_TEMPLATE_DIR="${SCRIPT_DIR}/../references/templates"

target=""
profile_file=""
template_dir="$DEFAULT_TEMPLATE_DIR"
dry_run=false
force=false

usage() {
    cat >&2 <<'EOF'
Usage: apply-docs.sh --target <dir> --profile-file <path>
                     [--template-dir <dir>] [--dry-run] [--force]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)         target="$2"; shift 2 ;;
        --target=*)       target="${1#*=}"; shift ;;
        --profile-file)   profile_file="$2"; shift 2 ;;
        --profile-file=*) profile_file="${1#*=}"; shift ;;
        --template-dir)   template_dir="$2"; shift 2 ;;
        --template-dir=*) template_dir="${1#*=}"; shift ;;
        --dry-run)        dry_run=true; shift ;;
        --force)          force=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "[apply-docs] ERROR: unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

[[ -z "$target" ]]         && { echo "[apply-docs] ERROR: --target is required" >&2; exit 1; }
[[ -z "$profile_file" ]]   && { echo "[apply-docs] ERROR: --profile-file is required" >&2; exit 1; }
[[ ! -d "$target" ]]       && { echo "[apply-docs] ERROR: target not a directory: $target" >&2; exit 1; }
[[ ! -f "$profile_file" ]] && { echo "[apply-docs] ERROR: profile file missing: $profile_file" >&2; exit 1; }

target="$(cd "$target" && pwd)"
tpl="$template_dir/readme-section.md.tmpl"
[[ ! -f "$tpl" ]] && { echo "[apply-docs] ERROR: template missing: $tpl" >&2; exit 1; }

info() { echo "[apply-docs] $*"; }

# ---------------------------------------------------------------------------
# Resolve docs target (precedence: README > CONTRIBUTING > AGENTS > CLAUDE)
# ---------------------------------------------------------------------------
docs_target=""
for candidate in README.md readme.md CONTRIBUTING.md AGENTS.md AGENTS.md; do
    if [[ -f "$target/$candidate" ]]; then
        docs_target="$target/$candidate"
        break
    fi
done

created_fresh=false
if [[ -z "$docs_target" ]]; then
    docs_target="$target/README.md"
    created_fresh=true
fi

# ---------------------------------------------------------------------------
# Render + apply via a single Python invocation (safer than nested heredocs)
# ---------------------------------------------------------------------------
export APPLY_DOCS_TARGET_FILE="$docs_target"
export APPLY_DOCS_TEMPLATE="$tpl"
export APPLY_DOCS_PROFILE="$profile_file"
export APPLY_DOCS_DRY_RUN="$dry_run"
export APPLY_DOCS_FORCE="$force"
export APPLY_DOCS_CREATED_FRESH="$created_fresh"

python3 <<'PYEOF'
import os
import re
import sys
from pathlib import Path

tpl_path = Path(os.environ["APPLY_DOCS_TEMPLATE"])
dest_path = Path(os.environ["APPLY_DOCS_TARGET_FILE"])
profile_path = Path(os.environ["APPLY_DOCS_PROFILE"])
dry_run = os.environ["APPLY_DOCS_DRY_RUN"] == "true"
force = os.environ["APPLY_DOCS_FORCE"] == "true"
created_fresh = os.environ["APPLY_DOCS_CREATED_FRESH"] == "true"

# Load profile key=value pairs
profile = {}
for line in profile_path.read_text(encoding="utf-8").splitlines():
    if "=" not in line:
        continue
    k, _, v = line.partition("=")
    profile[k.strip()] = v.strip()

def pflag(key, default="false"):
    return profile.get(key, default) == "true"

pkg_mgr = profile.get("package_manager", "") or "npm"
if pkg_mgr == "none":
    pkg_mgr = "npm"

flags = {
    "IF_PACKAGE_JSON":         pflag("has_package_json"),
    "IF_MAKEFILE":             pflag("has_makefile"),
    "IF_JUSTFILE":             pflag("has_justfile"),
    "IF_RUST":                 pflag("detect_rust"),
    "IF_GO":                   pflag("detect_go"),
    "IF_TS":                   pflag("detect_ts"),
    "IF_PYTHON":               pflag("detect_python"),
    "IF_DOCS":                 pflag("detect_docs"),
    "IF_SHELL":                pflag("detect_shell"),
    "IF_CI_INSTALLED":         pflag("has_lint_workflow"),
    "IF_CI_NOT_INSTALLED":     not pflag("has_lint_workflow"),
    "IF_HOOKS_INSTALLED":      pflag("has_lefthook") or pflag("has_husky"),
    "IF_HOOKS_NOT_INSTALLED":  not (pflag("has_lefthook") or pflag("has_husky")),
}

text = tpl_path.read_text(encoding="utf-8")

def strip_block(match):
    name = match.group(1)
    body = match.group(2)
    return body if flags.get(name, False) else ""

block_pat = re.compile(r"\{\{#(\w+)\}\}(.*?)\{\{/\1\}\}", re.DOTALL)
text = block_pat.sub(strip_block, text)
text = text.replace("{{PACKAGE_MANAGER}}", pkg_mgr)
text = re.sub(r"\n{3,}", "\n\n", text)
rendered = text.strip() + "\n"

# Fresh-create path
if created_fresh:
    if dry_run:
        print(f"[apply-docs] [dry-run] would create {dest_path} with rendered section")
        sys.exit(0)
    dest_path.write_text(
        f"# {dest_path.parent.name}\n\n{rendered}",
        encoding="utf-8",
    )
    print(f"[apply-docs] created {dest_path}")
    sys.exit(0)

# Existing-file path: append-or-replace
existing = dest_path.read_text(encoding="utf-8")
heading_re = re.compile(r"^## +Linting ?& ?Formatting\s*$", re.MULTILINE)
match = heading_re.search(existing)

if match is None:
    if dry_run:
        print(f"[apply-docs] [dry-run] would append ## Linting & Formatting to {dest_path}")
        sys.exit(0)
    sep = ""
    if not existing.endswith("\n"):
        sep = "\n"
    if not existing.endswith("\n\n"):
        sep += "\n"
    dest_path.write_text(existing + sep + rendered, encoding="utf-8")
    print(f"[apply-docs] appended section to {dest_path}")
    sys.exit(0)

if not force:
    action = "would skip" if dry_run else "skipping"
    print(f"[apply-docs] {action}: section already present in {dest_path} (pass --force to replace)")
    sys.exit(0)

start = match.start()
after = existing[match.end():]
next_hdr = re.search(r"^## ", after, re.MULTILINE)
end = match.end() + (next_hdr.start() if next_hdr else len(after))
new_text = existing[:start] + rendered + existing[end:]

if dry_run:
    print(f"[apply-docs] [dry-run] would replace section in {dest_path}")
    sys.exit(0)

dest_path.write_text(new_text, encoding="utf-8")
print(f"[apply-docs] replaced section in {dest_path}")
PYEOF

exit 0
