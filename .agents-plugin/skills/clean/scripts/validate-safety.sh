#!/usr/bin/env bash
#
# Safety Validation Script
# Validates that proposed file removals don't include protected files or directories
#
# Usage: validate-safety.sh [cleanup-report-path]
#
# Exit codes:
#   0 - All safety checks passed
#   1 - Protected files/directories detected
#   2 - Path validation failed
#   3 - Symbolic link issue
#   4 - Abnormal file count/size
#   5 - Emergency stop condition
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get cleanup report path from argument
REPORT_PATH="${1:-}"

if [[ -z "$REPORT_PATH" ]]; then
    echo -e "${RED}Error: No cleanup report path provided${NC}" >&2
    echo "Usage: $0 [cleanup-report-path]" >&2
    exit 1
fi

if [[ ! -f "$REPORT_PATH" ]]; then
    echo -e "${RED}Error: Report file not found: $REPORT_PATH${NC}" >&2
    exit 1
fi

# Get the target directory from report or use directory containing report
REPORT_DIR=$(dirname "$REPORT_PATH")
TARGET_DIR=$(dirname "$REPORT_DIR")

echo "Validating cleanup safety..."
echo "Report: $REPORT_PATH"
echo "Target Directory: $TARGET_DIR"
echo ""

# Initialize counters
VIOLATIONS=0
WARNINGS=0

# Function to log violation
log_violation() {
    echo -e "${RED}✗ VIOLATION: $1${NC}"
    VIOLATIONS=$((VIOLATIONS + 1))
}

# Function to log warning
log_warning() {
    echo -e "${YELLOW}⚠ WARNING: $1${NC}"
    WARNINGS=$((WARNINGS + 1))
}

# Function to log success
log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Protected directories list
declare -a PROTECTED_DIRS=(
    ".git"
    ".svn"
    ".hg"
    "node_modules"
    ".venv"
    "venv"
    "env"
    "vendor"
    ".pnpm"
    ".yarn"
    "__pycache__"
    "dist"
    "build"
    "out"
    ".next"
    "target"
    ".idea"
    ".vscode"
    ".claude"
    ".cursor"
    "logs"
    "data"
    "uploads"
)

# Protected files list
declare -a PROTECTED_FILES=(
    ".gitignore"
    ".gitattributes"
    "package.json"
    "package-lock.json"
    "yarn.lock"
    "pnpm-lock.yaml"
    "go.mod"
    "go.sum"
    "Cargo.toml"
    "Cargo.lock"
    "requirements.txt"
    "setup.py"
    "pyproject.toml"
    "Dockerfile"
    "docker-compose.yml"
    "docker-compose.yaml"
    ".dockerignore"
    "README.md"
    "LICENSE"
    "LICENSE.md"
    "Makefile"
    ".editorconfig"
)

# Security-sensitive patterns
declare -a SECURITY_PATTERNS=(
    "*.key"
    "*.pem"
    "*.p12"
    "*.pfx"
    "*.crt"
    "id_rsa"
    "id_ed25519"
    "credentials.json"
    "secrets.json"
)

echo "=========================================="
echo "Safety Check 1: Protected Directories"
echo "=========================================="

# Extract file paths from report (simplified - looks for markdown file path patterns)
FLAGGED_FILES=$(grep -E '^\|.*\|.*\|.*\|' "$REPORT_PATH" | grep -v '^|---' | grep -v '^| File Path' | cut -d'|' -f2 | tr -d ' ' | grep -v '^$' || true)
# FLAGGED_FILES is matched with here-strings, not `echo | grep -q`: under
# pipefail an early-exiting reader SIGPIPEs the echo writer and a present
# entry reads as missing (YAN-1587).

protected_dir_violations=0
for dir in "${PROTECTED_DIRS[@]}"; do
    if grep -q "/$dir/\|^$dir/" <<<"$FLAGGED_FILES"; then
        log_violation "Protected directory found in removal list: $dir"
        ((protected_dir_violations+=1))
    fi
done

if [[ $protected_dir_violations -eq 0 ]]; then
    log_success "No protected directories in removal list"
fi

echo ""
echo "=========================================="
echo "Safety Check 2: Protected Files"
echo "=========================================="

protected_file_violations=0
for file in "${PROTECTED_FILES[@]}"; do
    if grep -qE "(^|/)$file$" <<<"$FLAGGED_FILES"; then
        log_violation "Protected file found in removal list: $file"
        ((protected_file_violations+=1))
    fi
done

if [[ $protected_file_violations -eq 0 ]]; then
    log_success "No protected files in removal list"
fi

echo ""
echo "=========================================="
echo "Safety Check 3: Path Validation"
echo "=========================================="

path_violations=0

# Check that all paths are within target directory
while IFS= read -r filepath; do
    if [[ -z "$filepath" ]]; then
        continue
    fi

    # Skip if it's a header or separator
    if [[ "$filepath" =~ ^[-#*] ]]; then
        continue
    fi

    # Construct full path
    if [[ "$filepath" = /* ]]; then
        full_path="$filepath"
    else
        full_path="$TARGET_DIR/$filepath"
    fi

    # Check if path is within target directory
    real_target=$(cd "$TARGET_DIR" && pwd) || true

    if [[ -e "$full_path" ]]; then
        real_path=$(cd "$(dirname "$full_path")" && pwd)/$(basename "$full_path") || true
        if [[ ! "$real_path" =~ ^"$real_target" ]]; then
            log_violation "Path outside target directory: $filepath"
            ((path_violations+=1))
        fi
    fi
done <<< "$FLAGGED_FILES"

if [[ $path_violations -eq 0 ]]; then
    log_success "All paths are within target directory"
fi

echo ""
echo "=========================================="
echo "Safety Check 4: Symbolic Links"
echo "=========================================="

symlink_violations=0

while IFS= read -r filepath; do
    if [[ -z "$filepath" ]]; then
        continue
    fi

    # Skip headers
    if [[ "$filepath" =~ ^[-#*] ]]; then
        continue
    fi

    # Construct full path
    if [[ "$filepath" = /* ]]; then
        full_path="$filepath"
    else
        full_path="$TARGET_DIR/$filepath"
    fi

    # Check if it's a symbolic link
    if [[ -L "$full_path" ]]; then
        # Get link target
        link_target=$(readlink "$full_path" || true)

        # Check if target is outside project
        if [[ "$link_target" = /* ]] && [[ ! "$link_target" =~ ^"$TARGET_DIR" ]]; then
            log_warning "Symbolic link points outside project: $filepath -> $link_target"
            ((symlink_violations+=1))
        fi
    fi
done <<< "$FLAGGED_FILES"

if [[ $symlink_violations -eq 0 ]]; then
    log_success "No problematic symbolic links detected"
fi

echo ""
echo "=========================================="
echo "Safety Check 5: File Count Reasonableness"
echo "=========================================="

file_count=$(echo "$FLAGGED_FILES" | grep -v '^$' | wc -l)

if [[ $file_count -gt 1000 ]]; then
    log_violation "Excessive file count: $file_count files (threshold: 1000)"
    log_violation "This may indicate a misconfiguration"
elif [[ $file_count -gt 500 ]]; then
    log_warning "High file count: $file_count files (consider reviewing)"
else
    log_success "File count reasonable: $file_count files"
fi

echo ""
echo "=========================================="
echo "Safety Check 6: Security-Sensitive Files"
echo "=========================================="

security_issues=0

for pattern in "${SECURITY_PATTERNS[@]}"; do
    # Convert glob pattern to grep pattern
    grep_pattern=$(echo "$pattern" | sed 's/\*/.*/')

    if grep -qE "$grep_pattern" <<<"$FLAGGED_FILES"; then
        log_warning "Security-sensitive file pattern detected: $pattern"
        ((security_issues+=1))
    fi
done

if [[ $security_issues -eq 0 ]]; then
    log_success "No security-sensitive files detected"
else
    log_warning "Found $security_issues security-sensitive file patterns - review carefully"
fi

echo ""
echo "=========================================="
echo "Safety Check 7: Emergency Stop Conditions"
echo "=========================================="

emergency_stops=0

# Check if .git exists (is this a real project?)
if [[ ! -d "$TARGET_DIR/.git" ]]; then
    log_warning "No .git directory found - might not be a version-controlled project"
fi

# Check if target is root directory
if [[ "$TARGET_DIR" == "/" ]] || [[ "$TARGET_DIR" == "$HOME" ]]; then
    log_violation "EMERGENCY STOP: Target directory is root or home directory!"
    ((emergency_stops+=1))
fi

# Check total size (if du is available)
if command -v du &> /dev/null; then
    total_size_line=$(grep -i "total size\|space.*recover" "$REPORT_PATH" | head -1 || true)

    if grep -qi "GB" <<<"$total_size_line"; then
        size_value=$(grep -oP '\d+\.?\d*(?=\s*GB)' <<<"$total_size_line" | head -1 || echo "0")
        if (( $(echo "$size_value > 10" | bc -l) )); then
            log_warning "Large total size detected: ${size_value}GB - verify this is correct"
        fi
    fi
fi

if [[ $emergency_stops -eq 0 ]]; then
    log_success "No emergency stop conditions detected"
fi

echo ""
echo "=========================================="
echo "Safety Check 8: Project-Specific Rules"
echo "=========================================="

# Check for .cleanupignore
if [[ -f "$TARGET_DIR/.cleanupignore" ]]; then
    echo "Found .cleanupignore file - checking custom protections..."

    while IFS= read -r protected_item; do
        if [[ "$protected_item" =~ ^#.*$ ]] || [[ -z "$protected_item" ]]; then
            continue
        fi

        if grep -q "$protected_item" <<<"$FLAGGED_FILES"; then
            log_violation "Custom protected item found in removal list: $protected_item"
        fi
    done < "$TARGET_DIR/.cleanupignore"

    log_success "Custom protection rules checked"
else
    echo "No .cleanupignore file found (optional)"
fi

if [[ -f "$TARGET_DIR/.cleanup-safety.yml" ]]; then
    log_success "Custom safety configuration found (.cleanup-safety.yml)"
    echo "  Note: Manual review of custom rules recommended"
else
    echo "No .cleanup-safety.yml file found (optional)"
fi

echo ""
echo "=========================================="
echo "Validation Summary"
echo "=========================================="

echo ""
echo "Results:"
echo "  Violations: $VIOLATIONS"
echo "  Warnings: $WARNINGS"

# Determine exit code
if [[ $emergency_stops -gt 0 ]]; then
    echo ""
    echo -e "${RED}EMERGENCY STOP: Critical safety issue detected!${NC}"
    echo "Cleanup cannot proceed. Please review the violations above."
    exit 5
elif [[ $VIOLATIONS -gt 0 ]]; then
    echo ""
    echo -e "${RED}VALIDATION FAILED: $VIOLATIONS violation(s) detected${NC}"
    echo "Cleanup cannot proceed until violations are resolved."

    if [[ $protected_dir_violations -gt 0 ]]; then
        exit 1
    elif [[ $protected_file_violations -gt 0 ]]; then
        exit 1
    elif [[ $path_violations -gt 0 ]]; then
        exit 2
    elif [[ $symlink_violations -gt 0 ]]; then
        exit 3
    elif [[ $file_count -gt 1000 ]]; then
        exit 4
    else
        exit 1
    fi
elif [[ $WARNINGS -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}VALIDATION PASSED with $WARNINGS warning(s)${NC}"
    echo "Cleanup can proceed, but review warnings carefully."
    exit 0
else
    echo ""
    echo -e "${GREEN}✓ ALL SAFETY CHECKS PASSED${NC}"
    echo "Cleanup is safe to proceed."
    exit 0
fi
