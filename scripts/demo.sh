#!/usr/bin/env bash
# Runs AWSContext with made-up profiles for screenshots. Your real ~/.aws is never read or written.
#   ./scripts/demo.sh        start the demo (replaces the running AWSContext)
#   ./scripts/demo.sh stop   quit the demo and relaunch your installed AWSContext
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="io.github.awscontext.AWSContext"
DEMO="${TMPDIR:-/tmp}/awscontext-demo"
SAVED_PREVIOUS="$DEMO.previous-profile"

if [[ "${1:-}" == "stop" ]]; then
  pkill -x AWSContext || true
  if [[ -f "$SAVED_PREVIOUS" ]]; then
    value="$(cat "$SAVED_PREVIOUS")"
    if [[ -n "$value" ]]; then defaults write "$BUNDLE_ID" previousProfile "$value"; else defaults delete "$BUNDLE_ID" previousProfile 2>/dev/null || true; fi
    rm -f "$SAVED_PREVIOUS"
  fi
  rm -rf "$DEMO"
  sleep 1
  [[ -d /Applications/AWSContext.app ]] && open /Applications/AWSContext.app
  echo "Demo stopped."
  exit 0
fi

[[ -x build/AWSContext.app/Contents/MacOS/AWSContext ]] || UNIVERSAL=0 ./scripts/build-app.sh

rm -rf "$DEMO"
mkdir -p "$DEMO/sso/cache"

# Account IDs are the placeholder IDs used in AWS documentation.
cat > "$DEMO/config" <<'INI'
[default]
sso_session = acme
sso_account_id = 111122223333
sso_role_name = AdministratorAccess
region = eu-west-1

[profile acme-dev]
sso_session = acme
sso_account_id = 111122223333
sso_role_name = AdministratorAccess
region = eu-west-1

[profile acme-staging]
sso_session = acme
sso_account_id = 444455556666
sso_role_name = PowerUserAccess
region = eu-west-1

[profile acme-prod]
sso_session = acme
sso_account_id = 777788889999
sso_role_name = ReadOnlyAccess
region = us-east-1

[profile acme-prod-admin]
role_arn = arn:aws:iam::777788889999:role/BreakGlassAdmin
source_profile = acme-prod
region = us-east-1

[profile client-analytics]
sso_session = client
sso_account_id = 123456789012
sso_role_name = DataEngineer
region = eu-central-1

[profile personal]
region = us-west-2
output = json

[sso-session acme]
sso_start_url = https://acme.awsapps.com/start
sso_region = eu-west-1

[sso-session client]
sso_start_url = https://client-corp.awsapps.com/start
sso_region = eu-central-1
INI

cat > "$DEMO/credentials" <<'INI'
[personal]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
INI

echo "acme-dev" > "$DEMO/awscontext"

# Fake SSO tokens: "acme" is signed in for 7h 42m, "client" has expired (shows the ⚠️ state).
token() { # <session> <expiresAt>
  local file
  file="$(printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1).json"
  printf '{"startUrl": "demo", "region": "eu-west-1", "accessToken": "demo", "expiresAt": "%s"}\n' "$2" > "$DEMO/sso/cache/$file"
}
token acme "$(date -u -v+7H -v+42M -v+30S +%Y-%m-%dT%H:%M:%SZ)"
token client "$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)"

# Show "Switch Back to acme-staging"; your own value is restored on stop.
[[ -f "$SAVED_PREVIOUS" ]] || (defaults read "$BUNDLE_ID" previousProfile 2>/dev/null || true) > "$SAVED_PREVIOUS"
defaults write "$BUNDLE_ID" previousProfile acme-staging

pkill -x AWSContext || true
sleep 1
AWSCONTEXT_HOME="$DEMO" nohup build/AWSContext.app/Contents/MacOS/AWSContext >/dev/null 2>&1 &
echo "Demo running with fake profiles (data in $DEMO)."
echo "Stop it with: make demo-stop"
