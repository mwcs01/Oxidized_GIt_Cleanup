#!/usr/bin/env bash

set -euo pipefail

# ------------------------------------------------------------

# Load configuration

# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then

    echo "ERROR: Configuration file not found:"

    echo "$ENV_FILE"

    exit 1

fi

set -a

# shellcheck disable=SC1090

source "$ENV_FILE"

set +a

if [ -z "${BASE:-}" ]; then

    echo "ERROR: BASE is not defined in:"

    echo "$ENV_FILE"

    exit 1

fi

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    echo "Usage:"
    echo "  $0 <repository.git> [keep-count] [branch]"
    echo
    echo "Examples:"
    echo "  $0 devices.git"
    echo "  $0 devices.git 50"
    echo "  $0 devices.git 50 master"
    exit 1
fi

REPO_NAME="$1"
KEEP="${2:-50}"
BRANCH="${3:-master}"

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then
    echo "ERROR: keep-count must be a positive integer."
    exit 1
fi

NAME="${REPO_NAME%.git}"

OLD="$BASE/$REPO_NAME"
NEW="/tmp/${NAME}-pruned.git"

STAGE="$BASE/${NAME}.new.git"

TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
BACKUP="$BASE/${REPO_NAME}.before-prune-${TIMESTAMP}"

echo "============================================================"
echo " Oxidized Git Repository Cutover"
echo "============================================================"
echo
echo "Active repository     : $OLD"
echo "Validated replacement : $NEW"
echo "Staging repository    : $STAGE"
echo "Backup repository     : $BACKUP"
echo "Branch                : $BRANCH"
echo "Maximum revisions     : $KEEP"
echo
echo "IMPORTANT:"
echo "Oxidized must already be stopped."
echo "This script does NOT start or stop Docker/Oxidized."
echo

# ------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------

if [ ! -d "$OLD" ]; then
    echo "ERROR: Production repository does not exist:"
    echo "$OLD"
    exit 1
fi

if [ ! -d "$NEW" ]; then
    echo "ERROR: Replacement repository does not exist:"
    echo "$NEW"
    echo
    echo "Run rebuild-oxidized-history.sh first."
    exit 1
fi

if [ "$(git --git-dir="$OLD" rev-parse --is-bare-repository)" != "true" ]; then
    echo "ERROR: Production repository is not bare."
    exit 1
fi

if [ "$(git --git-dir="$NEW" rev-parse --is-bare-repository)" != "true" ]; then
    echo "ERROR: Replacement repository is not bare."
    exit 1
fi

if [ -e "$STAGE" ]; then
    echo "ERROR: Staging repository already exists:"
    echo "$STAGE"
    exit 1
fi

if [ -e "$BACKUP" ]; then
    echo "ERROR: Backup path already exists:"
    echo "$BACKUP"
    exit 1
fi

OLD_UID=$(stat -c '%u' "$OLD")
OLD_GID=$(stat -c '%g' "$OLD")
OLD_MODE=$(stat -c '%a' "$OLD")

echo "Production ownership:"
echo "  UID  : $OLD_UID"
echo "  GID  : $OLD_GID"
echo "  Mode : $OLD_MODE"
echo

# ------------------------------------------------------------
# Stage replacement
# ------------------------------------------------------------

echo "Copying replacement into staging..."

sudo cp -a "$NEW" "$STAGE"

sudo chown -R \
    "$OLD_UID:$OLD_GID" \
    "$STAGE"

sudo chmod \
    "$OLD_MODE" \
    "$STAGE"

echo
echo "Checking staged repository..."

sudo git --git-dir="$STAGE" fsck --full

# ------------------------------------------------------------
# File lists
# ------------------------------------------------------------

mapfile -t OLD_FILES < <(
    git --git-dir="$OLD" \
        ls-tree \
        -r \
        --name-only \
        "$BRANCH" |
        sort
)

mapfile -t NEW_FILES < <(
    sudo git --git-dir="$STAGE" \
        ls-tree \
        -r \
        --name-only \
        "$BRANCH" |
        sort
)

if [ "${#OLD_FILES[@]}" -ne "${#NEW_FILES[@]}" ]; then
    echo "ERROR: Production and replacement file counts differ."
    exit 1
fi

for ((i=0; i<${#OLD_FILES[@]}; i++)); do

    if [ "${OLD_FILES[$i]}" != "${NEW_FILES[$i]}" ]; then
        echo "ERROR: File lists differ."
        echo "OLD: ${OLD_FILES[$i]}"
        echo "NEW: ${NEW_FILES[$i]}"
        exit 1
    fi

done

# ------------------------------------------------------------
# Current config validation
# ------------------------------------------------------------

echo
echo "Comparing live configurations..."
echo

validation_failed=0

for file in "${OLD_FILES[@]}"; do

    live_blob=$(
        git --git-dir="$OLD" \
            rev-parse \
            "${BRANCH}:${file}"
    )

    new_blob=$(
        sudo git --git-dir="$STAGE" \
            rev-parse \
            "${BRANCH}:${file}"
    )

    printf "%-50s " "$file"

    if [ "$live_blob" = "$new_blob" ]; then
        echo "IDENTICAL"
    else
        echo "CHANGED"
        validation_failed=1
    fi

done

if [ "$validation_failed" -ne 0 ]; then
    echo
    echo "CUTOVER ABORTED."
    echo "The live repository differs from the rebuilt repository."
    echo "Nothing has been swapped."
    exit 1
fi

# ------------------------------------------------------------
# Expected revision counts
# ------------------------------------------------------------

echo
echo "Checking staged revision counts..."
echo

declare -A EXPECTED

for file in "${OLD_FILES[@]}"; do

    original_count=$(
        git --git-dir="$OLD" \
            rev-list \
            --count \
            "$BRANCH" \
            -- "$file"
    )

    if [ "$original_count" -gt "$KEEP" ]; then
        expected="$KEEP"
    else
        expected="$original_count"
    fi

    EXPECTED["$file"]="$expected"

    staged_count=$(
        sudo git --git-dir="$STAGE" \
            rev-list \
            --count \
            "$BRANCH" \
            -- "$file"
    )

    printf "%-50s %8s / %-8s" \
        "$file" \
        "$staged_count" \
        "$expected"

    if [ "$staged_count" -eq "$expected" ]; then
        echo " OK"
    else
        echo " FAILED"
        validation_failed=1
    fi

done

if [ "$validation_failed" -ne 0 ]; then
    echo
    echo "CUTOVER ABORTED."
    echo "Revision validation failed."
    exit 1
fi

# ------------------------------------------------------------
# Cutover
# ------------------------------------------------------------

echo
echo "============================================================"
echo " REPOSITORY CUTOVER"
echo "============================================================"
echo

echo "Moving current production repository to:"
echo "$BACKUP"

sudo mv \
    "$OLD" \
    "$BACKUP"

echo
echo "Promoting staged repository..."

if ! sudo mv "$STAGE" "$OLD"; then

    echo
    echo "ERROR: Promotion failed."
    echo "Attempting rollback."

    if [ ! -e "$OLD" ] && [ -e "$BACKUP" ]; then
        sudo mv "$BACKUP" "$OLD"
    fi

    exit 1
fi

sudo chown -R \
    "$OLD_UID:$OLD_GID" \
    "$OLD"

sudo chmod \
    "$OLD_MODE" \
    "$OLD"

# ------------------------------------------------------------
# Production validation
# ------------------------------------------------------------

echo
echo "Running production fsck..."

if ! sudo git --git-dir="$OLD" fsck --full; then

    echo
    echo "ERROR: Production fsck failed."
    echo "Automatically restoring original repository."

    sudo mv \
        "$OLD" \
        "${OLD}.failed"

    sudo mv \
        "$BACKUP" \
        "$OLD"

    exit 1
fi

echo
echo "Validating production configs..."
echo

validation_failed=0

for file in "${OLD_FILES[@]}"; do

    production_blob=$(
        sudo git --git-dir="$OLD" \
            rev-parse \
            "${BRANCH}:${file}"
    )

    replacement_blob=$(
        git --git-dir="$NEW" \
            rev-parse \
            "${BRANCH}:${file}"
    )

    printf "%-50s " "$file"

    if [ "$production_blob" = "$replacement_blob" ]; then
        echo "IDENTICAL"
    else
        echo "FAILED"
        validation_failed=1
    fi

done

echo
echo "Production revision counts:"
echo

for file in "${OLD_FILES[@]}"; do

    expected="${EXPECTED[$file]}"

    count=$(
        sudo git --git-dir="$OLD" \
            rev-list \
            --count \
            "$BRANCH" \
            -- "$file"
    )

    printf "%-50s %8s / %-8s" \
        "$file" \
        "$count" \
        "$expected"

    if [ "$count" -eq "$expected" ]; then
        echo " OK"
    else
        echo " FAILED"
        validation_failed=1
    fi

done

if [ "$validation_failed" -ne 0 ]; then

    echo
    echo "ERROR: Final production validation failed."
    echo
    echo "Rollback repository remains at:"
    echo "$BACKUP"

    exit 1
fi

# ------------------------------------------------------------
# Ownership validation
# ------------------------------------------------------------

CURRENT_UID=$(stat -c '%u' "$OLD")
CURRENT_GID=$(stat -c '%g' "$OLD")
CURRENT_MODE=$(stat -c '%a' "$OLD")

echo
echo "Production ownership:"
echo "  UID  : $CURRENT_UID"
echo "  GID  : $CURRENT_GID"
echo "  Mode : $CURRENT_MODE"

if [ "$CURRENT_UID" != "$OLD_UID" ] ||
   [ "$CURRENT_GID" != "$OLD_GID" ]; then

    echo
    echo "ERROR: Ownership changed unexpectedly."
    exit 1
fi

# ------------------------------------------------------------
# Results
# ------------------------------------------------------------

echo
echo "============================================================"
echo " CUTOVER SUCCESSFUL"
echo "============================================================"
echo
echo "Production:"
echo "  $OLD"
echo
echo "Rollback:"
echo "  $BACKUP"
echo
echo "Production size:"
sudo du -sh "$OLD"

echo
echo "Rollback size:"
sudo du -sh "$BACKUP"

echo
echo "Production Git statistics:"
sudo git --git-dir="$OLD" count-objects -vH

echo
echo "Latest commits:"
sudo git --git-dir="$OLD" \
    log \
    --oneline \
    --decorate \
    -10

echo
echo "Oxidized/Docker was NOT started or stopped."
echo "Keep the rollback repository until the new repo has"
echo "successfully received normal Oxidized commits."
