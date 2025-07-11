#!/bin/bash

# Script to wait for or trigger the update-otel workflow in opentelemetry-collector-contrib
# Usage: ./release-wait-update-otel.sh [--trigger-if-needed]

set -euo pipefail

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

TRIGGER_IF_NEEDED=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --trigger-if-needed)
            TRIGGER_IF_NEEDED=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--trigger-if-needed]"
            echo ""
            echo "Options:"
            echo "  --trigger-if-needed    Trigger update-otel workflow if not running"
            echo "  -h, --help            Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if required tools are available
command -v gh >/dev/null 2>&1 || { log_error "GitHub CLI (gh) is required but not installed"; exit 1; }
command -v jq >/dev/null 2>&1 || { log_error "jq is required but not installed"; exit 1; }

# Check GitHub authentication
if ! gh auth status >/dev/null 2>&1; then
    log_error "GitHub CLI is not authenticated. Run 'gh auth login' first"
    exit 1
fi

CONTRIB_REPO="open-telemetry/opentelemetry-collector-contrib"
WORKFLOW_NAME="update-otel.yaml"

log_info "Checking status of update-otel workflow in $CONTRIB_REPO..."

# Check if update-otel workflow is currently running
RUNNING_WORKFLOWS=$(gh run list --repo "$CONTRIB_REPO" --workflow "$WORKFLOW_NAME" --status in_progress --json id,status 2>/dev/null || echo "[]")
RUNNING_COUNT=$(echo "$RUNNING_WORKFLOWS" | jq length)

if [[ "$RUNNING_COUNT" -gt 0 ]]; then
    log_info "Update-otel workflow is currently running ($RUNNING_COUNT workflow(s))"
    
    # Wait for all running workflows to complete
    echo "$RUNNING_WORKFLOWS" | jq -r '.[].id' | while read -r run_id; do
        log_info "Waiting for workflow run $run_id to complete..."
        if ! gh run watch --repo "$CONTRIB_REPO" "$run_id" --exit-status; then
            log_error "Workflow run $run_id failed"
            exit 1
        fi
    done
    
    LATEST_RUN_ID=$(echo "$RUNNING_WORKFLOWS" | jq -r '.[0].id')
else
    log_info "No update-otel workflow is currently running"
    
    # Check the status of the most recent run
    LATEST_RUN=$(gh run list --repo "$CONTRIB_REPO" --workflow "$WORKFLOW_NAME" --limit 1 --json id,conclusion,status 2>/dev/null || echo "[]")
    LATEST_RUN_COUNT=$(echo "$LATEST_RUN" | jq length)
    
    if [[ "$LATEST_RUN_COUNT" -eq 0 ]]; then
        log_warn "No previous update-otel workflow runs found"
        if [[ "$TRIGGER_IF_NEEDED" == "true" ]]; then
            log_info "Triggering update-otel workflow..."
            gh workflow run --repo "$CONTRIB_REPO" "$WORKFLOW_NAME"
            
            # Wait for the workflow to start
            log_info "Waiting for workflow to start..."
            sleep 30
            
            # Get the latest run ID
            LATEST_RUN=$(gh run list --repo "$CONTRIB_REPO" --workflow "$WORKFLOW_NAME" --limit 1 --json id,conclusion,status)
            LATEST_RUN_ID=$(echo "$LATEST_RUN" | jq -r '.[0].id')
            
            # Wait for completion
            log_info "Waiting for workflow run $LATEST_RUN_ID to complete..."
            if ! gh run watch --repo "$CONTRIB_REPO" "$LATEST_RUN_ID" --exit-status; then
                log_error "Triggered workflow run failed"
                exit 1
            fi
        else
            log_error "No recent update-otel workflow runs found and --trigger-if-needed not specified"
            exit 1
        fi
    else
        LATEST_RUN_ID=$(echo "$LATEST_RUN" | jq -r '.[0].id')
        LATEST_CONCLUSION=$(echo "$LATEST_RUN" | jq -r '.[0].conclusion')
        LATEST_STATUS=$(echo "$LATEST_RUN" | jq -r '.[0].status')
        
        if [[ "$LATEST_STATUS" == "completed" ]]; then
            if [[ "$LATEST_CONCLUSION" == "success" ]]; then
                log_info "Most recent update-otel workflow (run $LATEST_RUN_ID) completed successfully"
            else
                log_error "Most recent update-otel workflow (run $LATEST_RUN_ID) failed with conclusion: $LATEST_CONCLUSION"
                
                if [[ "$TRIGGER_IF_NEEDED" == "true" ]]; then
                    log_info "Triggering new update-otel workflow due to previous failure..."
                    gh workflow run --repo "$CONTRIB_REPO" "$WORKFLOW_NAME"
                    
                    # Wait for the workflow to start
                    log_info "Waiting for workflow to start..."
                    sleep 30
                    
                    # Get the latest run ID
                    LATEST_RUN=$(gh run list --repo "$CONTRIB_REPO" --workflow "$WORKFLOW_NAME" --limit 1 --json id,conclusion,status)
                    LATEST_RUN_ID=$(echo "$LATEST_RUN" | jq -r '.[0].id')
                    
                    # Wait for completion
                    log_info "Waiting for workflow run $LATEST_RUN_ID to complete..."
                    if ! gh run watch --repo "$CONTRIB_REPO" "$LATEST_RUN_ID" --exit-status; then
                        log_error "Triggered workflow run failed"
                        exit 1
                    fi
                else
                    log_error "Previous update-otel workflow failed and --trigger-if-needed not specified"
                    exit 1
                fi
            fi
        else
            log_error "Most recent update-otel workflow (run $LATEST_RUN_ID) is in unexpected state: $LATEST_STATUS"
            exit 1
        fi
    fi
fi

# Final verification
log_info "Verifying final status of update-otel workflow..."
FINAL_RUN=$(gh run list --repo "$CONTRIB_REPO" --workflow "$WORKFLOW_NAME" --limit 1 --json id,conclusion,status)
FINAL_CONCLUSION=$(echo "$FINAL_RUN" | jq -r '.[0].conclusion')
FINAL_RUN_ID=$(echo "$FINAL_RUN" | jq -r '.[0].id')

if [[ "$FINAL_CONCLUSION" == "success" ]]; then
    log_info "✅ Update-otel workflow completed successfully (run $FINAL_RUN_ID)"
    
    # Get the URL for the workflow run
    RUN_URL=$(gh run view --repo "$CONTRIB_REPO" "$FINAL_RUN_ID" --json url | jq -r .url)
    log_info "Workflow run URL: $RUN_URL"
    
    # Check if a PR was created
    log_info "Checking if update-otel PR was created..."
    RECENT_PRS=$(gh pr list --repo "$CONTRIB_REPO" --author app/github-actions --search "update core" --limit 1 --json number,title,url 2>/dev/null || echo "[]")
    PR_COUNT=$(echo "$RECENT_PRS" | jq length)
    
    if [[ "$PR_COUNT" -gt 0 ]]; then
        PR_NUMBER=$(echo "$RECENT_PRS" | jq -r '.[0].number')
        PR_TITLE=$(echo "$RECENT_PRS" | jq -r '.[0].title')
        PR_URL=$(echo "$RECENT_PRS" | jq -r '.[0].url')
        log_info "Update-otel PR created: #$PR_NUMBER - $PR_TITLE"
        log_info "PR URL: $PR_URL"
        
        # Note: The PR needs to be merged before proceeding with core release
        log_warn "⚠️  The update-otel PR must be merged before proceeding with the core release"
    else
        log_info "No update-otel PR found (may have been merged already or not needed)"
    fi
else
    log_error "❌ Update-otel workflow failed with conclusion: $FINAL_CONCLUSION"
    exit 1
fi

log_info "Update-otel workflow check completed successfully"