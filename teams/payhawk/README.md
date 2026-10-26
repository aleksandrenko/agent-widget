# Payhawk team settings

`config.json` (Jira site and projects, the e2e gate workflow, portal prod releases) and `brand.svg` (the
header mark) for Payhawk. No tokens here: the Jira token lives in the macOS keychain, entered in the setup window.

Install them by hand, then open the app (or its menu → Setup… for the Jira token):

    mkdir -p ~/.agent-widget && cp teams/payhawk/config.json teams/payhawk/brand.svg ~/.agent-widget/
