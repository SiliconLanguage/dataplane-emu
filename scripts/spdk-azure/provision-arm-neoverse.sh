#!/bin/bash
source "$(dirname "$0")/.env"

echo "Provisioning $AZ_VM_NAME in $AZ_LOCATION..."
az vm create \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --name "$AZ_VM_NAME" \
  --location "$AZ_LOCATION" \
  --image Canonical:ubuntu-24_04-lts:server-arm64:latest \
  --size Standard_D4pds_v6 \
  --admin-username "$AZ_USER" \
  --generate-ssh-keys \
  --public-ip-sku Standard
