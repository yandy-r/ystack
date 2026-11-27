---
name: ycc-golang-coding-style
description: When working on Go files, apply formatting, types and idiomatic error
  handling. Applies to files matching **/*.go, **/go.mod, **/go.sum.
---

# Go Coding Style

## Formatting

- **gofmt** and **goimports** are mandatory — no style debates

## Design Principles

- Accept interfaces, return structs
- Keep interfaces small (1-3 methods)

## Error Handling

Always wrap errors with context:

```go
if err != nil {
    return fmt.Errorf("failed to create user: %w", err)
}
```

## Reference

See skill: `go-patterns` for comprehensive Go idioms and patterns.
