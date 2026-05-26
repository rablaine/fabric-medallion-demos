#!/usr/bin/env bash
# Deploys the Contoso Retail data estate to Azure.
#
# Prerequisites:
#   - Azure CLI installed and authenticated (`az login`)
#   - bash 4+
#   - Python 3.10+
#   - Contributor role on target subscription

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CONFIG_FILE="$SCRIPT_DIR/deployment.config"

echo "Contoso Retail - Deployment"
echo "============================"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: deployment.config not found. Package may be corrupt." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

echo ""
echo "Configuration:"
echo "  VERTICAL=$VERTICAL"
echo "  RESOURCE_GROUP=$RESOURCE_GROUP"
echo "  LOCATION=$LOCATION"
echo "  SCALE=$SCALE"
echo "  RESOURCE_PREFIX=$RESOURCE_PREFIX"
echo ""

echo "Verifying Azure CLI authentication..."
if ! az account show >/dev/null 2>&1; then
    echo "ERROR: Not logged into Azure CLI. Run 'az login' first." >&2
    exit 1
fi

ACCOUNT_NAME=$(az account show --query user.name -o tsv)
SUBSCRIPTION=$(az account show --query name -o tsv)
echo "  Signed in as: $ACCOUNT_NAME"
echo "  Subscription: $SUBSCRIPTION"
echo ""

# TODO: Create resource group
echo "[TODO] Create resource group $RESOURCE_GROUP in $LOCATION"

# TODO: Deploy Bicep
echo "[TODO] Deploy infra/main.bicep"

# TODO: Run data generation
echo "[TODO] Generate and load synthetic data (scale: $SCALE)"

# TODO: Configure Fabric / Purview
echo "[TODO] Configure Fabric workspace and Purview catalog"

echo ""
echo "Deployment scaffold complete. Real deployment logic coming soon."
