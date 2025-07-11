#!/bin/bash

# Release validation script
# Usage: ./release-validate.sh <version> [stable_version]
# Example: ./release-validate.sh 0.85.0 1.2.0

set -euo pipefail

VERSION="${1:-}"
STABLE_VERSION="${2:-}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    echo "Usage: $0 <version> [stable_version]"
    echo "Example: $0 0.85.0 1.2.0"
    echo ""
    echo "Arguments:"
    echo "  version        Release version without 'v' prefix (required)"
    echo "  stable_version Stable version without 'v' prefix (optional)"
    exit 1
}

# Validate arguments
if [[ -z "$VERSION" ]]; then
    log_error "Version is required"
    usage
fi

# Validate version format
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "Invalid version format: $VERSION"
    log_error "Version must be in semantic versioning format (e.g., 0.85.0)"
    exit 1
fi

if [[ -n "$STABLE_VERSION" && ! "$STABLE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "Invalid stable version format: $STABLE_VERSION"
    log_error "Stable version must be in semantic versioning format (e.g., 1.2.0)"
    exit 1
fi

log_info "Validating release prerequisites for version $VERSION"
if [[ -n "$STABLE_VERSION" ]]; then
    log_info "Stable version: $STABLE_VERSION"
fi

# Check if required tools are available
command -v gh >/dev/null 2>&1 || { log_error "GitHub CLI (gh) is required but not installed"; exit 1; }
command -v jq >/dev/null 2>&1 || { log_error "jq is required but not installed"; exit 1; }
command -v git >/dev/null 2>&1 || { log_error "git is required but not installed"; exit 1; }

# Check GitHub authentication
if ! gh auth status >/dev/null 2>&1; then
    log_error "GitHub CLI is not authenticated. Run 'gh auth login' first"
    exit 1
fi

# Check for release blockers in core repository
log_info "Checking for release blockers in opentelemetry-collector..."
BLOCKERS=$(gh issue list --repo jackgopack4/opentelemetry-collector --label "release:blocker" --state open --json number,title 2>/dev/null || echo "[]")
BLOCKER_COUNT=$(echo "$BLOCKERS" | jq length)

if [[ "$BLOCKER_COUNT" -gt 0 ]]; then
    log_error "Found $BLOCKER_COUNT release blocker(s) in opentelemetry-collector:"
    echo "$BLOCKERS" | jq -r '.[] | "  #\(.number): \(.title)"'
    exit 1
fi

# Check for release blockers in contrib repository
log_info "Checking for release blockers in opentelemetry-collector-contrib..."
CONTRIB_BLOCKERS=$(gh issue list --repo jackgopack4/opentelemetry-collector-contrib --label "release:blocker" --state open --json number,title 2>/dev/null || echo "[]")
CONTRIB_BLOCKER_COUNT=$(echo "$CONTRIB_BLOCKERS" | jq length)

if [[ "$CONTRIB_BLOCKER_COUNT" -gt 0 ]]; then
    log_error "Found $CONTRIB_BLOCKER_COUNT release blocker(s) in opentelemetry-collector-contrib:"
    echo "$CONTRIB_BLOCKERS" | jq -r '.[] | "  #\(.number): \(.title)"'
    exit 1
fi

# Check for release blockers in releases repository
log_info "Checking for release blockers in opentelemetry-collector-releases..."
RELEASES_BLOCKERS=$(gh issue list --repo jackgopack4/opentelemetry-collector-releases --label "release:blocker" --state open --json number,title 2>/dev/null || echo "[]")
RELEASES_BLOCKER_COUNT=$(echo "$RELEASES_BLOCKERS" | jq length)

if [[ "$RELEASES_BLOCKER_COUNT" -gt 0 ]]; then
    log_error "Found $RELEASES_BLOCKER_COUNT release blocker(s) in opentelemetry-collector-releases:"
    echo "$RELEASES_BLOCKERS" | jq -r '.[] | "  #\(.number): \(.title)"'
    exit 1
fi

# Check if we're on the right branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    log_warn "Not on main branch (currently on: $CURRENT_BRANCH)"
    log_warn "Release should typically be done from main branch"
fi

# Check if working directory is clean
if [[ -n "$(git status --porcelain)" ]]; then
    log_warn "Working directory is not clean"
    log_warn "Uncommitted changes may interfere with release process"
fi

# Validate stable module changes if stable version is provided
if [[ -n "$STABLE_VERSION" ]]; then
    log_info "Checking for stable module changes..."
    if command -v make >/dev/null 2>&1; then
        PREVIOUS_STABLE_VERSION=$(gh release list --repo jackgopack4/opentelemetry-collector --json tagName,isLatest | jq -r '.[] | select(.tagName | startswith("v1.")) | .tagName' | head -1 | sed 's/^v//')
        if [[ -n "$PREVIOUS_STABLE_VERSION" ]]; then
            log_info "Previous stable version: $PREVIOUS_STABLE_VERSION"
            if make check-changes PREVIOUS_VERSION="v$PREVIOUS_STABLE_VERSION" MODSET=stable 2>/dev/null; then
                log_info "Stable module changes detected"
            else
                log_warn "No stable module changes detected since v$PREVIOUS_STABLE_VERSION"
                log_warn "Consider whether stable release is necessary"
            fi
        else
            log_warn "Could not determine previous stable version"
        fi
    else
        log_warn "Make not available, skipping stable module change check"
    fi
fi

# Check if release already exists
if gh release view "v$VERSION" --repo jackgopack4/opentelemetry-collector >/dev/null 2>&1; then
    log_error "Release v$VERSION already exists"
    exit 1
fi

# Output environment information for debugging
log_info "Environment information:"
echo "  Current directory: $(pwd)"
echo "  Git branch: $CURRENT_BRANCH"
echo "  Git HEAD: $(git rev-parse HEAD)"
echo "  GitHub user: $(gh api user --jq .login 2>/dev/null || echo 'unknown')"

log_info "✅ All validation checks passed"
log_info "Ready to proceed with release $VERSION"

# Export variables for use by other scripts
export RELEASE_VERSION="$VERSION"
export RELEASE_STABLE_VERSION="$STABLE_VERSION"
export RELEASE_BRANCH="release/v${VERSION%.*}.x"

echo "RELEASE_VERSION=$VERSION"
echo "RELEASE_STABLE_VERSION=$STABLE_VERSION"
echo "RELEASE_BRANCH=release/v${VERSION%.*}.x"