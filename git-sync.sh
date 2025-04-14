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
GITSYNC_ONE_TIME=${GITSYNC_ONE_TIME:-false}

GITSYNC_ROOT=${GITSYNC_ROOT:-repo} # Root directory for the repository
GITSYNC_LINK=${GITSYNC_LINK:-head} # Directory to clone the repository into
GITSYNC_GITDIR=${GITSYNC_GITDIR:-/tmp/git} # Directory to store the git repository
GITSYNC_STATEFILE=${GITSYNC_STATEFILE:-/tmp/state} # File to store the last known state of the repository

if [ -z "$GITSYNC_REPO" ]; then
    echo "Error: GITSYNC_REPO environment variable is required"
    exit 1
fi

if [[ "$GITSYNC_ONE_TIME" == "true" ]]; then
    echo "$(date_formated): One-time sync mode enabled, exiting after initial sync"
fi

REPO_DIR=/tmp/$GITSYNC_ROOT/$GITSYNC_LINK

if [ ! -d "$(dirname $REPO_DIR)" ]; then
    echo "$(date_formated): Creating directory $(dirname $REPO_DIR)"
    mkdir -p $(dirname $REPO_DIR)
fi

if [ ! -d "$(dirname $GITSYNC_GITDIR)" ]; then
    echo "$(date_formated): Creating directory $(dirname $GITSYNC_GITDIR)"
    mkdir -p $(dirname $GITSYNC_GITDIR)
fi

# Save original git command
GIT_BIN_PATH=$(which git)

if [[ "$DEBUG" == "true" ]]; then
    echo "$(date_formated): Debug mode enabled"
    echo "$(date_formated): GIT_BIN_PATH: $GIT_BIN_PATH"
    echo "$(date_formated): GITSYNC_REPO: $GITSYNC_REPO"
    echo "$(date_formated): GITSYNC_REF: $GITSYNC_REF"
    echo "$(date_formated): GITSYNC_PERIOD: $GITSYNC_PERIOD"
    echo "$(date_formated): GITSYNC_ONE_TIME: $GITSYNC_ONE_TIME"
    echo "$(date_formated): GITSYNC_ROOT: $GITSYNC_ROOT"
    echo "$(date_formated): GITSYNC_LINK: $GITSYNC_LINK"
    echo "$(date_formated): GITSYNC_GITDIR: $GITSYNC_GITDIR"
    echo "$(date_formated): GITSYNC_STATEFILE: $GITSYNC_STATEFILE"
    echo "$(date_formated): REPO_DIR: $REPO_DIR"
    echo "$(date_formated): GITSYNC_USERNAME: $GITSYNC_USERNAME"
    echo "$(date_formated): GITSYNC_PASSWORD: $GITSYNC_PASSWORD"
    echo "$(date_formated): GITSYNC_GIT_CONFIG: $GITSYNC_GIT_CONFIG"
    echo "$(date_formated): GITSYNC_MAX_FAILURES: $GITSYNC_MAX_FAILURES"
fi

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
if [ -d "$REPO_DIR" ]; then
    rm -rf "$REPO_DIR"
fi
# Check if the git directory exists
if [ -d "$GITSYNC_GITDIR" ]; then
    rm -rf "$GITSYNC_GITDIR"
fi

# Initialize the git directory
echo "$(date_formated): Clone git repository"
if git clone --jobs 4 --separate-git-dir $GITSYNC_GITDIR --recurse-submodules --shallow-submodules --remote-submodules --branch $GITSYNC_REF $GITSYNC_REPO $REPO_DIR ; then
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

if [[ "$GITSYNC_ONE_TIME" == "true" ]] ; then
    echo "$(date_formated): Sync completed, exiting"
    exit 0
fi

while true ; do
    # Get remote HEAD for the specific branch
    REMOTE_HASH=$(git -C $REPO_DIR ls-remote origin $GITSYNC_REF | awk '{print $1}')
    
    # Get last known state
    if [ -f "$GITSYNC_STATEFILE" ]; then
        LAST_HASH=$(cat "$GITSYNC_STATEFILE")
    else
        LAST_HASH=""
    fi
    
    # Check for changes
    if [ "$REMOTE_HASH" != "$LAST_HASH" ]; then
        echo "$(date_formated): Changes detected in ref $GITSYNC_REF, syncing repository"
        git -C $REPO_DIR fetch origin $GITSYNC_REF
        git -C $REPO_DIR reset --hard origin/$GITSYNC_REF
        echo "$REMOTE_HASH" > "$GITSYNC_STATEFILE"
    elif $DEBUG ; then
        echo "$(date_formated): No changes detected in ref $GITSYNC_REF"
    fi
    # Check for changes in submodules
    if $DEBUG ; then echo "$(date_formated): Checking submodules"; fi
    git -C $REPO_DIR submodule update --init --recursive --remote
    if $DEBUG ; then echo "$(date_formated): Submodules updated successfully"; fi
    # Sleep for the specified period
    sleep $GITSYNC_PERIOD
done