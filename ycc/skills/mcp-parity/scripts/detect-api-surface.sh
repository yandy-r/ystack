#!/usr/bin/env bash
# detect-api-surface.sh — list the capability surfaces of a repository.
#
# Usage: detect-api-surface.sh [repo-root]
#
# Prints tab-separated `KIND<TAB>VALUE` lines on stdout, one per finding:
#   LANG       detected language/ecosystem (node, python, go, rust, java, ruby, php, dotnet)
#   SPEC       machine-readable contract file (openapi, graphql, proto, asyncapi)
#   ROUTES     source file that registers HTTP routes or RPC handlers
#   CLI        source file that defines CLI commands
#   MCP        source file that already uses an MCP server SDK
#   MCP_CONFIG MCP config/manifest file
# Hints only: research agents must still read the code. Vendored, generated and
# dependency directories are skipped. Exit 0 on success (even with no findings),
# 1 on bad input.
set -euo pipefail

root="${1:-.}"
if [[ ! -d "$root" ]]; then
  printf 'detect-api-surface: not a directory: %s\n' "$root" >&2
  exit 1
fi
root="$(CDPATH='' cd -- "$root" >/dev/null && pwd -P)"

# A caller's GIT_DIR/GIT_WORK_TREE (git hooks export them) would point `git -C` at
# another repository; scan the target directory's own repository instead.
if command -v git >/dev/null 2>&1; then
  while IFS= read -r git_var; do unset "$git_var"; done < <(git rev-parse --local-env-vars 2>/dev/null || true)
fi

MAX_HITS="${MCP_PARITY_MAX_HITS:-200}"
if [[ ! "$MAX_HITS" =~ ^[0-9]+$ ]] || ((MAX_HITS < 1)); then
  printf 'detect-api-surface: MCP_PARITY_MAX_HITS must be a positive integer\n' >&2
  exit 1
fi

# List candidate files relative to root. Prefer git (respects .gitignore).
list_files() {
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" -c core.quotePath=false ls-files --cached --others --exclude-standard
  else
    (cd "$root" && find . -type f -not -path '*/.git/*' | sed 's|^\./||')
  fi | grep -Ev '(^|/)(node_modules|vendor|dist|build|target|\.venv|venv|__pycache__|\.next|coverage|\.ycc|\.claude|\.codex|\.cursor|\.opencode|\.omp)/' || true
}

FILES="$(list_files)"

emit() { printf '%s\t%s\n' "$1" "$2"; }

# Language markers (root and up to two directories deep, for monorepos).
declare -A LANG_MARKERS=(
  [package.json]=node [pyproject.toml]=python [requirements.txt]=python [setup.py]=python
  [go.mod]=go [Cargo.toml]=rust [pom.xml]=java [build.gradle]=java [build.gradle.kts]=java
  [Gemfile]=ruby [composer.json]=php
)
seen_langs=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  base="${f##*/}"
  depth="${f//[^\/]/}"
  ((${#depth} <= 2)) || continue
  lang="${LANG_MARKERS[$base]:-}"
  [[ -z "$lang" && "$base" == *.csproj ]] && lang=dotnet
  if [[ -n "$lang" && " $seen_langs " != *" $lang "* ]]; then
    seen_langs="$seen_langs $lang"
    emit LANG "$lang"
  fi
done <<<"$FILES"

# Contract specs by name/extension.
printf '%s\n' "$FILES" | grep -Ei '(^|/)(openapi|swagger)[^/]*\.(ya?ml|json)$|\.(graphql|gql|proto)$|(^|/)schema\.graphqls?$|(^|/)asyncapi[^/]*\.(ya?ml|json)$' \
  | sed -n "1,${MAX_HITS}p" | while IFS= read -r f; do emit SPEC "$f"; done || true

SOURCE_RE='\.(ts|tsx|js|mjs|cjs|py|go|rs|java|kt|rb|php|cs)$'
sources="$(printf '%s\n' "$FILES" | grep -E "$SOURCE_RE" | grep -Ev '(^|/)(test|tests|__tests__|spec|testdata|fixtures)/|\.(test|spec)\.|_test\.(go|py)$|(^|/)test_[^/]*\.py$' || true)"

# Search file contents, printing each matching file once (bounded).
grep_files() {
  local label=$1 pattern=$2 hits count
  [[ -n "$sources" ]] || return 0
  hits="$(printf '%s\n' "$sources" | (cd "$root" && tr '\n' '\0' | xargs -0 grep -lIE -- "$pattern" 2>/dev/null) || true)"
  [[ -n "$hits" ]] || return 0
  count="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
  if ((count > MAX_HITS)); then
    printf 'detect-api-surface: %s: showing %s of %s files (raise MCP_PARITY_MAX_HITS)\n' "$label" "$MAX_HITS" "$count" >&2
  fi
  # sed, not head: head exits early and SIGPIPE would abort under pipefail.
  printf '%s\n' "$hits" | sed -n "1,${MAX_HITS}p" | while IFS= read -r f; do emit "$label" "$f"; done
}

ROUTE_RE='\b(app|router|server|fastify|r|e|g|mux|http|api|bp|blueprint|group|v[0-9])\.(get|post|put|patch|delete|route|add_api_route|handle|Handle|HandleFunc|Get|Post|Put|Patch|Delete|GET|POST|PUT|PATCH|DELETE)\(|^export (async )?function (GET|POST|PUT|PATCH|DELETE)\b|@(app|router|api|bp)\.(get|post|put|patch|delete|route)\(|@(Get|Post|Put|Patch|Delete|RequestMapping|GetMapping|PostMapping|PutMapping|DeleteMapping|Controller|RestController)\b|\b(createTRPCRouter|publicProcedure|protectedProcedure)\b|#\[(get|post|put|patch|delete)\(|\bRoute::(get|post|put|patch|delete)\(|\bresources? :[a-z_]+|\burlpatterns\b|\bRegister[A-Za-z]+Server\('
CLI_RE="(from|require\\()[[:space:]]*['\"](commander|yargs|cac|citty|@oclif/core)['\"]|\\bclick\\.(command|group)\\b|\\btyper\\.Typer\\b|\\bargparse\\.ArgumentParser\\b|github\\.com/spf13/cobra|github\\.com/urfave/cli|\\bclap::(Parser|Command)\\b|#\\[derive\\([^)]*Parser"
MCP_RE='@modelcontextprotocol/sdk|\bfrom mcp(\.server)?\b|\bimport mcp\b|\bFastMCP\b|mark3labs/mcp-go|modelcontextprotocol/go-sdk|\brmcp\b|McpServer|io\.modelcontextprotocol'

grep_files ROUTES "$ROUTE_RE"
grep_files CLI "$CLI_RE"
grep_files MCP "$MCP_RE"

printf '%s\n' "$FILES" | grep -Ei '(^|/)(\.mcp\.json|mcp\.json|server\.json|smithery\.ya?ml|mcp-server[^/]*\.(json|ya?ml))$' \
  | sed -n "1,${MAX_HITS}p" | while IFS= read -r f; do emit MCP_CONFIG "$f"; done || true

exit 0
