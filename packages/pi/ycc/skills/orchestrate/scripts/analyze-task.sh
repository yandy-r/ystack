#!/usr/bin/env bash
# Analyze task description and suggest orchestration approach
# Usage: analyze-task.sh "task description"

set -euo pipefail

TASK_DESCRIPTION="${1:-}"

if [[ -z "$TASK_DESCRIPTION" ]]; then
  echo "ERROR: Task description required"
  echo "Usage: analyze-task.sh \"task description\""
  exit 1
fi

echo "# Task Analysis"
echo ""
echo "Task: $TASK_DESCRIPTION"
echo ""

# Convert to lowercase for keyword matching
TASK_LOWER=$(echo "$TASK_DESCRIPTION" | tr '[:upper:]' '[:lower:]')

# Complexity estimation
COMPLEXITY="Simple"
AGENT_COUNT=1

# Check for multiple concerns
if [[ "$TASK_LOWER" =~ (implement|create|build).*(test|doc|documentation) ]] || \
   [[ "$TASK_LOWER" =~ (frontend|backend|database) ]] || \
   [[ "$TASK_LOWER" =~ (and|with|including) ]]; then
  COMPLEXITY="Medium"
  AGENT_COUNT=3
fi

if [[ "$TASK_LOWER" =~ (across|all|multiple|entire|system-wide) ]] || \
   [[ "$TASK_LOWER" =~ (refactor|migrate|upgrade) ]]; then
  COMPLEXITY="Complex"
  AGENT_COUNT=5
fi

echo "## Complexity: $COMPLEXITY"
echo "Estimated agents needed: $AGENT_COUNT"
echo ""

# Suggest agent types based on keywords
echo "## Suggested Agent Types"
echo ""

if [[ "$TASK_LOWER" =~ (implement|create|build|add|develop) ]]; then
  echo "- Implementation agents needed"
  if [[ "$TASK_LOWER" =~ (ui|frontend|component|page) ]]; then
    echo "  - frontend-ui-developer or nextjs-ux-ui-expert"
  fi
  if [[ "$TASK_LOWER" =~ (api|backend|server|service) ]]; then
    echo "  - nodejs-backend-architect or go-api-architect"
  fi
  if [[ "$TASK_LOWER" =~ (database|db|schema|migration) ]]; then
    echo "  - db-modifier or sql-database-architect"
  fi
fi

if [[ "$TASK_LOWER" =~ (test|testing|spec) ]]; then
  echo "- test-strategy-planner for test planning"
fi

if [[ "$TASK_LOWER" =~ (doc|documentation|readme|guide) ]]; then
  echo "- documentation-writer or api-docs-expert"
fi

if [[ "$TASK_LOWER" =~ (bug|issue|fix|debug|investigate|error|failing) ]]; then
  echo "- root-cause-analyzer for diagnosis"
fi

if [[ "$TASK_LOWER" =~ (refactor|restructure|reorganize) ]]; then
  echo "- codebase-research-analyst for analysis"
  echo "- Multiple implementation agents for refactoring"
fi

if [[ "$TASK_LOWER" =~ (infrastructure|terraform|cloud|deploy) ]]; then
  echo "- terraform-architect or cloudflare-architect"
fi

if [[ "$TASK_LOWER" =~ (ansible|automation|provision) ]]; then
  echo "- ansible-automation-expert"
fi

echo ""

# Execution mode recommendation
echo "## Recommended Execution Mode"
echo ""

if [[ "$TASK_LOWER" =~ (sequential|step.*step|order) ]]; then
  echo "Sequential (use --sequential flag)"
  echo "Reason: Task suggests ordered execution"
elif [[ "$TASK_LOWER" =~ (debug|investigate|diagnose|analyze) ]]; then
  echo "Sequential (use --sequential flag)"
  echo "Reason: Investigative work benefits from sequential analysis"
else
  echo "Parallel (default)"
  echo "Reason: Multiple independent concerns detected"
fi

echo ""

# Decomposition suggestions
echo "## Suggested Decomposition Approach"
echo ""

if [[ "$TASK_LOWER" =~ (implement|create|build) ]]; then
  echo "Decompose by:"
  echo "1. Core implementation"
  echo "2. Testing strategy"
  echo "3. Documentation"
fi

if [[ "$TASK_LOWER" =~ (refactor|migrate|upgrade) ]]; then
  echo "Decompose by:"
  echo "1. Analysis and planning"
  echo "2. Individual components/modules"
  echo "3. Integration and validation"
fi

if [[ "$TASK_LOWER" =~ (bug|fix|debug) ]]; then
  echo "Decompose by:"
  echo "1. Root cause analysis"
  echo "2. Fix implementation"
  echo "3. Test verification"
  echo "4. Documentation update"
fi

if [[ "$TASK_LOWER" =~ (doc|documentation) ]]; then
  echo "Decompose by:"
  echo "1. API documentation"
  echo "2. Feature guides"
  echo "3. Architecture documentation"
fi

exit 0
