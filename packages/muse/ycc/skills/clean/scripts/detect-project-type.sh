#!/usr/bin/env bash
#
# Project Type Detection Script
# Detects the type of project based on files present in the directory
#
# Usage: detect-project-type.sh [target-directory]
#
# Exit codes:
#   0 - Success, project type detected
#   1 - Invalid usage or directory doesn't exist
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get target directory from argument or use current directory
TARGET_DIR="${1:-.}"

# Validate directory exists
if [[ ! -d "$TARGET_DIR" ]]; then
    echo -e "${RED}Error: Directory does not exist: $TARGET_DIR${NC}" >&2
    exit 1
fi

# Convert to absolute path
TARGET_DIR=$(cd "$TARGET_DIR" && pwd)

# Initialize detection results
PROJECT_TYPES=()
PRIMARY_TYPE=""
CONFIDENCE="unknown"

echo "Analyzing project directory: $TARGET_DIR"
echo ""

# Function to check if file exists in directory
file_exists() {
    [[ -f "$TARGET_DIR/$1" ]]
}

# Function to check if directory exists
dir_exists() {
    [[ -d "$TARGET_DIR/$1" ]]
}

# Detect Docker
detect_docker() {
    local score=0

    if file_exists "Dockerfile"; then
        score=$((score + 3))
        echo "  ✓ Dockerfile found"
    fi

    if file_exists "docker-compose.yml" || file_exists "docker-compose.yaml"; then
        score=$((score + 3))
        echo "  ✓ docker-compose.yml found"
    fi

    if file_exists ".dockerignore"; then
        score=$((score + 1))
        echo "  ✓ .dockerignore found"
    fi

    if dir_exists "docker"; then
        score=$((score + 1))
        echo "  ✓ docker/ directory found"
    fi

    if [[ $score -ge 3 ]]; then
        PROJECT_TYPES+=("Docker")
        echo -e "${GREEN}Docker project detected (confidence: $score/8)${NC}"
        if [[ $score -ge 6 ]]; then
            CONFIDENCE="high"
        elif [[ $score -ge 4 ]]; then
            CONFIDENCE="medium"
        else
            CONFIDENCE="low"
        fi
        return 0
    fi
    return 1
}

# Detect Node.js
detect_nodejs() {
    local score=0

    if file_exists "package.json"; then
        score=$((score + 5))
        echo "  ✓ package.json found"
    fi

    if file_exists "package-lock.json"; then
        score=$((score + 2))
        echo "  ✓ package-lock.json found"
    fi

    if file_exists "yarn.lock"; then
        score=$((score + 2))
        echo "  ✓ yarn.lock found"
    fi

    if file_exists "pnpm-lock.yaml"; then
        score=$((score + 2))
        echo "  ✓ pnpm-lock.yaml found"
    fi

    if dir_exists "node_modules"; then
        score=$((score + 1))
        echo "  ✓ node_modules/ directory found"
    fi

    if file_exists ".nvmrc" || file_exists ".node-version"; then
        score=$((score + 1))
        echo "  ✓ Node version file found"
    fi

    if [[ $score -ge 5 ]]; then
        PROJECT_TYPES+=("Node.js")
        echo -e "${GREEN}Node.js project detected (confidence: $score/13)${NC}"
        [[ -z "$PRIMARY_TYPE" ]] && PRIMARY_TYPE="Node.js"
        return 0
    fi
    return 1
}

# Detect Python
detect_python() {
    local score=0

    if file_exists "requirements.txt"; then
        score=$((score + 3))
        echo "  ✓ requirements.txt found"
    fi

    if file_exists "setup.py"; then
        score=$((score + 3))
        echo "  ✓ setup.py found"
    fi

    if file_exists "pyproject.toml"; then
        score=$((score + 4))
        echo "  ✓ pyproject.toml found"
    fi

    if file_exists "Pipfile"; then
        score=$((score + 3))
        echo "  ✓ Pipfile found"
    fi

    if file_exists "poetry.lock"; then
        score=$((score + 2))
        echo "  ✓ poetry.lock found"
    fi

    if dir_exists ".venv" || dir_exists "venv"; then
        score=$((score + 1))
        echo "  ✓ Virtual environment found"
    fi

    if [[ $score -ge 3 ]]; then
        PROJECT_TYPES+=("Python")
        echo -e "${GREEN}Python project detected (confidence: $score/16)${NC}"
        [[ -z "$PRIMARY_TYPE" ]] && PRIMARY_TYPE="Python"
        return 0
    fi
    return 1
}

# Detect Go
detect_go() {
    local score=0

    if file_exists "go.mod"; then
        score=$((score + 5))
        echo "  ✓ go.mod found"
    fi

    if file_exists "go.sum"; then
        score=$((score + 2))
        echo "  ✓ go.sum found"
    fi

    if file_exists "go.work"; then
        score=$((score + 2))
        echo "  ✓ go.work found"
    fi

    # Check for .go files
    if find "$TARGET_DIR" -maxdepth 2 -name "*.go" -type f -print -quit | grep -q .; then
        score=$((score + 3))
        echo "  ✓ .go files found"
    fi

    if [[ $score -ge 5 ]]; then
        PROJECT_TYPES+=("Go")
        echo -e "${GREEN}Go project detected (confidence: $score/12)${NC}"
        [[ -z "$PRIMARY_TYPE" ]] && PRIMARY_TYPE="Go"
        return 0
    fi
    return 1
}

# Detect Rust
detect_rust() {
    local score=0

    if file_exists "Cargo.toml"; then
        score=$((score + 5))
        echo "  ✓ Cargo.toml found"
    fi

    if file_exists "Cargo.lock"; then
        score=$((score + 2))
        echo "  ✓ Cargo.lock found"
    fi

    if dir_exists "src" && find "$TARGET_DIR/src" -name "*.rs" -type f -print -quit | grep -q .; then
        score=$((score + 3))
        echo "  ✓ Rust source files found"
    fi

    if [[ $score -ge 5 ]]; then
        PROJECT_TYPES+=("Rust")
        echo -e "${GREEN}Rust project detected (confidence: $score/10)${NC}"
        [[ -z "$PRIMARY_TYPE" ]] && PRIMARY_TYPE="Rust"
        return 0
    fi
    return 1
}

# Detect Ruby
detect_ruby() {
    local score=0

    if file_exists "Gemfile"; then
        score=$((score + 4))
        echo "  ✓ Gemfile found"
    fi

    if file_exists "Gemfile.lock"; then
        score=$((score + 2))
        echo "  ✓ Gemfile.lock found"
    fi

    if file_exists ".ruby-version"; then
        score=$((score + 1))
        echo "  ✓ .ruby-version found"
    fi

    if [[ $score -ge 4 ]]; then
        PROJECT_TYPES+=("Ruby")
        echo -e "${GREEN}Ruby project detected (confidence: $score/7)${NC}"
        [[ -z "$PRIMARY_TYPE" ]] && PRIMARY_TYPE="Ruby"
        return 0
    fi
    return 1
}

# Detect Java/Maven
detect_java() {
    local score=0

    if file_exists "pom.xml"; then
        score=$((score + 5))
        echo "  ✓ pom.xml found (Maven)"
    fi

    if file_exists "build.gradle" || file_exists "build.gradle.kts"; then
        score=$((score + 5))
        echo "  ✓ Gradle build file found"
    fi

    if file_exists "gradlew"; then
        score=$((score + 2))
        echo "  ✓ Gradle wrapper found"
    fi

    if [[ $score -ge 5 ]]; then
        PROJECT_TYPES+=("Java")
        echo -e "${GREEN}Java project detected (confidence: $score/12)${NC}"
        [[ -z "$PRIMARY_TYPE" ]] && PRIMARY_TYPE="Java"
        return 0
    fi
    return 1
}

# Detect PHP/Composer
detect_php() {
    local score=0

    if file_exists "composer.json"; then
        score=$((score + 4))
        echo "  ✓ composer.json found"
    fi

    if file_exists "composer.lock"; then
        score=$((score + 2))
        echo "  ✓ composer.lock found"
    fi

    if [[ $score -ge 4 ]]; then
        PROJECT_TYPES+=("PHP")
        echo -e "${GREEN}PHP project detected (confidence: $score/6)${NC}"
        [[ -z "$PRIMARY_TYPE" ]] && PRIMARY_TYPE="PHP"
        return 0
    fi
    return 1
}

# Detect Git repository
detect_git() {
    if dir_exists ".git"; then
        echo -e "${BLUE}Git repository detected${NC}"
        return 0
    fi
    return 1
}

# Main detection logic
echo "Detecting project types..."
echo ""

# Run all detections
detect_docker || true
detect_nodejs || true
detect_python || true
detect_go || true
detect_rust || true
detect_ruby || true
detect_java || true
detect_php || true
IS_GIT=0
detect_git && IS_GIT=1 || true

echo ""
echo "=========================================="
echo "Detection Summary"
echo "=========================================="

if [[ ${#PROJECT_TYPES[@]} -eq 0 ]]; then
    echo "Primary Type: Generic (no specific framework detected)"
    PRIMARY_TYPE="Generic"
    CONFIDENCE="low"
else
    echo "Primary Type: $PRIMARY_TYPE"
    if [[ ${#PROJECT_TYPES[@]} -gt 1 ]]; then
        echo "Additional Types: ${PROJECT_TYPES[*]}"
    fi
fi

echo "Confidence: $CONFIDENCE"

if [[ $IS_GIT -eq 1 ]]; then
    echo "Version Control: Git"
else
    echo "Version Control: None detected"
fi

echo ""
echo "=========================================="
echo "Project Context"
echo "=========================================="

# Provide context based on detected types
if [[ " ${PROJECT_TYPES[*]} " =~ " Docker " ]]; then
    echo ""
    echo "Docker Project Notes:"
    echo "  - Compiled binaries should be in containers, not repository"
    echo "  - Volume mount artifacts should not be committed"
    echo "  - Check for old Dockerfile variants"
fi

if [[ " ${PROJECT_TYPES[*]} " == *" Node.js "* ]]; then
    echo ""
    echo "Node.js Project Notes:"
    echo "  - node_modules/ is protected (managed by npm/yarn/pnpm)"
    echo "  - Check for multiple lock files (use only one package manager)"
    echo "  - Look for old build artifacts in dist/ or build/"
fi

if [[ " ${PROJECT_TYPES[*]} " =~ " Python " ]]; then
    echo ""
    echo "Python Project Notes:"
    echo "  - .venv/ is protected (virtual environment)"
    echo "  - __pycache__/ directories can be safely removed"
    echo "  - .pyc files are safe to remove"
fi

if [[ " ${PROJECT_TYPES[*]} " =~ " Go " ]]; then
    echo ""
    echo "Go Project Notes:"
    echo "  - Compiled binaries should not be in repository"
    echo "  - Check for executables matching project name in root"
fi

# Export environment variables for use by the skill
export DETECTED_PROJECT_TYPE="$PRIMARY_TYPE"
export DETECTED_PROJECT_CONFIDENCE="$CONFIDENCE"
export DETECTED_IS_GIT="$IS_GIT"

# Output JSON for programmatic use
echo ""
echo "JSON Output (for programmatic use):"
cat << EOF
{
  "primary_type": "$PRIMARY_TYPE",
  "all_types": [$(printf '"%s",' "${PROJECT_TYPES[@]}" | sed 's/,$//')],
  "confidence": "$CONFIDENCE",
  "is_git": $IS_GIT,
  "target_directory": "$TARGET_DIR"
}
EOF

echo ""
echo "Detection complete."
exit 0
