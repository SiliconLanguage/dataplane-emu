#!/bin/bash
set -euo pipefail

# Match existing Azure scripts that source scripts/spdk-azure/.env.
source "$(dirname "$0")/.env"

if [ -z "${AZ_RESOURCE_GROUP:-}" ] || [ -z "${AZ_VM_NAME:-}" ]; then
    echo "AZ_RESOURCE_GROUP and AZ_VM_NAME must be set in scripts/spdk-azure/.env"
    exit 1
fi

echo "Deallocating Azure VM $AZ_VM_NAME in resource group $AZ_RESOURCE_GROUP..."
az vm deallocate --resource-group "$AZ_RESOURCE_GROUP" --name "$AZ_VM_NAME"

echo "VM deallocated: $AZ_VM_NAME"
