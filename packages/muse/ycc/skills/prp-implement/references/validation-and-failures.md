# PRP Validation and Failures

## Contents

- Levels 1–5
- Handling Failures

## Levels 1–5

Run all validation levels from the plan. Fix issues at each level before proceeding.

### Level 1: Static Analysis

```bash
# Type checking — zero errors required
[project type-check command]

# Linting — fix automatically where possible
[project lint command]
[project lint-fix command]
```

If lint errors remain after auto-fix, fix manually.

### Level 2: Unit Tests

Write tests for every new function (as specified in the plan's Testing Strategy).

```bash
[project test command for affected area]
```

- Every function needs at least one test
- Cover edge cases listed in the plan
- If a test fails → fix the implementation (not the test, unless the test is wrong)

### Level 3: Build Check

```bash
[project build command]
```

Build must succeed with zero errors.

### Level 4: Integration Testing (if applicable)

```bash
# Start server, run tests, stop server
[project dev server command] &
SERVER_PID=$!

# Wait for server to be ready (adjust port as needed)
SERVER_READY=0
for i in $(seq 1 30); do
  if curl -sf http://localhost:PORT/health >/dev/null 2>&1; then
    SERVER_READY=1
    break
  fi
  sleep 1
done

if [ "$SERVER_READY" -ne 1 ]; then
  kill "$SERVER_PID" 2>/dev/null || true
  echo "ERROR: Server failed to start within 30s" >&2
  exit 1
fi

[integration test command]
TEST_EXIT=$?

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

exit "$TEST_EXIT"
```

### Level 5: Edge Case Testing

Run through edge cases from the plan's Testing Strategy checklist.

**CHECKPOINT**: All 5 validation levels pass. Zero errors.

## Handling Failures

### Type Check Fails

1. Read the error message carefully
2. Fix the type error in the source file
3. Re-run type-check
4. Continue only when clean

### Tests Fail

1. Identify whether the bug is in the implementation or the test
2. Fix the root cause (usually the implementation)
3. Re-run tests
4. Continue only when green

### Lint Fails

1. Run auto-fix first
2. If errors remain, fix manually
3. Re-run lint
4. Continue only when clean

### Build Fails

1. Usually a type or import issue — check error message
2. Fix the offending file
3. Re-run build
4. Continue only when successful

### Integration Test Fails

1. Check server started correctly
2. Verify endpoint/route exists
3. Check request format matches expected
4. Fix and re-run
