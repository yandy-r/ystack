#!/usr/bin/env bash
# Validate agent assignments and subtask structure
# Usage: validate-agents.sh

set -euo pipefail

echo "# Agent Assignment Validation"
echo ""

# List of all valid agent types from Agent tool
VALID_AGENTS=(
  "generalPurpose"
  "explore"
  "shell"
  "ansible-automation-expert"
  "api-docs-expert"
  "cloudflare-architect"
  "code-finder"
  "codebase-research-analyst"
  "db-modifier"
  "docs-git-committer"
  "documentation-writer"
  "frontend-ui-developer"
  "go-api-architect"
  "go-expert-architect"
  "implementor"
  "library-docs-writer"
  "nextjs-ux-ui-expert"
  "nodejs-backend-architect"
  "project-file-cleaner"
  "research-specialist"
  "reverse-proxy-architect"
  "root-cause-analyzer"
  "systems-engineering-expert"
  "terraform-architect"
  "test-strategy-planner"
  "sql-database-architect"
)

echo "## Valid Agent Types"
echo ""
echo "Total available agents: ${#VALID_AGENTS[@]}"
echo ""
echo "Categories:"
echo "- Code Discovery: explore, code-finder, codebase-research-analyst"
echo "- Frontend: frontend-ui-developer, nextjs-ux-ui-expert"
echo "- Backend: nodejs-backend-architect, go-api-architect, go-expert-architect"
echo "- Database: db-modifier, sql-database-architect"
echo "- Infrastructure: terraform-architect, cloudflare-architect, reverse-proxy-architect"
echo "- Documentation: documentation-writer, api-docs-expert, library-docs-writer"
echo "- Testing: test-strategy-planner, root-cause-analyzer"
echo "- DevOps: ansible-automation-expert, systems-engineering-expert"
echo "- General: generalPurpose, shell, implementor, research-specialist"
echo ""

# Function to check if agent type is valid
validate_agent_type() {
  local agent_type="$1"
  for valid_agent in "${VALID_AGENTS[@]}"; do
    if [[ "$agent_type" == "$valid_agent" ]]; then
      return 0
    fi
  done
  return 1
}

# If provided with agent types as arguments, validate them
if [[ $# -gt 0 ]]; then
  echo "## Validating Provided Agents"
  echo ""

  for agent in "$@"; do
    if validate_agent_type "$agent"; then
      echo "✓ $agent - Valid"
    else
      echo "✗ $agent - INVALID (not in agent catalog)"
    fi
  done
  echo ""
fi

echo "## Validation Guidelines"
echo ""
echo "Each subtask should have:"
echo "- Clear agent type assignment"
echo "- Non-overlapping scope with other subtasks"
echo "- Explicit dependencies (or 'none')"
echo "- Context files identified"
echo "- Expected outputs specified"
echo ""

exit 0
