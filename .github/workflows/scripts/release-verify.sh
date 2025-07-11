#!/bin/bash

# Script to verify that the release was created successfully
# Usage: ./release-verify.sh <version> [--stable-version=<stable_version>]

set -euo pipefail

VERSION="${1:-}"
STABLE_VERSION=""

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
    echo "Usage: $0 <version> [--stable-version=<stable_version>]"
    echo "Example: $0 0.85.0 --stable-version=1.2.0"
    echo ""
    echo "Arguments:"
    echo "  version                   Release version without 'v' prefix (required)"
    echo "  --stable-version=VERSION  Stable version without 'v' prefix (optional)"
    exit 1
}

# Parse arguments
shift  # Remove the first argument (version)
while [[ $# -gt 0 ]]; do
    case $1 in
        --stable-version=*)
            STABLE_VERSION="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate arguments
if [[ -z "$VERSION" ]]; then
    log_error "Version is required"
    usage
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

REPO="jackgopack4/opentelemetry-collector"
BETA_TAG="v$VERSION"
STABLE_TAG=""
if [[ -n "$STABLE_VERSION" ]]; then
    STABLE_TAG="v$STABLE_VERSION"
fi

log_info "Verifying release for version $VERSION"
if [[ -n "$STABLE_VERSION" ]]; then
    log_info "Also verifying stable version $STABLE_VERSION"
fi

# Track verification results
VERIFICATION_ERRORS=0

# Function to report verification result
verify_item() {
    local item="$1"
    local status="$2"
    local details="${3:-}"
    
    if [[ "$status" == "pass" ]]; then
        log_info "✅ $item"
        if [[ -n "$details" ]]; then
            echo "    $details"
        fi
    else
        log_error "❌ $item"
        if [[ -n "$details" ]]; then
            echo "    $details"
        fi
        VERIFICATION_ERRORS=$((VERIFICATION_ERRORS + 1))
    fi
}

# Verify beta tags exist
log_info "Verifying beta tags..."
if git ls-remote --tags origin | grep -q "refs/tags/$BETA_TAG$"; then
    verify_item "Beta tag $BETA_TAG exists on remote" "pass"
else
    verify_item "Beta tag $BETA_TAG exists on remote" "fail"
fi

# Verify stable tags exist (if specified)
if [[ -n "$STABLE_VERSION" ]]; then
    log_info "Verifying stable tags..."
    if git ls-remote --tags origin | grep -q "refs/tags/$STABLE_TAG$"; then
        verify_item "Stable tag $STABLE_TAG exists on remote" "pass"
    else
        verify_item "Stable tag $STABLE_TAG exists on remote" "fail"
    fi
fi

# Verify release branch exists
RELEASE_BRANCH="release/v${VERSION%.*}.x"
log_info "Verifying release branch..."
if git ls-remote --heads origin | grep -q "refs/heads/$RELEASE_BRANCH$"; then
    verify_item "Release branch $RELEASE_BRANCH exists" "pass"
else
    verify_item "Release branch $RELEASE_BRANCH exists" "fail"
fi

# Verify GitHub release was created
log_info "Verifying GitHub release..."
if gh release view "$BETA_TAG" --repo "$REPO" >/dev/null 2>&1; then
    RELEASE_INFO=$(gh release view "$BETA_TAG" --repo "$REPO" --json name,tagName,publishedAt,isDraft,isPrerelease,url)
    RELEASE_NAME=$(echo "$RELEASE_INFO" | jq -r .name)
    RELEASE_URL=$(echo "$RELEASE_INFO" | jq -r .url)
    IS_DRAFT=$(echo "$RELEASE_INFO" | jq -r .isDraft)
    IS_PRERELEASE=$(echo "$RELEASE_INFO" | jq -r .isPrerelease)
    
    verify_item "GitHub release $BETA_TAG created" "pass" "URL: $RELEASE_URL"
    
    if [[ "$IS_DRAFT" == "true" ]]; then
        verify_item "Release is not a draft" "fail"
    else
        verify_item "Release is published" "pass"
    fi
    
    if [[ "$IS_PRERELEASE" == "false" ]]; then
        verify_item "Release is not marked as prerelease" "pass"
    else
        verify_item "Release is marked as prerelease" "fail"
    fi
else
    verify_item "GitHub release $BETA_TAG created" "fail"
fi

# Verify release assets/content
log_info "Verifying release content..."
if gh release view "$BETA_TAG" --repo "$REPO" >/dev/null 2>&1; then
    RELEASE_BODY=$(gh release view "$BETA_TAG" --repo "$REPO" --json body | jq -r .body)
    
    if [[ -n "$RELEASE_BODY" && "$RELEASE_BODY" != "null" ]]; then
        verify_item "Release has description/changelog" "pass"
        
        # Check if changelog sections are present
        if echo "$RELEASE_BODY" | grep -q "## 🚀 New components"; then
            verify_item "Release contains 'New components' section" "pass"
        else
            verify_item "Release contains 'New components' section" "fail"
        fi
        
        if echo "$RELEASE_BODY" | grep -q "## 💡 Enhancements"; then
            verify_item "Release contains 'Enhancements' section" "pass"
        else
            verify_item "Release contains 'Enhancements' section" "fail"
        fi
        
        if echo "$RELEASE_BODY" | grep -q "## 🧰 Bug fixes"; then
            verify_item "Release contains 'Bug fixes' section" "pass"
        else
            verify_item "Release contains 'Bug fixes' section" "fail"
        fi
    else
        verify_item "Release has description/changelog" "fail"
    fi
else
    verify_item "Could not verify release content" "fail"
fi

# Verify recent workflow runs succeeded
log_info "Verifying recent workflow runs..."
RECENT_RUNS=$(gh run list --repo "$REPO" --event push --limit 5 --json id,status,conclusion,displayTitle,url)
FAILED_RUNS=$(echo "$RECENT_RUNS" | jq -r '.[] | select(.status == "completed" and .conclusion != "success")')

if [[ -n "$FAILED_RUNS" ]]; then
    FAILED_COUNT=$(echo "$FAILED_RUNS" | jq -s length)
    verify_item "Recent workflow runs succeeded" "fail" "$FAILED_COUNT recent runs failed"
    
    echo "$FAILED_RUNS" | jq -r '.displayTitle + " - " + .url' | while read -r run_info; do
        log_error "  $run_info"
    done
else
    verify_item "Recent workflow runs succeeded" "pass"
fi

# Verify sourcecode-release workflow ran
log_info "Verifying sourcecode-release workflow..."
SOURCECODE_RUNS=$(gh run list --repo "$REPO" --workflow sourcecode-release.yaml --limit 3 --json id,status,conclusion,displayTitle,url)
RECENT_SOURCECODE_RUN=$(echo "$SOURCECODE_RUNS" | jq -r '.[0]')

if [[ -n "$RECENT_SOURCECODE_RUN" && "$RECENT_SOURCECODE_RUN" != "null" ]]; then
    RUN_STATUS=$(echo "$RECENT_SOURCECODE_RUN" | jq -r .status)
    RUN_CONCLUSION=$(echo "$RECENT_SOURCECODE_RUN" | jq -r .conclusion)
    RUN_TITLE=$(echo "$RECENT_SOURCECODE_RUN" | jq -r .displayTitle)
    RUN_URL=$(echo "$RECENT_SOURCECODE_RUN" | jq -r .url)
    
    if [[ "$RUN_STATUS" == "completed" && "$RUN_CONCLUSION" == "success" ]]; then
        verify_item "Sourcecode-release workflow succeeded" "pass" "$RUN_TITLE"
    else
        verify_item "Sourcecode-release workflow succeeded" "fail" "$RUN_TITLE - $RUN_URL"
    fi
else
    verify_item "Sourcecode-release workflow ran" "fail"
fi

# Check if milestone was updated
log_info "Verifying milestone management..."
MILESTONES=$(gh api repos/"$REPO"/milestones --jq '.[].title' 2>/dev/null || echo "")
if echo "$MILESTONES" | grep -q "^$BETA_TAG$"; then
    verify_item "Milestone $BETA_TAG exists" "pass"
else
    verify_item "Milestone $BETA_TAG exists" "fail"
fi

# Additional checks for contributors and community
log_info "Verifying release quality..."

# Check if release has reasonable number of commits
COMMIT_COUNT=$(git rev-list --count "$BETA_TAG" 2>/dev/null || echo "0")
if [[ "$COMMIT_COUNT" -gt 100 ]]; then
    verify_item "Release has reasonable commit history" "pass" "$COMMIT_COUNT commits"
elif [[ "$COMMIT_COUNT" -gt 0 ]]; then
    verify_item "Release has some commit history" "pass" "$COMMIT_COUNT commits (seems low)"
else
    verify_item "Release has commit history" "fail"
fi

# Verify that tag is signed (if GPG is configured)
if git config user.signingkey >/dev/null 2>&1; then
    log_info "Verifying tag signature..."
    if git verify-tag "$BETA_TAG" >/dev/null 2>&1; then
        verify_item "Tag is GPG signed" "pass"
    else
        verify_item "Tag is GPG signed" "fail"
    fi
else
    verify_item "Tag signing verification skipped" "pass" "No GPG key configured"
fi

# Check for any security vulnerabilities in dependencies
log_info "Checking for security issues..."
if command -v go >/dev/null 2>&1; then
    if go version | grep -q "go1\.[2-9][0-9]"; then
        # Use go mod download to ensure dependencies are available
        if go mod download 2>/dev/null; then
            # Check for known vulnerabilities (requires Go 1.18+)
            if command -v govulncheck >/dev/null 2>&1; then
                if govulncheck ./... >/dev/null 2>&1; then
                    verify_item "No known security vulnerabilities" "pass"
                else
                    verify_item "No known security vulnerabilities" "fail" "Run 'govulncheck ./...' for details"
                fi
            else
                verify_item "Security vulnerability check skipped" "pass" "govulncheck not available"
            fi
        else
            verify_item "Dependency download failed" "fail"
        fi
    else
        verify_item "Go version check skipped" "pass" "Requires Go 1.18+ for vulnerability checking"
    fi
else
    verify_item "Go security check skipped" "pass" "Go not available"
fi

# Final summary
log_info "=== VERIFICATION SUMMARY ==="
if [[ $VERIFICATION_ERRORS -eq 0 ]]; then
    log_info "🎉 All verification checks passed!"
    log_info "Release $VERSION appears to be successful"
    
    echo ""
    log_info "Release Information:"
    log_info "  Version: $VERSION"
    if [[ -n "$STABLE_VERSION" ]]; then
        log_info "  Stable Version: $STABLE_VERSION"
    fi
    log_info "  Release Branch: $RELEASE_BRANCH"
    if gh release view "$BETA_TAG" --repo "$REPO" >/dev/null 2>&1; then
        RELEASE_URL=$(gh release view "$BETA_TAG" --repo "$REPO" --json url | jq -r .url)
        log_info "  Release URL: $RELEASE_URL"
    fi
    
    echo ""
    log_info "Next Steps:"
    log_info "  1. ✅ Core release verification complete"
    log_info "  2. 🔄 Proceed with opentelemetry-collector-contrib release"
    log_info "  3. 🔄 Update opentelemetry-collector-releases artifacts"
    log_info "  4. 🔄 Verify Docker images are published"
    log_info "  5. 🔄 Announce release to community"
    
    exit 0
else
    log_error "❌ $VERIFICATION_ERRORS verification check(s) failed"
    log_error "Release $VERSION may have issues that need attention"
    
    echo ""
    log_error "Manual investigation required:"
    log_error "  1. Review failed checks above"
    log_error "  2. Check GitHub Actions: https://github.com/$REPO/actions"
    log_error "  3. Verify release manually: https://github.com/$REPO/releases/tag/$BETA_TAG"
    log_error "  4. Contact release manager or maintainers if needed"
    
    exit 1
fi