# Minimal Supabase on Docker + Cloudflare Tunnel

This repository runs a **minimal Supabase API stack** on your own Windows or Linux device. It starts only:

- Postgres database
- PostgREST (database REST API)
- Realtime (WebSocket/database changes)
- Storage API and its image proxy
- The API gateway needed to expose those APIs through one URL

It does **not** start Supabase Studio (admin panel), Supabase Auth sign-up/login, Edge Functions, analytics/logging, or the connection pooler. The official Supabase Docker bundle and key-generation utilities are included in `supabase/docker/`. The launchers select only the services listed above. First run still pulls their Docker images.

## Windows: run the stack

Install and start Docker Desktop. From PowerShell in the cloned repository run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\start-windows.ps1
```

The launcher generates unique database/API credentials, asks for your Cloudflare public hostname (optional; press Enter if the route is not configured yet), starts the minimal services, and prints the Supabase URL and keys in the PowerShell window. It does not ask for or store your Cloudflare tunnel token.

## Cloudflare Tunnel running as a Windows service

If `cloudflared.exe service install <TUNNEL_TOKEN>` is already installed on this same Windows machine, keep using that host service. In the Cloudflare Tunnel dashboard, add a Published application route for your hostname and set **Service URL** to:

```text
http://localhost:8000
```

Because `cloudflared.exe` is running on the Windows host—not in Docker—it connects to the API gateway through this localhost port. The launcher binds the gateway to localhost only. Do not use `http://api-gw:8000` for the host-installed Windows tunnel service.

Once the route exists, rerun the launcher and enter its public hostname when prompted. The console then prints the public Supabase URL and generated keys. Keep the service-role/secret keys private; they bypass Row Level Security and must never go in browser code. If a tunnel token has been pasted into chat or otherwise exposed, rotate it in Cloudflare before relying on it.

## Linux/macOS

```bash
bash start.sh
```

The API gateway binds to `127.0.0.1:8000`. A host-installed `cloudflared` connector should use `http://localhost:8000` as its origin as well.

## Connection endpoints and keys

The launchers print:

- `SUPABASE_URL` — local `http://localhost:8000` or the public HTTPS hostname you enter.
- REST API — `/rest/v1`
- Storage — `/storage/v1`
- Realtime — `/realtime/v1`
- Anonymous and service-role keys, plus current publishable/secret key values.

This reduced setup has no Supabase Auth service, so Auth sign-up, login, and `/auth/v1` are not available. Realtime/Storage/REST use the generated JWT/API keys; configure Postgres grants and Row Level Security policies deliberately before exposing application data. The service-role/secret key is privileged and server-only.

Postgres itself is not published on a host port or through the HTTP tunnel. To access it locally, run from `stack/`:

```powershell
docker compose exec db psql -U postgres
```

## Persistence and operations

Database data is stored in `stack/volumes/db/data/`; uploaded files are stored in `stack/volumes/storage/`. Normal restarts and `docker compose down` keep these folders. Never use `docker compose down -v` or delete `stack/volumes/` unless you intend to erase the data. Local persistence is not a backup: make encrypted, off-device database and Storage backups and test restores.

From `stack/`:

```text
docker compose ps
docker compose logs -f
docker compose down       # stop; retain data
```

## Official documentation

- [Supabase Docker self-hosting](https://supabase.com/docs/guides/self-hosting/docker)
- [Cloudflare Tunnel quickstart](https://developers.cloudflare.com/tunnel/get-started/)
