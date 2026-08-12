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

REPO="$BASE/$REPO_NAME"

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then
    echo "ERROR: keep-count must be a positive integer."
    exit 1
fi

echo "============================================================"
echo " Oxidized Repository Audit"
echo "============================================================"
echo
echo "Repository : $REPO"
echo "Branch     : $BRANCH"
echo "Retention  : $KEEP revisions per file"
echo

if [ ! -d "$REPO" ]; then
    echo "ERROR: Repository does not exist:"
    echo "$REPO"
    exit 1
fi

if [ "$(git --git-dir="$REPO" rev-parse --is-bare-repository)" != "true" ]; then
    echo "ERROR: Repository is not bare:"
    echo "$REPO"
    exit 1
fi

if ! git --git-dir="$REPO" show-ref \
    --verify \
    --quiet \
    "refs/heads/$BRANCH"; then

    echo "ERROR: Branch does not exist:"
    echo "$BRANCH"
    exit 1
fi

echo "Repository ownership:"
stat -c '  Owner: %U (%u)' "$REPO"
stat -c '  Group: %G (%g)' "$REPO"
stat -c '  Mode : %a' "$REPO"

echo
echo "Repository size:"
du -sh "$REPO"

echo
echo "Git object statistics:"
git --git-dir="$REPO" count-objects -vH

echo
echo "Repository integrity:"
git --git-dir="$REPO" fsck --full

echo
echo "HEAD:"
git --git-dir="$REPO" log \
    -1 \
    --oneline \
    --decorate \
    "$BRANCH"

echo
echo "Total Git commits:"
git --git-dir="$REPO" rev-list \
    --count \
    "$BRANCH"

echo
echo "Current files:"
echo

mapfile -t FILES < <(
    git --git-dir="$REPO" \
        ls-tree \
        -r \
        --name-only \
        "$BRANCH"
)

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "ERROR: No files exist at $BRANCH."
    exit 1
fi

printf '  %s\n' "${FILES[@]}"

echo
echo "============================================================"
echo " Revision Counts"
echo "============================================================"
echo

TOTAL_REVISIONS=0
TOTAL_RETAINED=0

for file in "${FILES[@]}"; do

    count=$(
        git --git-dir="$REPO" \
            rev-list \
            --count \
            "$BRANCH" \
            -- "$file"
    )

    newest=$(
        git --git-dir="$REPO" \
            log \
            -1 \
            --format='%H|%ci' \
            "$BRANCH" \
            -- "$file"
    )

    if [ "$count" -gt "$KEEP" ]; then
        retained="$KEEP"
    else
        retained="$count"
    fi

    oldest_retained=$(
        git --git-dir="$REPO" \
            log \
            -n "$retained" \
            --format='%H|%ci' \
            "$BRANCH" \
            -- "$file" |
            tail -1
    )

    TOTAL_REVISIONS=$((TOTAL_REVISIONS + count))
    TOTAL_RETAINED=$((TOTAL_RETAINED + retained))

    echo "FILE: $file"
    echo "  Total revisions  : $count"
    echo "  Will retain      : $retained"
    echo "  Newest revision  : $newest"
    echo "  Oldest retained  : $oldest_retained"
    echo

done

echo "============================================================"
echo " Commit Structure Check"
echo "============================================================"
echo

echo "Checking entire repository for multi-file commits..."

MULTI=0

while read -r commit; do

    mapfile -t changed_files < <(
        git --git-dir="$REPO" \
            diff-tree \
            --root \
            --no-commit-id \
            --name-only \
            -r \
            "$commit"
    )

    count="${#changed_files[@]}"

    if [ "$count" -gt 1 ]; then

        MULTI=$((MULTI + 1))

        echo
        echo "Multi-file commit:"
        echo "  $commit"
        echo "  Files: $count"

        printf '    %s\n' "${changed_files[@]}"

    fi

done < <(
    git --git-dir="$REPO" rev-list "$BRANCH"
)

echo
echo "============================================================"
echo " Summary"
echo "============================================================"
echo
echo "Repository files           : ${#FILES[@]}"
echo "Total device revisions     : $TOTAL_REVISIONS"
echo "Target retained revisions  : $TOTAL_RETAINED"
echo "Multi-file commits found   : $MULTI"
echo

if [ "$MULTI" -eq 0 ]; then
    echo "Repository structure is compatible with the standard"
    echo "Oxidized history rebuild process."
else
    echo "WARNING:"
    echo "Multi-file commits were found."
    echo "Do NOT run the standard rebuild until these are reviewed."
fi
