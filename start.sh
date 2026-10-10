#!/usr/bin/env bash
set -Eeuo pipefail

# One-command bootstrap/run wrapper for the official Supabase self-hosted bundle.
# Run from anywhere: bash supabase/self-hosted/start.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$ROOT/stack"
REF="self-hosted/v0.8.2"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || fail 'Docker is required. Install Docker Desktop (Windows/macOS) or Docker Engine + Compose plugin (Linux).'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 is required (docker compose).'
docker info >/dev/null 2>&1 || fail 'Docker daemon is not running or is not accessible.'

if [[ ! -f "$STACK/docker-compose.yml" ]]; then
  [[ -f "$ROOT/supabase/docker/docker-compose.yml" ]] || fail 'Bundled Supabase files are missing from supabase/docker/.'
  command -v openssl >/dev/null 2>&1 || fail 'OpenSSL is required for first-time setup.'
  mkdir -p "$STACK"
  echo "Using the Supabase Docker bundle included in this repository ($REF)..."
  cp -R "$ROOT/supabase/docker/." "$STACK/" || fail 'Could not copy bundled Supabase Docker files.'
  [[ -f "$STACK/docker-compose.yml" ]] || fail 'Supabase bundle extraction did not produce docker-compose.yml.'
  cp "$STACK/.env.example" "$STACK/.env"
  chmod 600 "$STACK/.env" 2>/dev/null || true
  (cd "$STACK" && sh utils/generate-keys.sh --update-env >/dev/null && sh utils/add-new-auth-keys.sh --update-env >/dev/null)
  # Publish only on loopback; cloudflared reaches api-gw over the private Compose network.
  sed -i.bak -e 's/^API_GW_HTTP_PORT=.*/API_GW_HTTP_PORT=127.0.0.1:8000/' -e 's/^POSTGRES_PORT=.*/POSTGRES_PORT=127.0.0.1:5432/' "$STACK/.env"
  rm -f "$STACK/.env.bak"
  printf '\n# Cloudflare Tunnel token (optional; set to enable external access)\nCLOUDFLARE_TUNNEL_TOKEN=\n' >> "$STACK/.env"
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
  echo 'Initialized with unique credentials. Edit stack/.env before publishing, especially the public URLs and dashboard password.'
fi

# Local-only binds prevent direct public exposure; Cloudflare reaches the API over Compose's private network.
cd "$STACK"

# Keep the standard upstream stack unchanged; use the tunnel overlay only when a token is configured.
token="$(sed -n 's/^CLOUDFLARE_TUNNEL_TOKEN=//p' .env | tr -d '\r' | tail -n1)"
if [[ -n "$token" ]]; then
  docker compose --env-file .env -f docker-compose.yml -f "$ROOT/docker-compose.tunnel.yml" up -d --wait
  echo 'Supabase and Cloudflare Tunnel are running.'
else
  docker compose --env-file .env up -d --wait
  echo 'Supabase is running locally. Add a Cloudflare Tunnel token to stack/.env and rerun to enable the tunnel.'
fi
printf 'Studio/API: %s\n' "$(sed -n 's/^SUPABASE_PUBLIC_URL=//p' .env | tail -n1)"
echo 'Cloudflare Tunnel route origin (enter this as the Service URL): http://api-gw:8000'
echo 'Set the public hostname in Cloudflare Dashboard > Networking > Tunnels > your tunnel > Routes.'
echo 'Status: docker compose ps'
echo 'Stop (data retained): docker compose down'
