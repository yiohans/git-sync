#!/bin/sh

set -e

date_formated() {
    # Use the date command to format the date
    date -Iseconds
}

trap cleanup EXIT
trap 'echo "Received interrupt signal, exiting..."; exit 0' 2 15

cleanup() {
    echo "$(date_formated): Exiting"
}

GITSYNC_REF=${GITSYNC_REF:-main}  # Default branch, can be overridden
GITSYNC_PERIOD=${GITSYNC_PERIOD:-60} # Sync interval in seconds
GITSYNC_ONETIME=${GITSYNC_ONETIME:-false}

GITSYNC_LINK=${GITSYNC_LINK:-/repo} # Directory to clone the repository into
GITSYNC_GITDIR=${GITSYNC_GITDIR:-/tmp/git} # Directory to store the git repository
GITSYNC_STATEFILE=${GITSYNC_STATEFILE:-/tmp/state} # File to store the last known state of the repository

if [ -z "$GITSYNC_REPO" ]; then
    echo "Error: GITSYNC_REPO environment variable is required"
    exit 1
fi

# Save original git command
GIT_BIN_PATH=$(which git)

git() {
    local retries=${GITSYNC_MAX_FAILURES:-3}
    local count=0
    
    while [ $count -lt $retries ]; do
        if $GIT_BIN_PATH "$@"; then
            return 0
        fi
        count=$((count + 1))
        # echo "$(date_formated): Git command failed, retry $count/$retries in 5 seconds"
        sleep 5
    done
    echo "$(date_formated): Git command failed after $retries attempts"
    return 1
}

if [ ! -z "$GITSYNC_GIT_CONFIG" ]; then
    echo "$(date_formated): Configuring git with GITSYNC_GIT_CONFIG"
    # Configure git with the provided config in format key:value,key:value
    
    # Use echo and pipe instead of here-string (<<<)
    old_IFS=$IFS
    IFS=','
    echo "$GITSYNC_GIT_CONFIG" | while read -r pair; do
        # Use case statement instead of [[ ... ]] pattern matching
        case "$pair" in
            *:*)
                # Extract key/value using POSIX compatible parameter substitution
                key="${pair%%:*}"
                value="${pair#*:}"
                if [ ! -z "$key" ] && [ ! -z "$value" ]; then
                    echo "$(date_formated): Setting git config $key=$value"
                    git config --global "$key" "$value"
                else
                    echo "$(date_formated): Warning: Invalid git config pair: $pair"
                fi
                ;;
            *)
                echo "$(date_formated): Warning: Invalid git config format: $pair"
                ;;
        esac
    done
    IFS=$old_IFS
fi

# Configure Git to use credentials for this session only
if [ -n "$GITSYNC_USERNAME" ] && [ -n "$GITSYNC_PASSWORD" ]; then
    echo "$(date_formated): HTTPS repository detected, configuring credentials"
    
    # Set up credential helper
    git config --global credential.helper 'cache --timeout=3600'
    
    # Provide credentials to Git
    echo "url=$GITSYNC_REPO
username=$GITSYNC_USERNAME
password=$GITSYNC_PASSWORD
" | git credential approve
fi

# Check if the repository directory exists
if [ -d "$GITSYNC_LINK" ]; then
    rm -rf "$GITSYNC_LINK"
fi
# Check if the git directory exists
if [ -d "$GITSYNC_GITDIR" ]; then
    rm -rf "$GITSYNC_GITDIR"
fi

# Initialize the git directory
echo "$(date_formated): Clone git repository"
if git clone --jobs 4 --separate-git-dir $GITSYNC_GITDIR --recurse-submodules --shallow-submodules --remote-submodules --branch $GITSYNC_REF $GITSYNC_REPO $GITSYNC_LINK ; then
    echo "$(date_formated): Repository cloned successfully"
else
    echo "$(date_formated): Failed to clone repository"
    exit 1
fi

# # Update submodules
# echo "$(date_formated): Updating submodules"
# if git -C $GITSYNC_LINK submodule update --init --recursive --remote ; then
#     echo "$(date_formated): Submodules updated successfully"
# else
#     echo "$(date_formated): Failed to update submodules"
#     exit 1
# fi

while [ "$GITSYNC_ONETIME" = "false" ] ; do
    # Get remote HEAD for the specific branch
    REMOTE_HASH=$(git -C $GITSYNC_LINK ls-remote origin $GITSYNC_REF | awk '{print $1}')
    
    # Get last known state
    if [ -f "$GITSYNC_STATEFILE" ]; then
        LAST_HASH=$(cat "$GITSYNC_STATEFILE")
    else
        LAST_HASH=""
    fi
    
    # Check for changes
    if [ "$REMOTE_HASH" != "$LAST_HASH" ]; then
        echo "$(date_formated): Changes detected in ref $GITSYNC_REF, syncing repository"
        git -C $GITSYNC_LINK fetch origin $GITSYNC_REF
        git -C $GITSYNC_LINK reset --hard origin/$GITSYNC_REF
        echo "$REMOTE_HASH" > "$GITSYNC_STATEFILE"
    elif $DEBUG ; then
        echo "$(date_formated): No changes detected in ref $GITSYNC_REF"
    fi
    # Update submodules
    echo "$(date_formated): Updating submodules"
    git -C $GITSYNC_LINK submodule update --init --recursive --remote
    sleep $GITSYNC_PERIOD
done