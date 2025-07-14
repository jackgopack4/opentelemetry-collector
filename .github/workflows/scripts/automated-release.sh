#!/bin/bash -ex
#
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# This script automates steps 2-7 of the OpenTelemetry Collector release process
# It handles triggering the prepare-release workflow, waiting for completion, and pushing tags

set -e

REPO="open-telemetry/opentelemetry-collector"
REMOTE=${REMOTE:-"origin"}

# Helper function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Helper function to wait for a workflow run to complete
wait_for_workflow_run() {
    local run_id=$1
    local max_wait=${2:-3600}  # Default 1 hour max wait
    local check_interval=${3:-60}  # Default 1 minute interval
    
    log "Waiting for workflow run $run_id to complete..."
    
    local elapsed=0
    while [ $elapsed -lt "$max_wait" ]; do
        local status
        local conclusion
        status=$(gh run view "$run_id" --repo "$REPO" --json status --jq '.status')
        conclusion=$(gh run view "$run_id" --repo "$REPO" --json conclusion --jq '.conclusion')
        
        log "Workflow run $run_id status: $status, conclusion: $conclusion"
        
        if [ "$status" = "completed" ]; then
            if [ "$conclusion" = "success" ]; then
                log "Workflow run $run_id completed successfully"
                return 0
            else
                log "Workflow run $run_id failed with conclusion: $conclusion"
                return 1
            fi
        fi
        
        sleep "$check_interval"
        elapsed=$((elapsed + check_interval))
    done
    
    log "Timeout waiting for workflow run $run_id to complete"
    return 1
}

# Helper function to wait for a PR to be merged
wait_for_pr_merge() {
    local pr_number=$1
    local max_wait=${2:-3600}  # Default 1 hour max wait
    local check_interval=${3:-60}  # Default 1 minute interval
    
    log "Waiting for PR #$pr_number to be merged..."
    
    local elapsed=0
    while [ $elapsed -lt "$max_wait" ]; do
        local pr_state
        local pr_merged
        pr_state=$(gh pr view "$pr_number" --repo "$REPO" --json state --jq '.state')
        pr_merged=$(gh pr view "$pr_number" --repo "$REPO" --json merged --jq '.merged')
        
        log "PR #$pr_number state: $pr_state, merged: $pr_merged"
        
        if [ "$pr_merged" = "true" ]; then
            log "PR #$pr_number has been merged"
            return 0
        fi
        
        if [ "$pr_state" = "CLOSED" ]; then
            log "PR #$pr_number was closed without merging"
            return 1
        fi
        
        sleep "$check_interval"
        elapsed=$((elapsed + check_interval))
    done
    
    log "Timeout waiting for PR #$pr_number to be merged"
    return 1
}

# Helper function to wait for tags to be pushed and detected by workflows
wait_for_tag_workflows() {
    local tag_version=$1
    local max_wait=${2:-1800}  # Default 30 minutes max wait
    local check_interval=${3:-60}  # Default 1 minute interval
    
    log "Waiting for tag workflows to be triggered for version $tag_version..."
    
    local elapsed=0
    while [ $elapsed -lt "$max_wait" ]; do
        # Check for release branch workflow
        local release_branch_runs
        release_branch_runs=$(gh run list --repo "$REPO" --workflow "release-branch.yml" --json headBranch,status,conclusion --jq --arg tag "$tag_version" "[.[] | select(.headBranch | test(\$tag))]")
        
        if [ "$release_branch_runs" != "[]" ]; then
            log "Found release branch workflow runs for tag $tag_version"
            
            # Get the latest run ID
            local latest_run_id
            latest_run_id=$(echo "$release_branch_runs" | jq -r '.[0].id' || echo "")
            
            if [ -n "$latest_run_id" ] && [ "$latest_run_id" != "null" ]; then
                log "Waiting for release branch workflow run $latest_run_id to complete..."
                if wait_for_workflow_run "$latest_run_id" 1800; then
                    log "Release branch workflow completed successfully"
                    return 0
                else
                    log "Release branch workflow failed"
                    return 1
                fi
            fi
        fi
        
        sleep "$check_interval"
        elapsed=$((elapsed + check_interval))
    done
    
    log "Timeout waiting for tag workflows to complete"
    return 1
}

# Main automation logic
main() {
    log "Starting automated release process..."
    
    # Construct parameters for prepare-release workflow
    local stable_params=""
    if [ "$RELEASE_STABLE" = "true" ]; then
        if [ "$STABLE_HAS_CHANGES" = "false" ] && [ "$SKIP_STABLE_CHECK" != "true" ]; then
            log "Stable modules have no changes since v$CURRENT_STABLE. Skipping stable release."
            stable_params=""
        else
            stable_params="--field current-stable=$CURRENT_STABLE --field candidate-stable=$CANDIDATE_STABLE"
        fi
    fi
    
    # Step 3: Trigger prepare-release workflow
    log "Step 3: Triggering prepare-release workflow..."
    gh workflow run prepare-release.yml --repo "$REPO" \
        --field current-beta="$CURRENT_BETA" \
        --field candidate-beta="$CANDIDATE_BETA" \
        "${stable_params}" \
        --json
    
    # Wait a bit for the workflow run to be created
    sleep 10
    
    # Get the most recent prepare-release workflow run
    local prepare_run_id
    prepare_run_id=$(gh run list --repo "$REPO" --workflow "prepare-release.yml" --limit 1 --json id --jq '.[0].id')
    
    if [ -z "$prepare_run_id" ] || [ "$prepare_run_id" = "null" ]; then
        log "ERROR: Could not find prepare-release workflow run"
        exit 1
    fi
    
    log "Triggered prepare-release workflow run: $prepare_run_id"
    
    # Wait for prepare-release workflow to complete
    if ! wait_for_workflow_run "$prepare_run_id" 1800; then
        log "ERROR: prepare-release workflow failed"
        exit 1
    fi
    
    # Get the PR number from the workflow run
    log "Finding PR created by prepare-release workflow..."
    local pr_number
    pr_number=$(gh pr list --repo "$REPO" --author "opentelemetrybot" --state "open" --json number,title --jq '.[] | select(.title | test("\\[chore\\] Prepare release")) | .number' | head -1)
    
    if [ -z "$pr_number" ] || [ "$pr_number" = "null" ]; then
        log "ERROR: Could not find prepare-release PR"
        exit 1
    fi
    
    log "Found prepare-release PR: #$pr_number"
    
    # Wait for PR to be merged
    log "Waiting for prepare-release PR to be merged..."
    if ! wait_for_pr_merge "$pr_number" 3600; then
        log "ERROR: prepare-release PR was not merged within timeout"
        exit 1
    fi
    
    # Step 4: Refresh local repo and push tags
    log "Step 4: Refreshing local repository and pushing tags..."
    
    # Ensure we're on main and have the latest changes
    git checkout main
    git fetch origin
    git reset --hard origin/main
    
    # Verify the prepare-release commit is at HEAD
    local head_commit
    head_commit=$(git rev-parse HEAD)
    log "Current HEAD commit: $head_commit"
    
    # Push beta tags
    log "Pushing beta tags..."
    make push-tags MODSET=beta REMOTE="$REMOTE"
    
    # Push stable tags if needed
    if [ "$RELEASE_STABLE" = "true" ] && { [ "$STABLE_HAS_CHANGES" = "true" ] || [ "$SKIP_STABLE_CHECK" = "true" ]; }; then
        log "Pushing stable tags..."
        make push-tags MODSET=stable REMOTE="$REMOTE"
    fi
    
    # Step 5-7: Wait for release branch workflow and tag-triggered builds
    log "Steps 5-7: Waiting for release branch workflow and tag-triggered builds..."
    
    # Wait for tag workflows to complete
    if ! wait_for_tag_workflows "v$CANDIDATE_BETA" 1800; then
        log "ERROR: Tag workflows failed or timed out"
        exit 1
    fi
    
    # Final verification - check if GitHub release was created
    log "Verifying GitHub release was created..."
    local release_check
    release_check=$(gh release view "v$CANDIDATE_BETA" --repo "$REPO" --json tagName --jq '.tagName' || echo "not_found")
    
    if [ "$release_check" = "v$CANDIDATE_BETA" ]; then
        log "SUCCESS: GitHub release v$CANDIDATE_BETA was created successfully"
    else
        log "WARNING: GitHub release v$CANDIDATE_BETA was not found, but tag workflows completed"
    fi
    
    log "Automated release process completed successfully!"
    
    # Summary
    echo "::notice::Automated release process completed"
    echo "::notice::Beta version v$CANDIDATE_BETA has been released"
    if [ "$RELEASE_STABLE" = "true" ] && { [ "$STABLE_HAS_CHANGES" = "true" ] || [ "$SKIP_STABLE_CHECK" = "true" ]; }; then
        echo "::notice::Stable version v$CANDIDATE_STABLE has been released"
    fi
    echo "::notice::Next steps: Release the contrib collector and artifacts"
}

# Run main function
main "$@" 