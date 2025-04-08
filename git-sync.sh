#!/bin/sh

set -e

date_formated() {
    # Use the date command to format the date
    date -Iseconds
}

trap cleanup EXIT
trap 'echo "Received interrupt signal, exiting..."; exit 0' SIGINT SIGTERM

cleanup() {
    echo "$(date_formated): Exiting"
}

. .env

REPO_DIR=${REPO_DIR:-/repo} # Directory to clone the repository into
GIT_REF=${GIT_REF:-main}  # Default branch, can be overridden
SYNC_INTERVAL=${SYNC_INTERVAL:-60} # Sync interval in seconds

GIT_DIR=/tmp/git
STATE_FILE=/tmp/state

if [ -z "$GIT_REPO" ]; then
    echo "Error: GIT_REPO environment variable is required"
    exit 1
fi

# Save original git command
GIT_BIN_PATH=$(which git)

git() {
    local retries=3
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

git config --global http.sslVerify "false"

# Configure Git to use credentials for this session only
if [ -n "$GIT_USERNAME" ] && [ -n "$GIT_PASSWORD" ]; then
    echo "$(date_formated): HTTPS repository detected, configuring credentials"
    
    # Set up credential helper
    $GIT_BIN_PATH config --global credential.helper 'cache --timeout=3600'
    
    # Provide credentials to Git
    echo "url=$GIT_REPO
username=$GIT_USERNAME
password=$GIT_PASSWORD
" | $GIT_BIN_PATH credential approve
    
    USING_CREDENTIALS="true"
fi

# Check if the repository directory exists
if [ -d "$REPO_DIR" ]; then
    rm -rf "$REPO_DIR"
fi
# Check if the git directory exists
if [ -d "$GIT_DIR" ]; then
    rm -rf "$GIT_DIR"
fi

git clone --separate-git-dir $GIT_DIR --branch $GIT_REF $GIT_REPO $REPO_DIR

while true; do
    # Get remote HEAD for the specific branch
    REMOTE_HASH=$(git -C $REPO_DIR ls-remote origin $GIT_REF | awk '{print $1}')
    
    # Get last known state
    if [ -f "$STATE_FILE" ]; then
        LAST_HASH=$(cat "$STATE_FILE")
    else
        LAST_HASH=""
    fi
    
    # Check for changes
    if [ "$REMOTE_HASH" != "$LAST_HASH" ]; then
        echo "$(date_formated): Changes detected in ref $GIT_REF, syncing repository"
        git -C $REPO_DIR fetch origin $GIT_REF
        git -C $REPO_DIR reset --hard origin/$GIT_REF
        git -C $REPO_DIR submodule update --init --recursive --remote
        echo "$REMOTE_HASH" > "$STATE_FILE"
    fi
    
    sleep $SYNC_INTERVAL
done