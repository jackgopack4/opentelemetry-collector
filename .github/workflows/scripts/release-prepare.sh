#!/bin/bash

# Script to orchestrate the prepare-release workflow and wait for PR merge
# Usage: ./release-prepare.sh <version> [stable_version]

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

# Check if required tools are available
command -v gh >/dev/null 2>&1 || { log_error "GitHub CLI (gh) is required but not installed"; exit 1; }
command -v jq >/dev/null 2>&1 || { log_error "jq is required but not installed"; exit 1; }

# Check GitHub authentication
if ! gh auth status >/dev/null 2>&1; then
    log_error "GitHub CLI is not authenticated. Run 'gh auth login' first"
    exit 1
fi

REPO="open-telemetry/opentelemetry-collector"
WORKFLOW_NAME="prepare-release.yml"

log_info "Triggering prepare-release workflow for version $VERSION"
if [[ -n "$STABLE_VERSION" ]]; then
    log_info "Stable version: $STABLE_VERSION"
fi

# Build the workflow dispatch command
WORKFLOW_CMD="gh workflow run --repo $REPO $WORKFLOW_NAME --field release_candidate=$VERSION"
if [[ -n "$STABLE_VERSION" ]]; then
    WORKFLOW_CMD="$WORKFLOW_CMD --field stable_version=$STABLE_VERSION"
fi

# Trigger the workflow
log_info "Executing: $WORKFLOW_CMD"
if ! eval "$WORKFLOW_CMD"; then
    log_error "Failed to trigger prepare-release workflow"
    exit 1
fi

# Wait for the workflow to start
log_info "Waiting for prepare-release workflow to start..."
sleep 30

# Get the latest workflow run
LATEST_RUN=$(gh run list --repo "$REPO" --workflow "$WORKFLOW_NAME" --limit 1 --json id,conclusion,status)
LATEST_RUN_COUNT=$(echo "$LATEST_RUN" | jq length)

if [[ "$LATEST_RUN_COUNT" -eq 0 ]]; then
    log_error "No prepare-release workflow runs found"
    exit 1
fi

LATEST_RUN_ID=$(echo "$LATEST_RUN" | jq -r '.[0].id')
LATEST_STATUS=$(echo "$LATEST_RUN" | jq -r '.[0].status')

log_info "Found workflow run: $LATEST_RUN_ID (status: $LATEST_STATUS)"

# Wait for the workflow to complete
if [[ "$LATEST_STATUS" != "completed" ]]; then
    log_info "Waiting for prepare-release workflow to complete..."
    if ! gh run watch --repo "$REPO" "$LATEST_RUN_ID" --exit-status; then
        log_error "Prepare-release workflow failed"
        
        # Get workflow run URL for debugging
        RUN_URL=$(gh run view --repo "$REPO" "$LATEST_RUN_ID" --json url | jq -r .url)
        log_error "Workflow run URL: $RUN_URL"
        
        # Get logs for debugging
        log_info "Fetching workflow logs for debugging..."
        gh run view --repo "$REPO" "$LATEST_RUN_ID" --log-failed || true
        
        exit 1
    fi
fi

# Get final workflow status
FINAL_RUN=$(gh run view --repo "$REPO" "$LATEST_RUN_ID" --json conclusion,status,url)
FINAL_CONCLUSION=$(echo "$FINAL_RUN" | jq -r .conclusion)
RUN_URL=$(echo "$FINAL_RUN" | jq -r .url)

if [[ "$FINAL_CONCLUSION" != "success" ]]; then
    log_error "Prepare-release workflow failed with conclusion: $FINAL_CONCLUSION"
    log_error "Workflow run URL: $RUN_URL"
    exit 1
fi

log_info "✅ Prepare-release workflow completed successfully"
log_info "Workflow run URL: $RUN_URL"

# Wait for the prepare-release PR to be created and merged
log_info "Waiting for prepare-release PR to be created and merged..."

# Function to check for prepare-release PR
check_prepare_release_pr() {
    # Look for open prepare-release PR
    OPEN_PR=$(gh pr list --repo "$REPO" --search "Prepare release" --state open --json number,title,url 2>/dev/null || echo "[]")
    OPEN_PR_COUNT=$(echo "$OPEN_PR" | jq length)
    
    if [[ "$OPEN_PR_COUNT" -gt 0 ]]; then
        echo "open"
        return 0
    fi
    
    # Look for recently merged prepare-release PR
    MERGED_PR=$(gh pr list --repo "$REPO" --search "Prepare release" --state merged --limit 1 --json number,title,url,mergedAt 2>/dev/null || echo "[]")
    MERGED_PR_COUNT=$(echo "$MERGED_PR" | jq length)
    
    if [[ "$MERGED_PR_COUNT" -gt 0 ]]; then
        MERGED_AT=$(echo "$MERGED_PR" | jq -r '.[0].mergedAt')
        # Check if merged within last 30 minutes (accounting for workflow runtime)
        if [[ -n "$MERGED_AT" ]] && [[ "$MERGED_AT" != "null" ]]; then
            MERGED_TIMESTAMP=$(date -d "$MERGED_AT" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$MERGED_AT" +%s 2>/dev/null || echo "0")
            CURRENT_TIMESTAMP=$(date +%s)
            TIME_DIFF=$((CURRENT_TIMESTAMP - MERGED_TIMESTAMP))
            
            if [[ "$TIME_DIFF" -lt 1800 ]]; then  # 30 minutes
                echo "merged"
                return 0
            fi
        fi
    fi
    
    echo "none"
    return 1
}

# Wait for PR creation/merge with timeout
TIMEOUT=1800  # 30 minutes
ELAPSED=0
SLEEP_INTERVAL=30

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    PR_STATUS=$(check_prepare_release_pr)
    
    case "$PR_STATUS" in
        "open")
            OPEN_PR=$(gh pr list --repo "$REPO" --search "Prepare release" --state open --json number,title,url)
            PR_NUMBER=$(echo "$OPEN_PR" | jq -r '.[0].number')
            PR_TITLE=$(echo "$OPEN_PR" | jq -r '.[0].title')
            PR_URL=$(echo "$OPEN_PR" | jq -r '.[0].url')
            
            log_info "Prepare-release PR found: #$PR_NUMBER - $PR_TITLE"
            log_info "PR URL: $PR_URL"
            log_warn "⚠️  The prepare-release PR must be merged before proceeding"
            log_info "Waiting for PR to be merged..."
            ;;
        "merged")
            MERGED_PR=$(gh pr list --repo "$REPO" --search "Prepare release" --state merged --limit 1 --json number,title,url)
            PR_NUMBER=$(echo "$MERGED_PR" | jq -r '.[0].number')
            PR_TITLE=$(echo "$MERGED_PR" | jq -r '.[0].title')
            PR_URL=$(echo "$MERGED_PR" | jq -r '.[0].url')
            
            log_info "✅ Prepare-release PR has been merged: #$PR_NUMBER - $PR_TITLE"
            log_info "PR URL: $PR_URL"
            break
            ;;
        "none")
            log_info "No prepare-release PR found yet, waiting..."
            ;;
    esac
    
    sleep $SLEEP_INTERVAL
    ELAPSED=$((ELAPSED + SLEEP_INTERVAL))
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
    log_error "Timeout waiting for prepare-release PR to be merged"
    log_error "Manual intervention required"
    exit 1
fi

# Final verification - ensure we have the latest changes
log_info "Verifying repository state after prepare-release PR merge..."

# Fetch latest changes
if command -v git >/dev/null 2>&1; then
    log_info "Fetching latest changes from remote..."
    git fetch origin main
    
    # Check if we need to pull changes
    LOCAL_COMMIT=$(git rev-parse HEAD)
    REMOTE_COMMIT=$(git rev-parse origin/main)
    
    if [[ "$LOCAL_COMMIT" != "$REMOTE_COMMIT" ]]; then
        log_info "Local branch is behind remote, updating..."
        git checkout main
        git reset --hard origin/main
        log_info "Repository updated to latest commit: $(git rev-parse HEAD)"
    else
        log_info "Repository is up to date"
    fi
else
    log_warn "Git not available, skipping repository state verification"
fi

log_info "✅ Prepare-release process completed successfully"
log_info "Repository is ready for tag creation"