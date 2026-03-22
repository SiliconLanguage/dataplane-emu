#!/bin/bash
# Load environment variables
source "$(dirname "$0")/.env"

echo "Enabling Managed Identity for $AZ_VM_NAME..."
az vm identity assign -g "$AZ_RESOURCE_GROUP" -n "$AZ_VM_NAME"

SP_ID=$(az vm show -g "$AZ_RESOURCE_GROUP" -n "$AZ_VM_NAME" --query identity.principalId -o tsv)
VM_ID=$(az vm show -g "$AZ_RESOURCE_GROUP" -n "$AZ_VM_NAME" --query id -o tsv)

echo "Assigning Contributor Role to Principal: $SP_ID"
az role assignment create --assignee "$SP_ID" --role "Virtual Machine Contributor" --scope "$VM_ID"
