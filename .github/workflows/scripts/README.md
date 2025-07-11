# OpenTelemetry Collector Release Scripts

This directory contains scripts that automate the OpenTelemetry Collector release process. These scripts can be run individually for debugging or as part of the automated release workflow.

## Overview

The release process is broken down into the following steps:

1. **Validation** - Check prerequisites and validate inputs
2. **Update-otel** - Ensure contrib repository is updated with latest core
3. **Prepare Release** - Trigger prepare-release workflow and wait for PR merge
4. **Push Tags** - Push beta and stable tags to trigger releases
5. **Verification** - Verify that the release was created successfully

## Scripts

### `release-validate.sh`

Validates release prerequisites and inputs.

**Usage:**
```bash
./release-validate.sh <version> [stable_version]
```

**Example:**
```bash
./release-validate.sh 0.85.0
./release-validate.sh 0.85.0 1.2.0
```

**What it does:**
- Validates version format (semantic versioning)
- Checks for release blockers in core, contrib, and releases repositories
- Verifies git configuration and working directory state
- Checks stable module changes (if stable version provided)
- Validates GitHub authentication and required tools

### `release-wait-update-otel.sh`

Waits for or triggers the update-otel workflow in opentelemetry-collector-contrib.

**Usage:**
```bash
./release-wait-update-otel.sh [--trigger-if-needed]
```

**Options:**
- `--trigger-if-needed`: Automatically trigger the workflow if not running

**What it does:**
- Checks if update-otel workflow is running in contrib repository
- Optionally triggers the workflow if not running
- Waits for workflow completion and verifies success
- Reports on any created PRs that need to be merged

### `release-prepare.sh`

Orchestrates the prepare-release workflow and waits for PR merge.

**Usage:**
```bash
./release-prepare.sh <version> [stable_version]
```

**Example:**
```bash
./release-prepare.sh 0.85.0
./release-prepare.sh 0.85.0 1.2.0
```

**What it does:**
- Triggers the existing prepare-release workflow
- Waits for workflow completion
- Monitors for prepare-release PR creation and merge
- Updates local repository state after PR merge

### `release-push-tags.sh`

Pushes release tags for beta and stable module sets.

**Usage:**
```bash
./release-push-tags.sh <version> [--stable-version=<stable_version>] [--dry-run]
```

**Example:**
```bash
./release-push-tags.sh 0.85.0
./release-push-tags.sh 0.85.0 --stable-version=1.2.0
./release-push-tags.sh 0.85.0 --dry-run
```

**Options:**
- `--stable-version=VERSION`: Also push stable tags for specified version
- `--dry-run`: Run in dry-run mode (no tags pushed)

**What it does:**
- Validates repository state and tag conflicts
- Pushes beta tags using `make push-tags MODSET=beta`
- Pushes stable tags if specified using `make push-tags MODSET=stable`
- Waits for release branch creation (triggered by beta tags)
- Waits for and verifies tag-triggered builds

### `release-verify.sh`

Verifies that the release was created successfully.

**Usage:**
```bash
./release-verify.sh <version> [--stable-version=<stable_version>]
```

**Example:**
```bash
./release-verify.sh 0.85.0
./release-verify.sh 0.85.0 --stable-version=1.2.0
```

**What it does:**
- Verifies tags exist on remote repository
- Checks release branch creation
- Validates GitHub release creation and content
- Verifies workflow runs succeeded
- Checks milestone management
- Validates tag signatures (if GPG configured)
- Scans for security vulnerabilities (if govulncheck available)

## Prerequisites

### Required Tools

All scripts require these tools to be installed:

- `gh` (GitHub CLI) - for interacting with GitHub API
- `jq` - for JSON processing
- `git` - for repository operations
- `make` - for running makefile targets (tag pushing script)
- `go` - for Go module operations (some scripts)

### Authentication

GitHub CLI must be authenticated:
```bash
gh auth login
```

### GPG Configuration (Optional)

For signed tags, configure GPG:
```bash
git config user.signingkey <your-key-id>
git config commit.gpgsign true
git config tag.gpgsign true
```

### Repository State

- Must be run from the root of the opentelemetry-collector repository
- Working directory should be clean (no uncommitted changes)
- Should be on the `main` branch and up-to-date with remote

## Usage Examples

### Full Release Process (Manual)

```bash
# 1. Validate prerequisites
./release-validate.sh 0.85.0

# 2. Ensure contrib is updated
./release-wait-update-otel.sh --trigger-if-needed

# 3. Prepare release
./release-prepare.sh 0.85.0

# 4. Push tags
./release-push-tags.sh 0.85.0

# 5. Verify release
./release-verify.sh 0.85.0
```

### Release with Stable Version

```bash
# Include stable version in relevant steps
./release-validate.sh 0.85.0 1.2.0
./release-prepare.sh 0.85.0 1.2.0
./release-push-tags.sh 0.85.0 --stable-version=1.2.0
./release-verify.sh 0.85.0 --stable-version=1.2.0
```

### Dry Run Testing

```bash
# Test tag pushing without actually pushing
./release-push-tags.sh 0.85.0 --dry-run
```

### Debugging Failed Steps

If a step fails, you can:

1. Review the script output and error messages
2. Fix any issues identified
3. Re-run the failed script
4. Continue with subsequent steps

Each script is designed to be idempotent where possible, so re-running should be safe.

## Integration with GitHub Actions

These scripts are used by the `automated-release.yml` workflow:

1. **validate-prerequisites** job runs `release-validate.sh`
2. **wait-for-update-otel** job runs `release-wait-update-otel.sh`
3. **prepare-release** job runs `release-prepare.sh`
4. **push-tags** job runs `release-push-tags.sh`
5. **verify-release** job runs `release-verify.sh`

The workflow provides:
- Manual approval gates via GitHub environments
- GPG key configuration for signed releases
- Dry-run mode for testing
- Comprehensive status reporting

## Security Considerations

### Repository Permissions

The automated workflow requires these permissions:
- `contents: write` - for creating tags and releases
- `pull-requests: write` - for interacting with PRs
- `actions: read` - for monitoring workflow runs
- `checks: read` - for checking build status

### GPG Signing

Tags and commits are signed when GPG is configured:
- Set `GPG_PRIVATE_KEY` secret in repository
- Set `GPG_PASSPHRASE` secret if key requires passphrase
- Configure git signing settings

## Troubleshooting

### Common Issues

1. **GitHub CLI not authenticated**
   ```bash
   gh auth login
   ```

2. **GPG signing errors**
   ```bash
   git config user.signingkey <key-id>
   gpg --list-secret-keys
   ```

3. **Repository not up-to-date**
   ```bash
   git fetch origin
   git checkout main
   git reset --hard origin/main
   ```

4. **Release blockers present**
   - Check GitHub issues with `release:blocker` label
   - Resolve or remove blocker labels before proceeding

5. **Update-otel workflow failures**
   - Check opentelemetry-collector-contrib repository
   - Review workflow logs for specific errors
   - May require manual intervention in contrib repository

### Getting Help

If you encounter issues:

1. Check script output for specific error messages
2. Review GitHub Actions workflow logs
3. Consult the release documentation in `docs/release.md`
4. Contact the release manager or maintainers
5. Open an issue in the repository with detailed information

## Contributing

When modifying these scripts:

1. Test locally before committing
2. Use shellcheck for shell script validation
3. Update this README if adding new scripts or changing behavior
4. Consider backward compatibility
5. Add appropriate error handling and logging