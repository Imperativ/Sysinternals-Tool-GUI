[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [ValidateRange(1024, 65535)][int]$Port = 18765,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Slg.Core.ps1')

function Get-SlgStaticContentType {
    param([Parameter(Mandatory)][string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.js' { return 'text/javascript; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg' { return 'image/svg+xml' }
        default { return 'application/octet-stream' }
    }
}

function Write-SlgStaticFile {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory)][string]$WebRoot,
        [Parameter(Mandatory)][string]$RequestPath,
        [Parameter(Mandatory)][hashtable]$State
    )
    $relativePath = if ($RequestPath -eq '/') { 'index.html' } else { $RequestPath.TrimStart('/') }
    if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath -match '(^|[\\/])\.\.([\\/]|$)' -or $relativePath -match '[\x00-\x1F]') {
        Write-SlgJson -Response $Response -StatusCode 400 -Value (New-SlgError -Code 'invalid_path' -Message 'Ungültiger statischer Pfad.')
        return
    }
    $filePath = Join-Path $WebRoot $relativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-SlgJson -Response $Response -StatusCode 404 -Value (New-SlgError -Code 'not_found' -Message 'Datei nicht gefunden.')
        return
    }
    $content = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
    if ($relativePath -eq 'index.html') { $content = $content.Replace('__SLG_CSRF_TOKEN__', $State.CsrfToken) }
    Write-SlgResponse -Response $Response -StatusCode 200 -Content $content -ContentType (Get-SlgStaticContentType -Path $filePath)
}

function Get-SlgQueryValue {
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request, [Parameter(Mandatory)][string]$Name)
    return [string]$Request.QueryString[$Name]
}

function Handle-SlgApiRequest {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][hashtable]$State
    )
    $request = $Context.Request
    $response = $Context.Response
    $path = $request.Url.AbsolutePath.TrimEnd('/')
    if ([string]::IsNullOrEmpty($path)) { $path = '/' }
    $requiresCsrf = $request.HttpMethod -in @('POST', 'PUT', 'PATCH', 'DELETE')
    Test-SlgApiRequest -Request $request -State $State -RequiresCsrf:$requiresCsrf

    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/v1/health') {
        Write-SlgJson -Response $response -StatusCode 200 -Value ([ordered]@{
            product = 'Sysinternals Live GUI'; agent = 'powershell-bootstrap'; listener = "http://127.0.0.1:$($State.Port)"; catalogRevision = $State.Catalog.catalogRevision;
            manifestRevision = $State.Manifest.revision; architecture = Get-SlgArchitecture; startedAt = $State.StartedAt
        })
        return
    }

    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/v1/tools') {
        $query = (Get-SlgQueryValue -Request $request -Name 'q').Trim()
        $category = (Get-SlgQueryValue -Request $request -Name 'category').Trim()
        $items = @($State.Catalog.tools)
        if (-not [string]::IsNullOrWhiteSpace($query)) {
            $needle = $query.ToLowerInvariant()
            $items = @($items | Where-Object {
                ([string]$_.name).ToLowerInvariant().Contains($needle) -or
                ([string]$_.id).ToLowerInvariant().Contains($needle) -or
                ([string]$_.description).ToLowerInvariant().Contains($needle) -or
                ((@($_.categories) -join ' ').ToLowerInvariant().Contains($needle))
            })
        }
        if (-not [string]::IsNullOrWhiteSpace($category)) { $items = @($items | Where-Object { @($_.categories) -contains $category }) }
        $views = @($items | Sort-Object name | ForEach-Object { Get-SlgToolView -State $State -Tool $_ })
        Write-SlgJson -Response $response -StatusCode 200 -Value ([ordered]@{ catalogRevision = $State.Catalog.catalogRevision; categories = @($State.Catalog.categories); total = $views.Count; tools = $views })
        return
    }

    if ($request.HttpMethod -eq 'GET' -and $path -match '^/api/v1/tools/([a-z0-9-]+)$') {
        $tool = Get-SlgTool -State $State -ToolId $Matches[1]
        if ($null -eq $tool) { Write-SlgJson -Response $response -StatusCode 404 -Value (New-SlgError -Code 'tool_not_found' -Message 'Tool nicht im Katalog gefunden.'); return }
        Write-SlgJson -Response $response -StatusCode 200 -Value (Get-SlgToolView -State $State -Tool $tool -IncludeAvailability)
        return
    }

    if ($request.HttpMethod -eq 'POST' -and $path -match '^/api/v1/tools/([a-z0-9-]+)/availability:refresh$') {
        Write-SlgJson -Response $response -StatusCode 200 -Value (Get-SlgAvailability -State $State -ToolId $Matches[1])
        return
    }

    if ($request.HttpMethod -eq 'POST' -and $path -match '^/api/v1/tools/([a-z0-9-]+)/download:open$') {
        $toolId = $Matches[1]
        $entry = Get-SlgManifestEntry -State $State -ToolId $toolId
        if ($null -eq $entry -or -not (Test-SlgOfficialUrl -Url ([string]$entry.downloadUrl))) { throw [System.InvalidOperationException]::new('Für dieses Tool existiert kein freigegebener offizieller Download-Link.') }
        Start-Process -FilePath ([string]$entry.downloadUrl) | Out-Null
        Write-SlgJson -Response $response -StatusCode 202 -Value ([ordered]@{ accepted = $true; action = 'official-download-opened'; url = [string]$entry.downloadUrl })
        return
    }

    if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/v1/invocations:preview') {
        $body = Get-SlgJsonBody -Request $request
        Write-SlgJson -Response $response -StatusCode 200 -Value (New-SlgPreview -State $State -Body $body)
        return
    }

    if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/v1/invocations:start') {
        $body = Get-SlgJsonBody -Request $request
        Write-SlgJson -Response $response -StatusCode 202 -Value (Start-SlgRun -State $State -Body $body)
        return
    }

    if ($request.HttpMethod -eq 'GET' -and $path -match '^/api/v1/runs/([a-f0-9]+)$') {
        $runId = $Matches[1]
        if (-not $State.Runs.ContainsKey($runId)) { Write-SlgJson -Response $response -StatusCode 404 -Value (New-SlgError -Code 'run_not_found' -Message 'Run nicht gefunden.'); return }
        Write-SlgJson -Response $response -StatusCode 200 -Value (Get-SlgRunView -Run $State.Runs[$runId])
        return
    }

    if ($request.HttpMethod -eq 'POST' -and $path -match '^/api/v1/runs/([a-f0-9]+):cancel$') {
        Write-SlgJson -Response $response -StatusCode 200 -Value (Stop-SlgRun -State $State -RunId $Matches[1])
        return
    }

    Write-SlgJson -Response $response -StatusCode 404 -Value (New-SlgError -Code 'api_not_found' -Message 'API-Route nicht gefunden.')
}

$webRoot = Join-Path $ProjectRoot 'web'
$configPath = Join-Path $ProjectRoot 'assets\agent-config.json'
$catalogPath = Join-Path $ProjectRoot 'assets\catalog.json'
$manifestPath = Join-Path $ProjectRoot 'assets\execution-manifest.json'
foreach ($requiredPath in @($webRoot, $configPath, $catalogPath, $manifestPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Erforderlicher Projektbestandteil fehlt: $requiredPath" }
}

$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$stateRoot = Join-Path $ProjectRoot 'state'
$cacheRoot = Join-Path $stateRoot 'cache'
New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null

$state = @{
    ProjectRoot = $ProjectRoot
    Port = $Port
    CsrfToken = Get-SlgRandomToken
    StartedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Catalog = $catalog
    Manifest = $manifest
    CacheRoot = $cacheRoot
    Previews = @{}
    Runs = @{}
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
}
catch {
    throw "Der Loopback-Port $Port kann nicht gebunden werden. Prüfe, ob bereits ein Prozess auf diesem Port läuft. Details: $($_.Exception.Message)"
}

$origin = "http://127.0.0.1:$Port/"
Write-Host "Sysinternals Live GUI läuft unter $origin" -ForegroundColor Cyan
Write-Host 'Mit Ctrl+C wird der lokale Agent beendet.' -ForegroundColor DarkGray
if (-not $NoBrowser) { Start-Process -FilePath $origin | Out-Null }
$contextTask = $null
try {
    while ($listener.IsListening) {
        Receive-SlgProcessEvents -State $state
        Clear-SlgExpiredPreviews -State $state
        if ($null -eq $contextTask) {
            $contextTask = $listener.GetContextAsync()
        }
        if (-not $contextTask.IsCompleted) { Start-Sleep -Milliseconds 50; continue }
        $context = $contextTask.GetAwaiter().GetResult()
        $contextTask = $null
        try {
            $requestPath = $context.Request.Url.AbsolutePath
            if ($requestPath.StartsWith('/api/')) { Handle-SlgApiRequest -Context $context -State $state }
            elseif ($context.Request.HttpMethod -ne 'GET') { Write-SlgJson -Response $context.Response -StatusCode 405 -Value (New-SlgError -Code 'method_not_allowed' -Message 'Nur GET ist für statische Ressourcen erlaubt.') }
            else { Write-SlgStaticFile -Response $context.Response -WebRoot $webRoot -RequestPath $requestPath -State $state }
        }
        catch {
            $exception = $_.Exception
            if ($exception -is [System.UnauthorizedAccessException]) {
                Write-SlgJson -Response $context.Response -StatusCode 403 -Value (New-SlgError -Code 'forbidden' -Message $exception.Message)
            }
            elseif ($exception -is [System.ArgumentException]) {
                Write-SlgJson -Response $context.Response -StatusCode 400 -Value (New-SlgError -Code 'invalid_request' -Message $exception.Message)
            }
            elseif ($exception -is [System.TimeoutException]) {
                Write-SlgJson -Response $context.Response -StatusCode 410 -Value (New-SlgError -Code 'preview_expired' -Message $exception.Message)
            }
            elseif ($exception -is [System.InvalidOperationException]) {
                Write-SlgJson -Response $context.Response -StatusCode 409 -Value (New-SlgError -Code 'operation_not_available' -Message $exception.Message)
            }
            else {
                Write-SlgJson -Response $context.Response -StatusCode 500 -Value (New-SlgError -Code 'agent_error' -Message 'Unerwarteter Agentfehler.' -Details $exception.Message)
            }
        }
    }
}
finally {
    foreach ($run in @($state.Runs.Values)) {
        try { if (-not $run.process.HasExited) { $run.process.Kill() } } catch { }
    }
    $listener.Stop()
    $listener.Close()
}
