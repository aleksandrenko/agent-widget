#!/bin/bash
# Saves a Slack user token in the keychain (entry: slack_user_token), so the panel can show who wrote
# to you and open that exact conversation. Without it the panel shows only the unread count.
#
# 1. This opens Slack's "create app" page with the app's settings filled in: pick your workspace, Create.
# 2. Install to Workspace (your admin may need to approve it), then copy the "User OAuth Token" (xoxp-…).
# 3. Paste it here.
set -euo pipefail
MANIFEST='{"display_information":{"name":"Agent Widget","description":"Shows your unread DMs and mentions on your Mac desktop."},"oauth_config":{"scopes":{"user":["im:read","im:history","mpim:read","mpim:history","users:read","search:read"]}},"settings":{"org_deploy_enabled":false,"socket_mode_enabled":false,"token_rotation_enabled":false}}'
open "https://api.slack.com/apps?new_app=1&manifest_json=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$MANIFEST")"
read -rsp "Slack User OAuth Token (xoxp-…): " token; echo
security add-generic-password -U -a "$USER" -s slack_user_token -w "$token"
answer=$(curl -s -H "Authorization: Bearer $token" https://slack.com/api/auth.test)
python3 -c 'import json, sys; a = json.loads(sys.argv[1]); print("Slack OK: " + a["user"] + " @ " + a["team"] if a.get("ok") else "Slack said: " + a.get("error", "?"))' "$answer"
open -g "agentwidget://refresh" 2>/dev/null || true
