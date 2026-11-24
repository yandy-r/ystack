---
trigger: glob
description: When working on Go files, apply test organization, framework usage and
  failure verification.
globs: '**/*.go,**/go.mod,**/go.sum'
---

# Go Testing

Use the `go-testing` skill for detailed guidance.
Run `go test -race ./...` to detect concurrency defects.
