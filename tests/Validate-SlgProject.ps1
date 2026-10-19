[CmdletBinding()]
param(
    [string]$ProjectRoot
)

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Condition {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

$requiredFiles = @(
    'Start-SysinternalsLiveGui.ps1',
    'src\Slg.Core.ps1',
    'src\Start-SlgServer.ps1',
    'assets\agent-config.json',
    'assets\catalog.json',
    'assets\execution-manifest.json',
    'web\index.html',
    'web\app.js',
    'web\styles.css',
    'web\manus-routes.json'
)
foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $ProjectRoot $relativePath
    Assert-Condition -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "Fehlende Projektdatei: $relativePath"
}

foreach ($relativePath in @('Start-SysinternalsLiveGui.ps1', 'src\Slg.Core.ps1', 'src\Start-SlgServer.ps1')) {
    $path = Join-Path $ProjectRoot $relativePath
    $null = [scriptblock]::Create([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
    Write-Host "PowerShell-Syntax OK: $relativePath"
}

$config = Get-Content -LiteralPath (Join-Path $ProjectRoot 'assets\agent-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$catalog = Get-Content -LiteralPath (Join-Path $ProjectRoot 'assets\catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$manifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'assets\execution-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$routes = Get-Content -LiteralPath (Join-Path $ProjectRoot 'web\manus-routes.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop

Assert-Condition -Condition ($config.listenHost -eq '127.0.0.1') -Message 'Der Agent darf ausschließlich auf 127.0.0.1 binden.'
Assert-Condition -Condition (@($catalog.tools).Count -ge 70) -Message 'Der Katalog ist unerwartet unvollständig.'
Assert-Condition -Condition (@($routes.routes | Where-Object path -eq '/').Count -eq 1) -Message 'Das Routenmanifest muss die Root-Route enthalten.'
$duplicateIds = @($catalog.tools.id | Group-Object | Where-Object Count -gt 1)
if ($duplicateIds.Count -gt 0) {
    throw "Doppelte Katalog-IDs: $($duplicateIds | ForEach-Object Name -join ', ')"
}
$missingCatalogReferences = @($manifest.tools | Where-Object { $catalog.tools.id -notcontains $_.toolId })
if ($missingCatalogReferences.Count -gt 0) {
    throw "Manifest verweist auf unbekannte Tools: $($missingCatalogReferences | ForEach-Object toolId -join ', ')"
}
$core = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\Slg.Core.ps1') -Raw -Encoding UTF8
$server = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\Start-SlgServer.ps1') -Raw -Encoding UTF8
$combined = $core + "`n" + $server
foreach ($forbidden in @('Invoke-Expression', 'cmd.exe', 'powershell.exe')) {
    Assert-Condition -Condition ($combined -notmatch [regex]::Escape($forbidden)) -Message "Unsicheres Launch-Primitiv gefunden: $forbidden"
}
Assert-Condition -Condition ($combined -match 'UseShellExecute\s*=\s*\$false') -Message 'ProcessStartInfo muss ShellExecute deaktivieren.'
foreach ($required in @('ProcessStartInfo', 'ConvertTo-SlgWindowsArgument', 'Get-AuthenticodeSignature', 'Test-SlgOfficialUrl', 'X-SLG-CSRF', '127.0.0.1')) {
    Assert-Condition -Condition ($combined -match [regex]::Escape($required)) -Message "Sicherheitsinvariante fehlt: $required"
}
$binaryExtensions = @('.exe', '.dll', '.zip', '.msi')
$binaryFiles = Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File | Where-Object { $binaryExtensions -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch '\\.work\\tools\\' }
if (@($binaryFiles).Count -gt 0) {
    throw "Das Projekt darf keine Sysinternals- oder Paketbinaries enthalten: $($binaryFiles | ForEach-Object FullName -join ', ')"
}
Write-Host "VALIDATION PASSED: $(@($catalog.tools).Count) Katalogtools, $(@($manifest.tools).Count) freigegebene Execution-Manifest-Einträge." -ForegroundColor Green
