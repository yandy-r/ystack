#!/usr/bin/env bash
# Consolidate and summarize orchestration results
# Usage: summarize-results.sh

set -euo pipefail

echo "# Orchestration Results Summary"
echo ""
echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

echo "## Summary Template"
echo ""
echo "Use this template to organize agent outputs:"
echo ""

cat <<'EOF'
# Orchestration Complete: [Task Name]

## Execution Summary

- **Total Subtasks**: [count]
- **Completed**: [count]
- **Failed**: [count]
- **Execution Batches**: [count]
- **Total Agents Deployed**: [count]
- **Total Duration**: [time estimate]

## Results by Agent

### Batch 1: Independent Tasks

#### [Agent Type 1] - [Subtask 1]
**Status**: ✓ Success / ✗ Failed / ⚠ Partial

**Outputs**:
- Files Created: [list]
- Files Modified: [list]
- Key Changes: [summary]

**Notes**: [observations, warnings, recommendations]

---

#### [Agent Type 2] - [Subtask 2]
**Status**: ✓ Success / ✗ Failed / ⚠ Partial

**Outputs**:
- Files Created: [list]
- Files Modified: [list]
- Key Changes: [summary]

**Notes**: [observations, warnings, recommendations]

---

### Batch 2: Dependent Tasks

#### [Agent Type 3] - [Subtask 3]
**Status**: ✓ Success / ✗ Failed / ⚠ Partial

**Dependencies**: [list of completed subtasks]

**Outputs**:
- Files Created: [list]
- Files Modified: [list]
- Key Changes: [summary]

**Notes**: [observations, warnings, recommendations]

---

## Consolidated File Changes

### Files Created
- `/path/to/new/file1.ext` - [brief description]
- `/path/to/new/file2.ext` - [brief description]
- `/path/to/new/file3.ext` - [brief description]

### Files Modified
- `/path/to/modified/file1.ext` - [what changed]
- `/path/to/modified/file2.ext` - [what changed]
- `/path/to/modified/file3.ext` - [what changed]

### Files Deleted
- `/path/to/deleted/file1.ext` - [reason]

## Integration Status

Check these integration points:

- [ ] No conflicting changes between agents
- [ ] All cross-references valid
- [ ] Consistent patterns and conventions used
- [ ] Dependencies properly integrated
- [ ] Documentation reflects code changes
- [ ] Tests cover new functionality

**Integration Issues Found**: [list or "None"]

## Failed Subtasks

If any subtasks failed, document them:

### [Subtask Name]
- **Agent**: [agent type]
- **Reason**: [why it failed]
- **Impact**: [what couldn't be completed]
- **Resolution**: [how to fix or next steps]

## Quality Checks

- [ ] Linting errors checked on modified files
- [ ] Build/compilation verified (if applicable)
- [ ] Tests run (if applicable)
- [ ] Documentation updated to match code
- [ ] Security considerations addressed
- [ ] Performance implications considered

## Recommendations

Based on the orchestration results:

1. [Recommendation 1]
2. [Recommendation 2]
3. [Recommendation 3]

## Next Steps

1. Review all changed files in your editor
2. Test the integrated functionality
3. Address any failed subtasks:
   - [Specific action 1]
   - [Specific action 2]
4. Run full test suite to verify
5. Commit changes when satisfied
6. Update project documentation if needed

## Additional Notes

[Any other observations, learnings, or important context]

---

**Orchestration Pattern Used**: [Feature Implementation / Bug Investigation / Refactoring / Documentation / Other]

**Success Rate**: [X/Y tasks completed successfully] ([percentage]%)
EOF

echo ""
echo "## Usage"
echo ""
echo "The orchestrator should:"
echo "1. Collect outputs from each agent as they complete"
echo "2. Fill in this template with actual results"
echo "3. Verify integration between agent outputs"
echo "4. Provide actionable next steps"
echo ""

exit 0
