$ErrorActionPreference = 'Stop'
$Ref = 'self-hosted/v0.8.2'
$Root = $PSScriptRoot
$Stack = Join-Path $Root 'stack'
$EnvFile = Join-Path $Stack '.env'

function Set-EnvValue([string]$Name, [string]$Value) {
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $EnvFile) {
        foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) { $lines.Add($line) }
    }
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith("$Name=")) { $lines[$i] = "$Name=$Value"; $found = $true }
    }
    if (-not $found) { $lines.Add("$Name=$Value") }
    [System.IO.File]::WriteAllLines($EnvFile, $lines, [System.Text.UTF8Encoding]::new($false))
}

function Get-EnvValue([string]$Name) {
    if (-not (Test-Path -LiteralPath $EnvFile)) { return '' }
    $line = [System.IO.File]::ReadAllLines($EnvFile) | Where-Object { $_.StartsWith("$Name=") } | Select-Object -Last 1
    if ($null -eq $line) { return '' }
    return $line.Substring($Name.Length + 1)
}

function Invoke-Docker([string[]]$Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker command failed (exit $LASTEXITCODE): docker $($Arguments -join ' ')" }
}

try {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Install and start Docker Desktop, then rerun this script.' }
    Invoke-Docker @('compose', 'version') | Out-Null
    Invoke-Docker @('info') | Out-Null

    if (-not (Test-Path (Join-Path $Stack 'docker-compose.yml'))) {
        $upstream = Join-Path $Root 'supabase\docker'
        if (-not (Test-Path (Join-Path $upstream 'docker-compose.yml'))) { throw "Bundled Supabase configuration is missing from $upstream" }
        New-Item -ItemType Directory -Force -Path $Stack | Out-Null
        Write-Host "Copying bundled Supabase Docker configuration ($Ref)..."
        Copy-Item -Path (Join-Path $upstream '*') -Destination $Stack -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $upstream '.env.example') -Destination $Stack -Force
        Copy-Item (Join-Path $Stack '.env.example') $EnvFile -Force
        Write-Host 'Generating unique Supabase credentials inside a temporary Docker container...'
        $mount = "type=bind,source=$Stack,target=/work"
        Invoke-Docker @('run', '--rm', '--mount', $mount, '-w', '/work', 'node:22-alpine', 'sh', '-c', 'apk add --no-cache openssl >/dev/null && sh utils/generate-keys.sh --update-env >/dev/null && sh utils/add-new-auth-keys.sh --update-env >/dev/null')
        Set-EnvValue 'API_GW_HTTP_PORT' '127.0.0.1:8000'
        Set-EnvValue 'POSTGRES_PORT' '5432'
        Set-Content -LiteralPath (Join-Path $Stack '.supabase-version') -Value "ref=$Ref" -Encoding ascii
        @('.env', '.env.*', '!.env.example', 'volumes/db/data/', 'volumes/storage/', 'volumes/functions/') | Set-Content -LiteralPath (Join-Path $Stack '.gitignore') -Encoding ascii
    }

    # Optional public hostname is for printed SDK URL/storage links; Cloudflare routes are configured separately.
    $currentUrl = Get-EnvValue 'SUPABASE_PUBLIC_URL'
    if (-not $currentUrl) { $currentUrl = 'http://localhost:8000' }
    $publicHost = Read-Host "Cloudflare public hostname (for example supabase.example.com); Enter keeps $currentUrl"
    if ($publicHost) {
        if ($publicHost -notmatch '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') { throw 'Enter a hostname such as supabase.example.com, without https:// or a path.' }
        Set-EnvValue 'SUPABASE_PUBLIC_URL' "https://$publicHost"
        Set-EnvValue 'API_EXTERNAL_URL' "https://$publicHost/auth/v1"
    }
    Set-EnvValue 'API_GW_HTTP_PORT' '127.0.0.1:8000'
    Set-EnvValue 'POSTGRES_PORT' '5432'

    # Retire any old full-stack containers for this project; volumes/data are retained.
    Push-Location $Stack
    try {
        Invoke-Docker @('compose', '--env-file', '.env', 'down', '--remove-orphans')
        # Start only Postgres, PostgREST, Realtime, Storage and imgproxy.
        Invoke-Docker @('compose', '--env-file', '.env', 'up', '-d', '--wait', 'db', 'rest', 'realtime', 'storage', 'imgproxy')
        # Start the API gateway without its upstream Studio dependency; no admin UI or Auth service is launched.
        Invoke-Docker @('compose', '--env-file', '.env', 'up', '-d', '--no-deps', '--wait', 'api-gw')
    } finally { Pop-Location }

    $localUrl = 'http://localhost:8000'
    $publicUrl = Get-EnvValue 'SUPABASE_PUBLIC_URL'
    if (-not $publicUrl) { $publicUrl = $localUrl }
    Write-Host ''
    Write-Host "SUPABASE_URL=$publicUrl" -ForegroundColor Green
    Write-Host "Cloudflare Tunnel Service URL (Windows cloudflared service origin): $localUrl"
    Write-Host "REST:      $publicUrl/rest/v1"
    Write-Host "Storage:   $publicUrl/storage/v1"
    Write-Host "Realtime:  $publicUrl/realtime/v1"
    Write-Host ''
    Write-Host "SUPABASE_ANON_KEY=$(Get-EnvValue 'ANON_KEY')"
    Write-Host "SUPABASE_SERVICE_ROLE_KEY=$(Get-EnvValue 'SERVICE_ROLE_KEY')  [SECRET: server-side only]" -ForegroundColor Yellow
    Write-Host "SUPABASE_PUBLISHABLE_KEY=$(Get-EnvValue 'SUPABASE_PUBLISHABLE_KEY')"
    Write-Host "SUPABASE_SECRET_KEY=$(Get-EnvValue 'SUPABASE_SECRET_KEY')  [SECRET: server-side only]" -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Use the Service URL http://localhost:8000 in your Cloudflare Tunnel Published application route.'
    Write-Host 'Studio and Supabase Auth sign-up/login are intentionally not running. The service-role/secret keys bypass RLS.'
    Write-Host 'Status: docker compose ps    Stop without deleting data: docker compose down'
} catch {
    Write-Error $_
    exit 1
}
