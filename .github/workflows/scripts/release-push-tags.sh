#!/bin/bash

# Script to push release tags for beta and stable module sets
# Usage: ./release-push-tags.sh <version> [--stable-version=<stable_version>] [--dry-run]

set -euo pipefail

VERSION="${1:-}"
STABLE_VERSION=""
DRY_RUN=false

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
    echo "Usage: $0 <version> [--stable-version=<stable_version>] [--dry-run]"
    echo "Example: $0 0.85.0 --stable-version=1.2.0"
    echo ""
    echo "Arguments:"
    echo "  version                   Release version without 'v' prefix (required)"
    echo "  --stable-version=VERSION  Stable version without 'v' prefix (optional)"
    echo "  --dry-run                Run in dry-run mode (no tags pushed)"
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
        --dry-run)
            DRY_RUN=true
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
command -v make >/dev/null 2>&1 || { log_error "make is required but not installed"; exit 1; }
command -v git >/dev/null 2>&1 || { log_error "git is required but not installed"; exit 1; }
command -v gh >/dev/null 2>&1 || { log_error "GitHub CLI (gh) is required but not installed"; exit 1; }

# Check GitHub authentication
if ! gh auth status >/dev/null 2>&1; then
    log_error "GitHub CLI is not authenticated. Run 'gh auth login' first"
    exit 1
fi

# Check if we're in the right repository
if [[ ! -f "Makefile" ]] || [[ ! -f "go.mod" ]]; then
    log_error "Not in the root of the OpenTelemetry Collector repository"
    exit 1
fi

# Check if git is configured for signing
if ! git config user.signingkey >/dev/null 2>&1; then
    log_warn "Git signing key not configured - tags will not be signed"
    log_warn "To configure signing: git config user.signingkey <key-id>"
fi

# Ensure we're on the main branch and up to date
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    log_error "Must be on main branch to push tags (currently on: $CURRENT_BRANCH)"
    exit 1
fi

# Check if working directory is clean
if [[ -n "$(git status --porcelain)" ]]; then
    log_error "Working directory is not clean. Commit or stash changes before pushing tags"
    exit 1
fi

# Fetch latest changes
log_info "Fetching latest changes from remote..."
git fetch origin

# Check if local main is up to date
LOCAL_COMMIT=$(git rev-parse HEAD)
REMOTE_COMMIT=$(git rev-parse origin/main)

if [[ "$LOCAL_COMMIT" != "$REMOTE_COMMIT" ]]; then
    log_error "Local main branch is not up to date with remote"
    log_error "Run 'git pull origin main' to update"
    exit 1
fi

log_info "Repository is up to date - proceeding with tag creation"

# Function to check if tag already exists
check_tag_exists() {
    local tag_name="$1"
    if git tag -l "$tag_name" | grep -q "^$tag_name$"; then
        return 0  # Tag exists locally
    fi
    if git ls-remote --tags origin "$tag_name" | grep -q "refs/tags/$tag_name$"; then
        return 0  # Tag exists on remote
    fi
    return 1  # Tag doesn't exist
}

# Function to push tags with proper error handling
push_tags_with_retry() {
    local modset="$1"
    local version="$2"
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        log_info "Pushing tags for $modset module set (attempt $((retry_count + 1))/$max_retries)..."
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "DRY RUN: Would execute: make push-tags MODSET=$modset"
            return 0
        fi
        
        # Use make target to push tags
        if make push-tags MODSET="$modset"; then
            log_info "✅ Successfully pushed $modset tags"
            return 0
        else
            log_warn "Failed to push $modset tags (attempt $((retry_count + 1))/$max_retries)"
            retry_count=$((retry_count + 1))
            
            if [[ $retry_count -lt $max_retries ]]; then
                log_info "Retrying in 10 seconds..."
                sleep 10
            fi
        fi
    done
    
    log_error "Failed to push $modset tags after $max_retries attempts"
    return 1
}

# Check if beta version tags would conflict
log_info "Checking for existing beta tags for version $VERSION..."
BETA_TAG_PREFIX="v$VERSION"
if check_tag_exists "$BETA_TAG_PREFIX"; then
    log_error "Tag $BETA_TAG_PREFIX already exists"
    exit 1
fi

# Push beta tags
log_info "Pushing beta tags for version $VERSION..."
if ! push_tags_with_retry "beta" "$VERSION"; then
    log_error "Failed to push beta tags"
    exit 1
fi

log_info "✅ Beta tags pushed successfully"

# Wait for the release-branch workflow to be triggered
log_info "Waiting for release-branch workflow to be triggered by beta tags..."
sleep 30

# Check if stable version should be released
if [[ -n "$STABLE_VERSION" ]]; then
    log_info "Checking for existing stable tags for version $STABLE_VERSION..."
    STABLE_TAG_PREFIX="v$STABLE_VERSION"
    if check_tag_exists "$STABLE_TAG_PREFIX"; then
        log_error "Stable tag $STABLE_TAG_PREFIX already exists"
        exit 1
    fi
    
    # Push stable tags
    log_info "Pushing stable tags for version $STABLE_VERSION..."
    if ! push_tags_with_retry "stable" "$STABLE_VERSION"; then
        log_error "Failed to push stable tags"
        exit 1
    fi
    
    log_info "✅ Stable tags pushed successfully"
else
    log_info "No stable version specified, skipping stable tag push"
fi

# Wait for release branch creation (triggered by beta tags)
RELEASE_BRANCH="release/v${VERSION%.*}.x"
log_info "Waiting for release branch '$RELEASE_BRANCH' to be created..."

BRANCH_WAIT_TIMEOUT=900  # 15 minutes
BRANCH_WAIT_ELAPSED=0
BRANCH_WAIT_INTERVAL=30

while [[ $BRANCH_WAIT_ELAPSED -lt $BRANCH_WAIT_TIMEOUT ]]; do
    if git ls-remote --exit-code origin "refs/heads/$RELEASE_BRANCH" >/dev/null 2>&1; then
        log_info "✅ Release branch '$RELEASE_BRANCH' created successfully"
        break
    else
        log_info "Release branch not yet created, waiting..."
        sleep $BRANCH_WAIT_INTERVAL
        BRANCH_WAIT_ELAPSED=$((BRANCH_WAIT_ELAPSED + BRANCH_WAIT_INTERVAL))
    fi
done

if [[ $BRANCH_WAIT_ELAPSED -ge $BRANCH_WAIT_TIMEOUT ]]; then
    log_error "Timeout waiting for release branch '$RELEASE_BRANCH' to be created"
    log_error "Check the release-branch workflow: https://github.com/open-telemetry/opentelemetry-collector/actions/workflows/release-branch.yml"
    exit 1
fi

# Wait for tag-triggered builds to complete
log_info "Waiting for tag-triggered builds to complete..."

BUILD_WAIT_TIMEOUT=1800  # 30 minutes
BUILD_WAIT_ELAPSED=0
BUILD_WAIT_INTERVAL=60

while [[ $BUILD_WAIT_ELAPSED -lt $BUILD_WAIT_TIMEOUT ]]; do
    # Check for running workflows triggered by tags
    RUNNING_BUILDS=$(gh run list --event push --json id,status,conclusion | jq -r '.[] | select(.status == "in_progress") | .id')
    
    if [[ -z "$RUNNING_BUILDS" ]]; then
        log_info "✅ All tag-triggered builds completed"
        break
    else
        RUNNING_COUNT=$(echo "$RUNNING_BUILDS" | wc -l)
        log_info "Still waiting for $RUNNING_COUNT build(s) to complete..."
        sleep $BUILD_WAIT_INTERVAL
        BUILD_WAIT_ELAPSED=$((BUILD_WAIT_ELAPSED + BUILD_WAIT_INTERVAL))
    fi
done

if [[ $BUILD_WAIT_ELAPSED -ge $BUILD_WAIT_TIMEOUT ]]; then
    log_error "Timeout waiting for tag-triggered builds to complete"
    log_error "Check build status: https://github.com/open-telemetry/opentelemetry-collector/actions"
    exit 1
fi

# Final verification - check that all builds passed
log_info "Verifying that all tag-triggered builds passed..."
FAILED_BUILDS=$(gh run list --event push --limit 10 --json id,status,conclusion | jq -r '.[] | select(.status == "completed" and .conclusion != "success") | .id')

if [[ -n "$FAILED_BUILDS" ]]; then
    log_error "Some tag-triggered builds failed:"
    echo "$FAILED_BUILDS" | while read -r run_id; do
        if [[ -n "$run_id" ]]; then
            RUN_INFO=$(gh run view "$run_id" --json displayTitle,url)
            RUN_TITLE=$(echo "$RUN_INFO" | jq -r .displayTitle)
            RUN_URL=$(echo "$RUN_INFO" | jq -r .url)
            log_error "  Failed: $RUN_TITLE ($RUN_URL)"
        fi
    done
    exit 1
fi

log_info "✅ All tag-triggered builds passed successfully"

# Output summary
log_info "🎉 Tag pushing completed successfully!"
log_info "Summary:"
log_info "  Beta version: $VERSION"
if [[ -n "$STABLE_VERSION" ]]; then
    log_info "  Stable version: $STABLE_VERSION"
fi
log_info "  Release branch: $RELEASE_BRANCH"
log_info "  All builds: Passed"

log_info "Next steps:"
log_info "  1. Verify GitHub release was created automatically"
log_info "  2. Proceed with opentelemetry-collector-contrib release"
log_info "  3. Update opentelemetry-collector-releases artifacts"