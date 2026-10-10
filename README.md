# Supabase Self-Hosted with Docker + Cloudflare Tunnel

A small deployment-only repository for running a self-hosted Supabase stack with persistent local data and an optional Cloudflare Tunnel. It contains no application/frontend code and no credentials. The official Supabase Docker configuration and runtime files (pinned to `self-hosted/v0.8.2`) are included in `supabase/docker/` in this repo; the launchers copy them locally into the ignored `stack/` directory.

The official Supabase bundle includes Postgres, Storage, Realtime, Auth, REST/API gateway, Studio, and supporting services. Auth, REST, and the gateway are dependencies of the standard self-hosted stack; this repo does not include a separate app.

## Requirements

- Docker Desktop (Windows/macOS) or Docker Engine and Compose v2 (Linux).
- Internet access on first start so Docker can pull the Supabase service images. The Compose files themselves are included here; the launcher no longer downloads the Supabase source archive.
- Linux/macOS: Bash and OpenSSL. Windows: PowerShell 5.1+ and Docker Desktop; WSL is not required.

## Windows: PowerShell setup

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\start-windows.ps1
```

The first run copies the bundled Supabase configuration, generates unique credentials inside a temporary Docker container, and starts the stack. Docker downloads the required service images on first launch. The launcher prompts whether to enable Cloudflare Tunnel. If yes, it securely prompts for your existing Cloudflare tunnel token and public hostname, then writes the local environment file automatically. You do not need to edit `.env` manually.

To clone this public repo first:

```powershell
git clone https://github.com/satviksingh0828-wq/supabase-cloudflare-selfhost.git
cd supabase-cloudflare-selfhost
```

## Linux/macOS: one command

```bash
bash start.sh
```

The gateway/API and Postgres ports bind to localhost on the host. Supabase data persists under `stack/volumes/` and is preserved by normal restarts and `docker compose down`.

## Cloudflare Tunnel

Create a remotely managed Tunnel in the Cloudflare dashboard first. The launcher accepts its tunnel token locally; it does not ask you to paste secrets into chat or commit them. Create a **Published application** route for your chosen hostname and set its **Service URL** to:

```text
http://api-gw:8000
```

That service name is reachable by the cloudflared container over Compose's private network. The launchers print this origin address. The tunnel token is a bearer secret: anyone possessing it can run the tunnel, so protect the local `stack/.env` file and rotate the token if exposed. The token alone cannot create the tunnel or hostname route; those are configured in the Cloudflare dashboard.

For correct Auth callbacks and generated links, use the Windows launcher's hostname prompt or set these values in `stack/.env` on Linux/macOS:

```dotenv
SUPABASE_PUBLIC_URL=https://your-hostname.example.com
API_EXTERNAL_URL=https://your-hostname.example.com/auth/v1
```

Then restart the stack. Do not publish Postgres, Docker control access, or unprotected Studio administration through a public route. Apply appropriate Cloudflare Access policies and keep Supabase RLS enabled.

## Operations and data safety

Run from `stack/`:

```bash
docker compose ps
docker compose logs -f
docker compose down          # stop; retains data
docker compose up -d --wait  # restart
```

Never use `docker compose down -v` or delete `stack/volumes/` unless you intend to destroy the stored data. Local persistence is not a backup. Back up Postgres and Storage objects together to encrypted off-host storage and periodically test restoration. Restrict host/Docker access, protect generated database/JWT/API keys, and do not put secret/service-role keys in client-side code.

## References

- [Supabase self-hosting with Docker](https://supabase.com/docs/guides/self-hosting/docker)
- [Cloudflare Tunnel quickstart](https://developers.cloudflare.com/tunnel/get-started/)
