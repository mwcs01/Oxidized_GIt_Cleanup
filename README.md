# Oxidized Git History Retention Scripts

This toolkit provides a safe, repeatable process for reducing oversized Oxidized Git repositories while preserving the newest revisions for each device configuration.

The scripts are designed for bare Git repositories stored under a configurable base directory.

The base directory is defined in a `.env` file:

```env
BASE=/etc/oxidized/configs
```

By default, the scripts look for `.env` in the same directory as the script. This allows the scripts to be moved between systems without hard-coding the Oxidized configuration path.

Example layout:

```text
/opt/oxidized-tools/
├── .env
├── oxidized_config_read.sh
├── rebuild-oxidized-history.sh
└── cutover-oxidized-history.sh
```

Example `.env`:

```env
BASE=/etc/oxidized/configs
```

They do **not** start or stop Docker or Oxidized. Oxidized should be stopped manually before the final cutover.

## Scripts

### `oxidized_config_read.sh`

Read-only audit script.

Use it to inspect an Oxidized repository before making any changes. It reports:

- Repository path and branch
- Ownership and permissions
- Repository size
- Git object statistics
- `git fsck` integrity status
- Total Git commit count
- Current config files
- Revision count per file
- Number of revisions that would be retained
- Newest revision per file
- Oldest revision that would be retained
- Multi-file commit detection

The standard rebuild process expects normal Oxidized commits to modify only one config file per commit.

Example:

```bash
/tmp/oxidized_config_read.sh devices.git 50
```

Optional branch:

```bash
/tmp/oxidized_config_read.sh devices.git 50 master
```

Usage:

```text
oxidized_config_read.sh <repository.git> [keep-count] [branch]
```

Defaults:

```text
keep-count = 50
branch     = master
```

---

### `rebuild-oxidized-history.sh`

Builds a new pruned repository under `/tmp` without modifying the production repository.

For each current config file:

- If it has more than the requested retention count, only the newest revisions are retained.
- If it has fewer than the requested retention count, all available revisions are retained.
- Current/latest config contents are preserved exactly.
- Original commit messages, author information, and timestamps are preserved for replayed commits.
- A synthetic root commit is created to represent the oldest retained revision for each current config.
- The new repository is packed with `git gc`.
- The rebuilt repository is validated with `git fsck`.
- Current file lists are compared.
- Final config blobs are compared byte-for-byte.

Example:

```bash
/tmp/rebuild-oxidized-history.sh devices.git 50
```

Usage:

```text
rebuild-oxidized-history.sh <repository.git> [keep-count] [branch]
```

For `devices.git`, the rebuild creates:

```text
/tmp/devices-prune-work
/tmp/devices-pruned.git
```

The active repository remains unchanged:

```text
/etc/oxidized/configs/devices.git
```

Do not proceed to cutover unless the rebuild completes successfully and reports that all current configurations are `IDENTICAL`.

---

### `cutover-oxidized-history.sh`

Replaces the production repository with the validated pruned repository.

This script does **not** start or stop Docker or Oxidized.

Before running it:

1. Stop Oxidized manually.
2. Confirm the rebuild completed successfully.
3. Confirm the replacement repository exists under `/tmp`.

The cutover script:

- Copies the replacement repository into a staging location.
- Preserves numeric UID, GID, and directory mode.
- Runs `git fsck` against the staged repository.
- Re-compares all live config blobs before cutover.
- Re-validates revision counts.
- Moves the current production repository to a timestamped backup.
- Promotes the staged repository into production.
- Runs another `git fsck`.
- Re-validates current configs.
- Re-validates retained revision counts.
- Verifies ownership after cutover.
- Leaves the rollback repository intact.

Example:

```bash
/tmp/cutover-oxidized-history.sh devices.git 50
```

Usage:

```text
cutover-oxidized-history.sh <repository.git> [keep-count] [branch]
```

A rollback repository is automatically created with a name similar to:

```text
/etc/oxidized/configs/devices.git.before-prune-20260812-120500
```

Do not delete the rollback repository until Oxidized has been restarted manually and has successfully written new commits to the new production repository.

## Recommended Workflow

For `devices.git` with a 50-revision retention target:

```bash
chmod 750 /tmp/oxidized_config_read.sh
chmod 750 /tmp/rebuild-oxidized-history.sh
chmod 750 /tmp/cutover-oxidized-history.sh
```

Run the audit:

```bash
/tmp/oxidized_config_read.sh devices.git 50
```

Confirm:

```text
Multi-file commits found   : 0
```

Then rebuild:

```bash
/tmp/rebuild-oxidized-history.sh devices.git 50
```

Verify the rebuild finishes successfully and that current configs report:

```text
IDENTICAL
```

Stop Oxidized manually before cutover.

Then run:

```bash
/tmp/cutover-oxidized-history.sh devices.git 50
```

After a successful cutover, verify:

```bash
git --git-dir=/etc/oxidized/configs/devices.git fsck --full
```

Check recent commits:

```bash
git --git-dir=/etc/oxidized/configs/devices.git log --oneline --decorate -10
```

Check repository size:

```bash
du -sh /etc/oxidized/configs/devices.git
```

Check object statistics:

```bash
git --git-dir=/etc/oxidized/configs/devices.git count-objects -vH
```

Then start Oxidized manually using the normal Docker or Docker Compose procedure.

After Oxidized completes at least one polling cycle, confirm new commits can be written normally.

## Safety Notes

These scripts are intentionally conservative.

The audit and rebuild stages do not modify the active repository.

The cutover script aborts before swapping repositories if:

- The replacement repository is missing.
- The repository is not bare.
- The configured branch does not exist.
- The staged repository fails `git fsck`.
- The production and replacement file lists differ.
- Any current config blob differs.
- Revision counts do not match the expected retained counts.

The production repository is renamed to a timestamped backup before the replacement is promoted.

## Docker Ownership

The Oxidized repositories may appear on the host with numeric ownership such as:

```text
UID: 30000
GID: 30000
```

This is normal when the user exists inside the Docker container but not on the host.

The cutover script preserves the numeric UID and GID rather than changing ownership to `root` or the host administrator account.

Example:

```text
Owner: UNKNOWN (30000)
Group: UNKNOWN (30000)
Mode : 755
```

This should remain unchanged after cutover.

## Rollback

If a rollback is required after cutover, keep Oxidized stopped and restore the backup repository.

Example:

```bash
sudo mv /etc/oxidized/configs/devices.git /etc/oxidized/configs/devices.git.failed
sudo mv /etc/oxidized/configs/devices.git.before-prune-YYYYMMDD-HHMMSS /etc/oxidized/configs/devices.git
```

Then validate:

```bash
sudo git --git-dir=/etc/oxidized/configs/devices.git fsck --full
```

After validation, start Oxidized manually.

## Important Retention Behavior

The pruning process is a one-time history reduction.

If a device has 50 retained revisions and Oxidized later records another change, that device will have 51 revisions.

These scripts do not automatically enforce a rolling 50-revision limit.

To keep repositories permanently bounded, run the audit/rebuild/cutover process periodically during a maintenance window or build a separate controlled retention workflow.

## Example Successful Result

A large repository can shrink dramatically after history reconstruction and packing.

Example:

```text
Before:
3.1G repository
104019 loose objects

After:
2.0M repository
1038 packed objects
50 revisions per device
git fsck clean
current configs IDENTICAL
```

## Requirements

The scripts expect:

- Bash
- Git
- `sudo` for the cutover phase
- Bare Git repositories under `/etc/oxidized/configs`
- Sufficient free space under `/tmp`
- Oxidized stopped manually during cutover
- One-file-per-commit Oxidized history for the standard rebuild process

## Summary

The normal sequence is:

```text
audit
  |
  v
rebuild under /tmp
  |
  v
validate
  |
  v
stop Oxidized manually
  |
  v
cutover
  |
  v
validate production
  |
  v
start Oxidized manually
  |
  v
verify new commits
  |
  v
retain rollback copy until satisfied
```
