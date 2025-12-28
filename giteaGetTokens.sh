#!/bin/bash

set -e

GITEA_USERNAME="__GITEA_USERNAME__"
GITEA_URL="__GITEA_URL__"
CONFIG_DIR="__CONFIG_DIR__"

if [ -z "$GITEA_USERNAME" ] || [ "$GITEA_USERNAME" = "__GITEA_USERNAME__" ]; then
  echo "Error: GITEA_USERNAME not configured. Please edit this script or re-run installation."
  exit 1
fi

if [ -z "$GITEA_URL" ] || [ "$GITEA_URL" = "__GITEA_URL__" ]; then
  echo "Error: GITEA_URL not configured. Please edit this script or re-run installation."
  exit 1
fi

# Step 1: Generate PAT using podmgr exec from the compose directory
echo "Generating Personal Access Token for user: $GITEA_USERNAME"
cd /opt/compose/gitea

PAT=$(podmgr exec gitea gitea admin user generate-access-token \
  --username "$GITEA_USERNAME" \
  --token-name "automation-token" \
  --scopes all \
  --raw 2>/dev/null || true)

if [ -z "$PAT" ]; then
  echo "Error: Failed to generate PAT. Make sure Gitea is running and the user exists."
  exit 1
fi

# Save PAT securely
echo "$PAT" > "$CONFIG_DIR/.pat"
chmod 600 "$CONFIG_DIR/.pat"
echo "PAT saved to $CONFIG_DIR/.pat"

# Step 2: Get runner registration token using the PAT
echo "Fetching runner registration token..."
RUNNER_TOKEN_RESPONSE=$(curl -s -X GET "https://$GITEA_URL/api/v1/admin/runners/registration-token" \
     -H "Authorization: token $PAT" \
     -H "accept: application/json")

if [ -z "$RUNNER_TOKEN_RESPONSE" ]; then
  echo "Error: Failed to fetch runner registration token."
  exit 1
fi

# Save runner token response
echo "$RUNNER_TOKEN_RESPONSE" > "$CONFIG_DIR/.runner_token"
chmod 600 "$CONFIG_DIR/.runner_token"
echo "Runner token saved to $CONFIG_DIR/.runner_token"

echo "Done! Tokens have been saved to $CONFIG_DIR/"
