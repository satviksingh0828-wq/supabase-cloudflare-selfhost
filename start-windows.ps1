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
        if ($lines[$i].StartsWith("$Name=")) {
            $lines[$i] = "$Name=$Value"
            $found = $true
        }
    }
    if (-not $found) { $lines.Add("$Name=$Value") }
    [System.IO.File]::WriteAllLines($EnvFile, $lines, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Docker([string[]]$Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker command failed (exit $LASTEXITCODE): docker $($Arguments -join ' ')" }
}

try {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker is not installed. Install and start Docker Desktop, then run this script again.'
    }
    Invoke-Docker @('compose', 'version') | Out-Null
    Invoke-Docker @('info') | Out-Null

    if (-not (Test-Path (Join-Path $Stack 'docker-compose.yml'))) {
        $upstream = Join-Path $Root 'supabase\docker'
        if (-not (Test-Path (Join-Path $upstream 'docker-compose.yml'))) {
            throw "Bundled Supabase Docker files are missing from $upstream"
        }
        Write-Host "Copying the Supabase Docker bundle included in this repository ($Ref)..."
        New-Item -ItemType Directory -Force -Path $Stack | Out-Null
        Copy-Item -Path (Join-Path $upstream '*') -Destination $Stack -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $upstream '.env.example') -Destination $Stack -Force
        Copy-Item (Join-Path $Stack '.env.example') $EnvFile -Force
        Write-Host 'Generating unique Supabase keys and passwords inside a temporary Docker container...'
        $mount = "type=bind,source=$Stack,target=/work"
        Invoke-Docker @('run', '--rm', '--mount', $mount, '-w', '/work', 'node:22-alpine', 'sh', '-c', 'apk add --no-cache openssl >/dev/null && sh utils/generate-keys.sh --update-env >/dev/null && sh utils/add-new-auth-keys.sh --update-env >/dev/null')
        Set-EnvValue 'API_GW_HTTP_PORT' '127.0.0.1:8000'
        Set-EnvValue 'POSTGRES_PORT' '127.0.0.1:5432'
        Set-Content -LiteralPath (Join-Path $Stack '.supabase-version') -Value "ref=$Ref" -Encoding ascii
        @('.env', '.env.*', '!.env.example', 'volumes/db/data/', 'volumes/storage/', 'volumes/functions/') | Set-Content -LiteralPath (Join-Path $Stack '.gitignore') -Encoding ascii
        Write-Host 'Supabase environment initialized with generated secrets.'
    }

    if (-not (Test-Path $EnvFile)) { throw "Missing environment file: $EnvFile" }
    $token = ''
    $hostName = ''
    if (-not (Select-String -LiteralPath $EnvFile -Pattern '^CLOUDFLARE_TUNNEL_TOKEN=' -Quiet)) {
        Set-EnvValue 'CLOUDFLARE_TUNNEL_TOKEN' ''
    }
    $existing = (Select-String -LiteralPath $EnvFile -Pattern '^CLOUDFLARE_TUNNEL_TOKEN=' | Select-Object -Last 1).Line -replace '^CLOUDFLARE_TUNNEL_TOKEN=', ''
    if ($existing) {
        $enableTunnel = Read-Host 'A tunnel token is already saved. Use it? [Y/n]'
        if ($enableTunnel -notmatch '^(n|no)$') { $token = $existing }
    }
    if (-not $token) {
        $enableTunnel = Read-Host 'Enable Cloudflare Tunnel now? You will need to have created a tunnel in Cloudflare [y/N]'
        if ($enableTunnel -match '^(y|yes)$') {
            $secureToken = Read-Host 'Paste the Cloudflare Tunnel token (input is hidden)' -AsSecureString
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
            try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
            if (-not $token) { throw 'No tunnel token was entered.' }
            $hostName = Read-Host 'Public hostname you configured in Cloudflare (example: supabase.example.com)'
            if ($hostName -notmatch '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') { throw 'Enter a valid public hostname.' }
            Set-EnvValue 'CLOUDFLARE_TUNNEL_TOKEN' $token
            Set-EnvValue 'SUPABASE_PUBLIC_URL' "https://$hostName"
            Set-EnvValue 'API_EXTERNAL_URL' "https://$hostName/auth/v1"
        }
    }
    if ($token -and -not $hostName) {
        $hostName = Read-Host 'Public hostname already configured in Cloudflare (press Enter to keep current URLs)'
        if ($hostName) {
            if ($hostName -notmatch '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') { throw 'Enter a valid public hostname.' }
            Set-EnvValue 'SUPABASE_PUBLIC_URL' "https://$hostName"
            Set-EnvValue 'API_EXTERNAL_URL' "https://$hostName/auth/v1"
        }
    }

    # Limit the generated credential file to the current Windows account.
    & icacls $EnvFile /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not tighten .env file permissions; protect this file manually.' }

    Push-Location $Stack
    try {
        if ($token) {
            Invoke-Docker @('compose', '--env-file', '.env', '-f', 'docker-compose.yml', '-f', (Join-Path $Root 'docker-compose.tunnel.yml'), 'up', '-d', '--wait')
            Write-Host 'Supabase and Cloudflare Tunnel are running.' -ForegroundColor Green
        } else {
            Invoke-Docker @('compose', '--env-file', '.env', 'up', '-d', '--wait')
            Write-Host 'Supabase is running locally. Rerun this script to enable a tunnel.' -ForegroundColor Green
        }
        $publicUrl = (Select-String -LiteralPath $EnvFile -Pattern '^SUPABASE_PUBLIC_URL=' | Select-Object -Last 1).Line -replace '^SUPABASE_PUBLIC_URL=', ''
        Write-Host "Studio/API: $publicUrl"
        Write-Host 'Cloudflare Tunnel Service URL: http://api-gw:8000'
        Write-Host 'In Cloudflare, add a Published application route for your hostname using that Service URL.'
        Write-Host 'Status: docker compose ps    Stop without deleting data: docker compose down'
    } finally { Pop-Location }
} catch {
    Write-Error $_
    exit 1
}
