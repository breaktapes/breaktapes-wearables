#!/usr/bin/env bash
# Deploy Open Wearables (breaktapes) to Fly.io.
#
# Prereqs:
#   1. flyctl installed + `fly auth login` done
#   2. open_wearables schema + ow_app role exist on Supabase (already created)
#
# Run from the repo root:  bash deploy/fly-deploy.sh
#
# Secrets are generated once and saved to ~/breaktapes-ow-secrets.env (gitignored,
# outside the repo). Re-running reuses them so SECRET_KEY / MASTER_KEY stay stable
# (changing MASTER_KEY would make already-stored OAuth tokens undecryptable).

set -euo pipefail

REDIS_APP="breaktapes-wearables-redis"
OW_APP="breaktapes-wearables"
SECRETS_FILE="$HOME/breaktapes-ow-secrets.env"
REGION="fra"

# ── Known values (non-generated) ──────────────────────────────────────────────
# DB_PASSWORD (ow_app role) — never hardcoded. Provide via env or prompt:
#   export DB_PASSWORD="..."   before running.
WHOOP_CLIENT_ID="a36f712e-3cb4-4d73-95e9-a1c594feb923"   # public client id, not secret
# WHOOP_CLIENT_SECRET must be provided via env (rotate the exposed one first):
#   export WHOOP_CLIENT_SECRET="..."   before running, OR paste when prompted.
WHOOP_REDIRECT_URI="https://${OW_APP}.fly.dev/api/v1/oauth/whoop/callback"
WHOOP_DEFAULT_SCOPE="offline read:cycles read:sleep read:recovery read:workout"
ADMIN_EMAIL="admin@breaktapes.com"

# ── Generate-once secrets ─────────────────────────────────────────────────────
if [ -f "$SECRETS_FILE" ]; then
  echo "Reusing secrets from $SECRETS_FILE"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
else
  echo "Generating new secrets → $SECRETS_FILE"
  SECRET_KEY="$(openssl rand -hex 32)"
  MASTER_KEY="$(python3 -c 'import base64,os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())')"
  OPEN_WEARABLES_API_KEY="bt_ow_$(openssl rand -hex 24)"
  ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' )Aa1!"
  umask 077
  cat > "$SECRETS_FILE" <<EOF
SECRET_KEY=$SECRET_KEY
MASTER_KEY=$MASTER_KEY
OPEN_WEARABLES_API_KEY=$OPEN_WEARABLES_API_KEY
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF
  echo "Saved. health-proxy OW_API_KEY = $OPEN_WEARABLES_API_KEY"
fi

# DB password + WHOOP secret from env or prompt (never committed)
if [ -z "${DB_PASSWORD:-}" ]; then
  read -rsp "Paste DB_PASSWORD (ow_app Supabase role): " DB_PASSWORD
  echo
fi
if [ -z "${WHOOP_CLIENT_SECRET:-}" ]; then
  read -rsp "Paste WHOOP_CLIENT_SECRET (rotate the exposed one first): " WHOOP_CLIENT_SECRET
  echo
fi

# ── 1. Redis app (private network) ────────────────────────────────────────────
if ! fly apps list 2>/dev/null | grep -q "$REDIS_APP"; then
  fly apps create "$REDIS_APP" --org personal
fi
fly deploy -c deploy/redis/fly.toml --app "$REDIS_APP" --remote-only

# ── 2. OW app ─────────────────────────────────────────────────────────────────
if ! fly apps list 2>/dev/null | grep -q "^$OW_APP"; then
  fly apps create "$OW_APP" --org personal
fi

# Secrets (staged, applied on next deploy)
fly secrets set --app "$OW_APP" --stage \
  SECRET_KEY="$SECRET_KEY" \
  MASTER_KEY="$MASTER_KEY" \
  OPEN_WEARABLES_API_KEY="$OPEN_WEARABLES_API_KEY" \
  DB_PASSWORD="$DB_PASSWORD" \
  ADMIN_EMAIL="$ADMIN_EMAIL" \
  ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  WHOOP_CLIENT_ID="$WHOOP_CLIENT_ID" \
  WHOOP_CLIENT_SECRET="$WHOOP_CLIENT_SECRET" \
  WHOOP_REDIRECT_URI="$WHOOP_REDIRECT_URI" \
  WHOOP_DEFAULT_SCOPE="$WHOOP_DEFAULT_SCOPE"

# Deploy (builds backend/Dockerfile, runs migrations on app boot)
fly deploy -c backend/fly.toml --app "$OW_APP" --remote-only

echo ""
echo "=== DONE ==="
echo "OW URL:        https://${OW_APP}.fly.dev"
echo "Admin panel:   https://${OW_APP}.fly.dev/  (admin@breaktapes.com)"
echo "OW_BASE_URL:   https://${OW_APP}.fly.dev"
echo "OW_API_KEY:    (see $SECRETS_FILE → OPEN_WEARABLES_API_KEY)"
echo ""
echo "Next:"
echo "  1. Add WHOOP redirect URI in dashboard: $WHOOP_REDIRECT_URI"
echo "  2. Set health-proxy secrets:"
echo "       cd health-proxy"
echo "       echo 'https://${OW_APP}.fly.dev' | wrangler secret put OW_BASE_URL"
echo "       echo '<OPEN_WEARABLES_API_KEY>'  | wrangler secret put OW_API_KEY"
