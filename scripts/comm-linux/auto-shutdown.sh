#!/bin/bash

# Exit on error, treat unset variables as an error.
set -euo pipefail

IDLE_FILE="/tmp/idle_count"
MAX_IDLE=4 # 4 checks x 15 mins = 60 minutes of idle time

# Reset idle counter whenever an interactive session exists.
if [ "$(who | wc -l)" -gt 0 ]; then
    echo 0 > "$IDLE_FILE"
    exit 0
fi

# Increment the idle counter.
IDLE_COUNT=$(cat "$IDLE_FILE" 2>/dev/null || echo 0)
IDLE_COUNT=$((IDLE_COUNT + 1))
echo "$IDLE_COUNT" > "$IDLE_FILE"

# If idle for 60 minutes, ask Azure to deallocate this VM.
if [ "$IDLE_COUNT" -ge "$MAX_IDLE" ]; then
    TOKEN=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F" | jq -r '.access_token')
    SUB=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | jq -r '.compute.subscriptionId')
    RG=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | jq -r '.compute.resourceGroupName')
    VM=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | jq -r '.compute.name')

    curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Length: 0" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Compute/virtualMachines/$VM/deallocate?api-version=2021-03-01" > /dev/null
    unset TOKEN
fi
