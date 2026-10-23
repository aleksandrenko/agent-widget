#!/bin/bash
# Saves a Jira API token in the keychain for the widget (entries: jira_email, jira_api_token).
# Create the token at https://id.atlassian.com/manage-profile/security/api-tokens
set -euo pipefail
SITE=$(python3 -c 'import json, os; print(json.load(open(os.path.expanduser("~/.agent-widget/config.json")))["jira"]["site"].rstrip("/"))' 2>/dev/null || true)
[ -n "$SITE" ] || { echo "Set jira.site in ~/.agent-widget/config.json first (see config.example.json)."; exit 1; }
saved=$(security find-generic-password -a "$USER" -s jira_email -w 2>/dev/null || true)
read -rp "Jira email [$saved]: " email
email="${email:-$saved}"
read -rsp "Jira API token: " token; echo
security add-generic-password -U -a "$USER" -s jira_email -w "$email"
security add-generic-password -U -a "$USER" -s jira_api_token -w "$token"
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$email:$token" "$SITE/rest/api/3/myself")
[ "$code" = 200 ] && echo "Jira OK." || echo "Jira answered $code — check the token."
open -g "agentwidget://refresh" 2>/dev/null || true
