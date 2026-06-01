#!/bin/bash
set -e -x

# Ensure svix database exists (idempotent).
# BREAKTAPES PATCH: svix (outgoing webhooks) is not used — we poll providers.
# On managed Postgres (Supabase) the app role can't CREATE DATABASE, so this
# step is gated behind ENABLE_SVIX and made non-fatal. Default: skip.
if [ "${ENABLE_SVIX:-false}" = "true" ]; then
    echo 'Ensuring svix database...'
    uv run python scripts/init/create_svix_db.py \
        || echo "Warning: svix DB creation failed — continuing without svix."
else
    echo 'Skipping svix database (ENABLE_SVIX != true).'
fi

# Init database
echo 'Applying migrations...'
uv run alembic upgrade head

# Initialize provider settings
echo 'Initializing provider settings...'
uv run python scripts/init_provider_settings.py

# Initialize device priority table
echo 'Initializing priorities...'
uv run python scripts/init_device_priorities.py

# Seed admin account (uses ADMIN_EMAIL/ADMIN_PASSWORD env vars, or defaults)
echo 'Seeding admin account...'
uv run python scripts/init/seed_admin.py

# Initialize series type definitions
echo 'Initializing series type definitions...'
uv run python scripts/init/seed_series_types.py

# TODO: Remove this after ~2026-06-01 once all deployments have migrated.
# Drops legacy recovery_score timeseries data; no-op if already cleaned up.
echo 'Running recovery_score series type cleanup...'
uv run python scripts/data_migrations/drop_recovery_score_series_type.py \
    || echo "Warning: recovery_score cleanup failed — will retry on next startup."

# TODO: Remove this after ~2026-06-01 once all deployments have migrated.
# Divides body_fat_percentage values stored 100x too large (Samsung/Google bug, PR #917); no-op if already corrected.
echo 'Running body_fat_percentage normalization...'
uv run python scripts/data_migrations/normalize_body_fat_percentage.py \
    || echo "Warning: body_fat_percentage normalization failed — will retry on next startup."

# Initialize archival settings
echo 'Initializing archival settings...'
uv run python scripts/init/seed_archival_settings.py

# Register webhook event types with Svix (with retry, non-fatal).
# BREAKTAPES PATCH: only attempt when svix is enabled.
if [ "${ENABLE_SVIX:-false}" = "true" ]; then
    echo 'Registering webhook event types...'
    for i in 1 2 3; do
        uv run python scripts/init/seed_webhook_event_types.py && break
        echo "Svix not ready yet, retrying in 5s... (attempt ${i}/3)"
        sleep 5
    done || echo "Warning: Could not register webhook event types with Svix. Will retry on next startup."
else
    echo 'Skipping svix webhook registration (ENABLE_SVIX != true).'
fi

# Init app
echo "Starting the FastAPI application..."
if [ "$ENVIRONMENT" = "local" ]; then
    uv run fastapi dev app/main.py --host 0.0.0.0 --port "${API_PORT:-8000}"
else
    uv run fastapi run app/main.py --host 0.0.0.0 --port "${API_PORT:-8000}"
fi
