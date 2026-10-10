#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$ROOT/stack"
REF="self-hosted/v0.8.2"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || fail 'Docker is required.'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 is required.'
docker info >/dev/null 2>&1 || fail 'Docker daemon is not running or accessible.'

if [[ ! -f "$STACK/docker-compose.yml" ]]; then
  [[ -f "$ROOT/supabase/docker/docker-compose.yml" ]] || fail 'Bundled Supabase files are missing from supabase/docker/.'
  command -v openssl >/dev/null 2>&1 || fail 'OpenSSL is required for first-time key generation.'
  mkdir -p "$STACK"
  echo "Copying the bundled Supabase Docker configuration ($REF)..."
  cp -R "$ROOT/supabase/docker/." "$STACK/"
  cp "$STACK/.env.example" "$STACK/.env"
  chmod 600 "$STACK/.env" 2>/dev/null || true
  (cd "$STACK" && sh utils/generate-keys.sh --update-env >/dev/null && sh utils/add-new-auth-keys.sh --update-env >/dev/null)
  # Keep the API gateway reachable only from this computer; tunnel access is configured on the host.
  sed -i.bak -e 's/^API_GW_HTTP_PORT=.*/API_GW_HTTP_PORT=127.0.0.1:8000/' -e 's/^POSTGRES_PORT=.*/POSTGRES_PORT=5432/' "$STACK/.env"
  rm -f "$STACK/.env.bak"
  printf 'ref=%s\n' "$REF" > "$STACK/.supabase-version"
  cat > "$STACK/.gitignore" <<'IGNORE'
.env
.env.*
!.env.example
volumes/db/data/
volumes/storage/
volumes/functions/
*.bak
IGNORE
  echo 'Generated unique database password, JWT secret, and API keys.'
fi

cd "$STACK"
# Only these Supabase components are started. Studio, Auth, Functions, Logs, and pooler are not run.
docker compose --env-file .env up -d --wait db rest realtime storage imgproxy
# Skip api-gw's upstream dependency on Studio; this starts only the gateway, not the admin panel.
docker compose --env-file .env up -d --no-deps --wait api-gw

read_env() { sed -n "s/^$1=//p" .env | tr -d '\r' | tail -n1; }
local_url='http://localhost:8000'
printf '\nSupabase local URL: %s\n' "$local_url"
printf 'Cloudflare Tunnel route origin (Windows host service): %s\n' "$local_url"
printf 'PostgREST: %s/rest/v1\nStorage:   %s/storage/v1\nRealtime:  %s/realtime/v1\n\n' "$local_url" "$local_url" "$local_url"
printf 'SUPABASE_ANON_KEY=%s\n' "$(read_env ANON_KEY)"
printf 'SUPABASE_SERVICE_ROLE_KEY=%s  [SECRET: server-side only]\n' "$(read_env SERVICE_ROLE_KEY)"
printf 'SUPABASE_PUBLISHABLE_KEY=%s\n' "$(read_env SUPABASE_PUBLISHABLE_KEY)"
printf 'SUPABASE_SECRET_KEY=%s  [SECRET: server-side only]\n' "$(read_env SUPABASE_SECRET_KEY)"
printf '\nThe Service Role/Secret keys bypass Row Level Security. Never put them in browser code.\n'
echo 'Cloudflare route: set the tunnel Service URL to http://localhost:8000 on the same host.'
echo 'Auth sign-up/login and Supabase Studio are not included in this minimal setup.'
echo 'Status: docker compose ps    Stop without deleting data: docker compose down'
