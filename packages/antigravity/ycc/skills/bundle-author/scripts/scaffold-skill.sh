#!/usr/bin/env bash
# scaffold-skill.sh — Scaffold a new skill in ycc/skills/<skill-name>/.
#
# Skills are directly slash-invocable by default. --skill-only marks passive
# guidance with user-invocable: false. No wrapper commands are created.
#
# Usage: scaffold-skill.sh <skill-name> [--skill-only] [--with-agent]
#
# Exit codes:
#   0 - Scaffolding completed successfully
#   1 - Invalid arguments, name validation failure, or collision detected

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

SKILL_NAME=""
SKILL_ONLY=0
WITH_AGENT=0

usage() {
    cat <<EOF
Usage: scaffold-skill.sh <skill-name> [--skill-only] [--with-agent]

Scaffold a directly invocable skill in ycc/skills/<skill-name>/. Optionally
create an agent under ycc/agents/<skill-name>.md.
Templates are read from ycc/skills/bundle-author/references/templates/.

Options:
  --skill-only     Stamp 'user-invocable: false' into the skill frontmatter.
                   Use only for passive guidance hidden from the slash menu.
  --with-command   Legacy no-op; skills are directly invocable by default
  --with-agent     Also create ycc/agents/<skill-name>.md
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skill-only)
            SKILL_ONLY=1
            shift
            ;;
        --with-command)
            # Legacy no-op; never overrides --skill-only.
            shift
            ;;
        --with-agent)
            WITH_AGENT=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "scaffold-skill.sh: unknown flag: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -n "${SKILL_NAME}" ]]; then
                echo "scaffold-skill.sh: unexpected argument: $1" >&2
                usage >&2
                exit 1
            fi
            SKILL_NAME="$1"
            shift
            ;;
    esac
done

# Validate skill name is provided
if [[ -z "${SKILL_NAME}" ]]; then
    echo "scaffold-skill.sh: missing required argument: <skill-name>" >&2
    usage >&2
    exit 1
fi

# Validate skill name format
if ! [[ "${SKILL_NAME}" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]]; then
    echo "scaffold-skill.sh: invalid skill name '${SKILL_NAME}'" >&2
    echo "  Must match: ^[a-z][a-z0-9]*(-[a-z0-9]+)*\$" >&2
    exit 1
fi

# Collision checks
[[ -e "${REPO_ROOT}/ycc/skills/${SKILL_NAME}" ]] && {
    echo "scaffold-skill.sh: refuse: ycc/skills/${SKILL_NAME} already exists" >&2
    exit 1
}

if [[ "${WITH_AGENT}" -eq 1 ]]; then
    [[ -e "${REPO_ROOT}/ycc/agents/${SKILL_NAME}.md" ]] && {
        echo "scaffold-skill.sh: refuse: ycc/agents/${SKILL_NAME}.md already exists" >&2
        exit 1
    }
fi

# Verify templates directory exists
TEMPLATES_DIR="${REPO_ROOT}/ycc/skills/bundle-author/references/templates"
[[ -d "${TEMPLATES_DIR}" ]] || {
    echo "scaffold-skill.sh: missing templates dir: ${TEMPLATES_DIR}" >&2
    exit 1
}

# Default description placeholder
DESC="TODO: one-line description for ${SKILL_NAME}"

# Passive skills stay available to the model, but not the slash menu.
if [[ "${SKILL_ONLY}" -eq 1 ]]; then
    INVOCATION_OPT_OUT="user-invocable: false"$'\n'
else
    INVOCATION_OPT_OUT=""
fi

# Helper: render a template with NAME, DESCRIPTION, and INVOCATION_OPT_OUT substitutions.
# INVOCATION_OPT_OUT is a multi-line-capable value, so use a Python helper rather than sed.
render() {
    local src="$1"
    local dst="$2"
    local name="$3"
    local desc="$4"
    local opt_out="${5:-}"
    NAME="$name" DESCRIPTION="$desc" INVOCATION_OPT_OUT="$opt_out" \
        python3 -c '
import os, sys
text = open(sys.argv[1], encoding="utf-8").read()
for key in ("NAME", "DESCRIPTION", "INVOCATION_OPT_OUT"):
    text = text.replace("{{" + key + "}}", os.environ.get(key, ""))
open(sys.argv[2], "w", encoding="utf-8").write(text)
' "$src" "$dst"
}

# Create skill directory and render SKILL.md
mkdir -p "${REPO_ROOT}/ycc/skills/${SKILL_NAME}"
render \
    "${TEMPLATES_DIR}/skill-template.md" \
    "${REPO_ROOT}/ycc/skills/${SKILL_NAME}/SKILL.md" \
    "${SKILL_NAME}" \
    "${DESC}" \
    "${INVOCATION_OPT_OUT}"
echo "${REPO_ROOT}/ycc/skills/${SKILL_NAME}/SKILL.md"

# Optionally render agent stub
if [[ "${WITH_AGENT}" -eq 1 ]]; then
    render \
        "${TEMPLATES_DIR}/agent-template.md" \
        "${REPO_ROOT}/ycc/agents/${SKILL_NAME}.md" \
        "${SKILL_NAME}" \
        "${DESC}"
    echo "${REPO_ROOT}/ycc/agents/${SKILL_NAME}.md"
fi

exit 0
