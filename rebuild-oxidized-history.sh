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
WORK="/tmp/${NAME}-prune-work"
NEW="/tmp/${NAME}-pruned.git"

SELECTED_COMMITS=$(mktemp "/tmp/${NAME}-selected.XXXXXX")
ORDERED_COMMITS=$(mktemp "/tmp/${NAME}-ordered.XXXXXX")

cleanup() {
    rm -f "$SELECTED_COMMITS" "$ORDERED_COMMITS"
}

trap cleanup EXIT

echo "============================================================"
echo " Oxidized Git History Rebuild"
echo "============================================================"
echo
echo "Source repository   : $OLD"
echo "Working repository  : $WORK"
echo "New bare repository : $NEW"
echo "Branch              : $BRANCH"
echo "Maximum revisions   : $KEEP per file"
echo

# ------------------------------------------------------------
# Safety
# ------------------------------------------------------------

if [ ! -d "$OLD" ]; then
    echo "ERROR: Source repository does not exist:"
    echo "$OLD"
    exit 1
fi

if [ "$(git --git-dir="$OLD" rev-parse --is-bare-repository)" != "true" ]; then
    echo "ERROR: Source repository is not bare."
    exit 1
fi

if ! git --git-dir="$OLD" show-ref \
    --verify \
    --quiet \
    "refs/heads/$BRANCH"; then

    echo "ERROR: Branch $BRANCH does not exist."
    exit 1
fi

if [ -e "$WORK" ]; then
    echo "ERROR: Working directory already exists:"
    echo "$WORK"
    echo
    echo "Remove it only if it is from a previous rebuild attempt."
    exit 1
fi

if [ -e "$NEW" ]; then
    echo "ERROR: Replacement repository already exists:"
    echo "$NEW"
    echo
    echo "Remove it only if it is from a previous rebuild attempt."
    exit 1
fi

echo "Running source git fsck..."
git --git-dir="$OLD" fsck --full

echo
echo "Source repository is healthy."
echo

# ------------------------------------------------------------
# Files
# ------------------------------------------------------------

mapfile -t FILES < <(
    git --git-dir="$OLD" \
        ls-tree \
        -r \
        --name-only \
        "$BRANCH"
)

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "ERROR: Repository contains no current files."
    exit 1
fi

echo "Current files:"
printf '  %s\n' "${FILES[@]}"

echo

# ------------------------------------------------------------
# Reject multi-file history
# ------------------------------------------------------------

echo "Checking commit structure..."

multi=0

while read -r commit; do

    count=$(
        git --git-dir="$OLD" \
            diff-tree \
            --root \
            --no-commit-id \
            --name-only \
            -r \
            "$commit" |
            wc -l
    )

    if [ "$count" -gt 1 ]; then
        multi=$((multi + 1))

        echo "ERROR: Commit $commit modifies $count files."

        git --git-dir="$OLD" \
            diff-tree \
            --root \
            --no-commit-id \
            --name-only \
            -r \
            "$commit"
    fi

done < <(
    git --git-dir="$OLD" rev-list "$BRANCH"
)

if [ "$multi" -ne 0 ]; then
    echo
    echo "ERROR: $multi multi-file commits found."
    echo "Standard rebuild aborted."
    exit 1
fi

echo "Commit structure is compatible."
echo

# ------------------------------------------------------------
# Create working repository
# ------------------------------------------------------------

mkdir -p "$WORK"

git -C "$WORK" init -b "$BRANCH"

git -C "$WORK" config \
    user.name \
    "Oxidized History Prune"

git -C "$WORK" config \
    user.email \
    "oxidized-prune@localhost"

: > "$SELECTED_COMMITS"
: > "$ORDERED_COMMITS"

declare -A RETAIN_COUNTS

EXPECTED_REPLAY=0

echo "Building synthetic root..."
echo

for file in "${FILES[@]}"; do

    total=$(
        git --git-dir="$OLD" \
            rev-list \
            --count \
            "$BRANCH" \
            -- "$file"
    )

    if [ "$total" -gt "$KEEP" ]; then
        retain="$KEEP"
    else
        retain="$total"
    fi

    RETAIN_COUNTS["$file"]="$retain"

    mapfile -t commits < <(
        git --git-dir="$OLD" \
            log \
            --format='%H' \
            -n "$retain" \
            "$BRANCH" \
            -- "$file"
    )

    if [ "${#commits[@]}" -ne "$retain" ]; then
        echo "ERROR: Could not retrieve expected history for:"
        echo "$file"
        exit 1
    fi

    cutoff_commit="${commits[$((retain - 1))]}"

    echo "FILE: $file"
    echo "  Existing revisions : $total"
    echo "  Retaining          : $retain"
    echo "  Root revision      : $cutoff_commit"

    if ! git --git-dir="$OLD" \
        cat-file \
        -e \
        "${cutoff_commit}:${file}" \
        2>/dev/null; then

        echo "ERROR: $file does not exist at cutoff commit."
        exit 1
    fi

    dir=$(dirname "$file")

    if [ "$dir" != "." ]; then
        mkdir -p "$WORK/$dir"
    fi

    git --git-dir="$OLD" \
        show \
        "${cutoff_commit}:${file}" \
        > "$WORK/$file"

    for ((i=0; i<retain-1; i++)); do
        echo "${commits[$i]}" >> "$SELECTED_COMMITS"
        EXPECTED_REPLAY=$((EXPECTED_REPLAY + 1))
    done

    echo

done

echo "Creating synthetic root commit..."

git -C "$WORK" add --all

git -C "$WORK" commit \
    -m "Oxidized history retention root - maximum $KEEP revisions per device"

# ------------------------------------------------------------
# Commit lookup
# ------------------------------------------------------------

declare -A WANT

while read -r commit; do

    if [ -n "$commit" ]; then
        WANT["$commit"]=1
    fi

done < "$SELECTED_COMMITS"

echo
echo "Restoring original commit order..."

while read -r commit; do

    if [[ -n "${WANT[$commit]+x}" ]]; then
        echo "$commit" >> "$ORDERED_COMMITS"
    fi

done < <(
    git --git-dir="$OLD" \
        rev-list \
        --reverse \
        "$BRANCH"
)

selected_count=$(wc -l < "$ORDERED_COMMITS")

echo
echo "Selected replay commits : $selected_count"
echo "Expected replay commits : $EXPECTED_REPLAY"
echo

if [ "$selected_count" -ne "$EXPECTED_REPLAY" ]; then
    echo "ERROR: Selected commit count mismatch."
    exit 1
fi

# ------------------------------------------------------------
# Replay
# ------------------------------------------------------------

echo "Replaying retained commits..."
echo

replayed=0

while read -r commit; do

    mapfile -t changed_files < <(
        git --git-dir="$OLD" \
            diff-tree \
            --no-commit-id \
            --name-only \
            -r \
            "$commit"
    )

    if [ "${#changed_files[@]}" -ne 1 ]; then
        echo "ERROR: Commit $commit does not modify exactly one file."
        exit 1
    fi

    file="${changed_files[0]}"

    if ! git --git-dir="$OLD" \
        cat-file \
        -e \
        "${commit}:${file}" \
        2>/dev/null; then

        echo "ERROR: Selected commit $commit deletes $file."
        exit 1
    fi

    dir=$(dirname "$file")

    if [ "$dir" != "." ]; then
        mkdir -p "$WORK/$dir"
    fi

    git --git-dir="$OLD" \
        show \
        "${commit}:${file}" \
        > "$WORK/$file"

    git -C "$WORK" add -- "$file"

    author_name=$(
        git --git-dir="$OLD" show -s --format='%an' "$commit"
    )

    author_email=$(
        git --git-dir="$OLD" show -s --format='%ae' "$commit"
    )

    author_date=$(
        git --git-dir="$OLD" show -s --format='%aI' "$commit"
    )

    committer_name=$(
        git --git-dir="$OLD" show -s --format='%cn' "$commit"
    )

    committer_email=$(
        git --git-dir="$OLD" show -s --format='%ce' "$commit"
    )

    committer_date=$(
        git --git-dir="$OLD" show -s --format='%cI' "$commit"
    )

    message_file=$(mktemp "/tmp/${NAME}-message.XXXXXX")

    git --git-dir="$OLD" \
        show \
        -s \
        --format='%B' \
        "$commit" \
        > "$message_file"

    GIT_AUTHOR_NAME="$author_name" \
    GIT_AUTHOR_EMAIL="$author_email" \
    GIT_AUTHOR_DATE="$author_date" \
    GIT_COMMITTER_NAME="$committer_name" \
    GIT_COMMITTER_EMAIL="$committer_email" \
    GIT_COMMITTER_DATE="$committer_date" \
        git -C "$WORK" \
        commit \
        --allow-empty \
        -F "$message_file"

    rm -f "$message_file"

    replayed=$((replayed + 1))

    if (( replayed % 25 == 0 )); then
        echo "Replayed $replayed / $selected_count commits..."
    fi

done < "$ORDERED_COMMITS"

echo
echo "Replay complete."
echo

# ------------------------------------------------------------
# Validate work repository
# ------------------------------------------------------------

echo "============================================================"
echo " Validation"
echo "============================================================"
echo

git -C "$WORK" fsck --full

OLD_FILE_LIST=$(mktemp "/tmp/${NAME}-old-files.XXXXXX")
NEW_FILE_LIST=$(mktemp "/tmp/${NAME}-new-files.XXXXXX")

git --git-dir="$OLD" \
    ls-tree \
    -r \
    --name-only \
    "$BRANCH" |
    sort > "$OLD_FILE_LIST"

git -C "$WORK" \
    ls-tree \
    -r \
    --name-only \
    HEAD |
    sort > "$NEW_FILE_LIST"

if ! diff -u "$OLD_FILE_LIST" "$NEW_FILE_LIST"; then

    echo "ERROR: Current file lists differ."

    rm -f "$OLD_FILE_LIST" "$NEW_FILE_LIST"
    exit 1
fi

rm -f "$OLD_FILE_LIST" "$NEW_FILE_LIST"

echo "File lists match."
echo

validation_failed=0

echo "Revision counts:"
echo

for file in "${FILES[@]}"; do

    expected="${RETAIN_COUNTS[$file]}"

    count=$(
        git -C "$WORK" \
            rev-list \
            --count \
            HEAD \
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
    echo "ERROR: Revision validation failed."
    exit 1
fi

echo
echo "Comparing current configurations:"
echo

for file in "${FILES[@]}"; do

    old_blob=$(
        git --git-dir="$OLD" \
            rev-parse \
            "${BRANCH}:${file}"
    )

    new_blob=$(
        git -C "$WORK" \
            rev-parse \
            "HEAD:${file}"
    )

    printf "%-50s " "$file"

    if [ "$old_blob" = "$new_blob" ]; then
        echo "IDENTICAL"
    else
        echo "DIFFERENT"
        validation_failed=1
    fi

done

if [ "$validation_failed" -ne 0 ]; then
    echo "ERROR: Current configuration validation failed."
    exit 1
fi

# ------------------------------------------------------------
# Bare replacement
# ------------------------------------------------------------

echo
echo "Creating bare replacement..."

git clone \
    --bare \
    "$WORK" \
    "$NEW"

git --git-dir="$NEW" \
    symbolic-ref \
    HEAD \
    "refs/heads/$BRANCH"

git --git-dir="$NEW" gc --prune=now

git --git-dir="$NEW" fsck --full

# ------------------------------------------------------------
# Bare validation
# ------------------------------------------------------------

echo
echo "Final replacement revision counts:"
echo

validation_failed=0

for file in "${FILES[@]}"; do

    expected="${RETAIN_COUNTS[$file]}"

    count=$(
        git --git-dir="$NEW" \
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

echo
echo "Final current-config comparison:"
echo

for file in "${FILES[@]}"; do

    old_blob=$(
        git --git-dir="$OLD" \
            rev-parse \
            "${BRANCH}:${file}"
    )

    new_blob=$(
        git --git-dir="$NEW" \
            rev-parse \
            "${BRANCH}:${file}"
    )

    printf "%-50s " "$file"

    if [ "$old_blob" = "$new_blob" ]; then
        echo "IDENTICAL"
    else
        echo "DIFFERENT"
        validation_failed=1
    fi

done

if [ "$validation_failed" -ne 0 ]; then
    echo
    echo "ERROR: Final replacement validation failed."
    exit 1
fi

echo
echo "============================================================"
echo " SUCCESS"
echo "============================================================"
echo
echo "Production repository has NOT been modified."
echo
echo "Original:"
echo "  $OLD"
echo
echo "Replacement:"
echo "  $NEW"
echo
echo "Repository sizes:"
du -sh "$OLD" "$NEW"

echo
echo "Original Git objects:"
git --git-dir="$OLD" count-objects -vH

echo
echo "Replacement Git objects:"
git --git-dir="$NEW" count-objects -vH
