Set-StrictMode -Version Latest

function ConvertTo-SlgJson {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 12 -Compress)
}

function Write-SlgResponse {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$Content,
        [string]$ContentType = 'application/json; charset=utf-8',
        [hashtable]$Headers = @{}
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentEncoding = [System.Text.Encoding]::UTF8
    $Response.ContentLength64 = $bytes.Length
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.Headers['Referrer-Policy'] = 'no-referrer'
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['Content-Security-Policy'] = "default-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; object-src 'none'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'"
    foreach ($name in $Headers.Keys) {
        $Response.Headers[$name] = [string]$Headers[$name]
    }
    try {
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $Response.OutputStream.Close()
    }
}

function Write-SlgJson {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][object]$Value
    )
    Write-SlgResponse -Response $Response -StatusCode $StatusCode -Content (ConvertTo-SlgJson -Value $Value)
}

function New-SlgError {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        [object]$Details = $null
    )
    return [ordered]@{
        error = [ordered]@{
            code = $Code
            message = $Message
            details = $Details
        }
    }
}

function Get-SlgRandomToken {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ([Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_'))
}

function Get-SlgJsonBody {
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request)
    if ($Request.ContentLength64 -gt 1048576) {
        throw [System.ArgumentException]::new('Der Request-Body überschreitet das Limit von 1 MiB.')
    }
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        $text = $reader.ReadToEnd()
    }
    finally {
        $reader.Close()
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [pscustomobject]@{}
    }
    try {
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw [System.ArgumentException]::new('Ungültiger JSON-Request-Body.')
    }
}

function Test-SlgApiRequest {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request,
        [Parameter(Mandatory)][hashtable]$State,
        [switch]$RequiresCsrf
    )

    $hostHeader = [string]$Request.Headers['Host']
    if ($hostHeader -notmatch '^127\.0\.0\.1(?::\d+)?$') {
        throw [System.UnauthorizedAccessException]::new('Anfragen sind ausschließlich über 127.0.0.1 zulässig.')
    }

    if ($RequiresCsrf) {
        $origin = [string]$Request.Headers['Origin']
        $expectedOrigin = "http://127.0.0.1:$($State.Port)"
        if (-not [string]::IsNullOrWhiteSpace($origin) -and $origin -ne $expectedOrigin) {
            throw [System.UnauthorizedAccessException]::new('Origin-Prüfung fehlgeschlagen.')
        }
        $token = [string]$Request.Headers['X-SLG-CSRF']
        if ([string]::IsNullOrWhiteSpace($token) -or $token -cne $State.CsrfToken) {
            throw [System.UnauthorizedAccessException]::new('CSRF-Token fehlt oder ist ungültig.')
        }
    }
}

function Get-SlgArchitecture {
    $environmentArchitectures = @($env:PROCESSOR_ARCHITECTURE, $env:PROCESSOR_ARCHITEW6432) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.ToUpperInvariant() }
    if ($environmentArchitectures -contains 'ARM64') { return 'arm64' }
    if ($environmentArchitectures -contains 'AMD64') { return 'x64' }
    if ($environmentArchitectures -contains 'X86') { return 'x86' }

    # Der Agent kann über einen Host gestartet werden, der die PROCESSOR_*-
    # Variablen nicht weiterreicht. CIM liefert dann die Betriebssystemarchitektur.
    try {
        $processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($processor.Architecture -eq 12) { return 'arm64' }
        if ($processor.AddressWidth -eq 64) { return 'x64' }
        if ($processor.AddressWidth -eq 32) { return 'x86' }
    }
    catch { }
    return 'unknown'
}

function Get-SlgTool {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ToolId
    )
    $matches = @($State.Catalog.tools | Where-Object { $_.id -eq $ToolId } | Select-Object -First 1)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}
function Get-SlgManifestEntry {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ToolId
    )
    $matches = @($State.Manifest.tools | Where-Object { $_.toolId -eq $ToolId } | Select-Object -First 1)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-SlgExpectedSigner {
    param([Parameter(Mandatory)][hashtable]$State)
    return [string]$State.Manifest.policy.cacheSignerSubjectPattern
}

function Get-SlgSignatureInfo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$State
    )
    try {
        $signature = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
        $subject = if ($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
        $valid = $signature.Status -eq 'Valid' -and $subject -match [regex]::Escape((Get-SlgExpectedSigner -State $State))
        return [ordered]@{
            checked = $true
            valid = $valid
            status = [string]$signature.Status
            statusMessage = [string]$signature.StatusMessage
            subject = $subject
        }
    }
    catch {
        return [ordered]@{
            checked = $true
            valid = $false
            status = 'VerificationError'
            statusMessage = $_.Exception.Message
            subject = ''
        }
    }
}

function Get-SlgConfiguredRoots {
    param([Parameter(Mandatory)][hashtable]$State)
    $roots = New-Object System.Collections.Generic.List[string]
    $storeRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Microsoft.SysinternalsSuite_8wekyb3d8bbwe'
    if (Test-Path -LiteralPath $storeRoot -PathType Container) { $roots.Add($storeRoot) }
    if (Test-Path -LiteralPath $State.CacheRoot -PathType Container) { $roots.Add($State.CacheRoot) }
    if (-not [string]::IsNullOrWhiteSpace($env:SLG_PORTABLE_ROOTS)) {
        foreach ($root in $env:SLG_PORTABLE_ROOTS.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $candidate = $root.Trim()
            if (Test-Path -LiteralPath $candidate -PathType Container) { $roots.Add($candidate) }
        }
    }
    return @($roots | Select-Object -Unique)
}

function Get-SlgLocalArtifact {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][object]$ManifestEntry
    )

    foreach ($root in Get-SlgConfiguredRoots -State $State) {
        foreach ($alias in @($ManifestEntry.aliases)) {
            $candidate = Join-Path $root $alias
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $isMsixAlias = $root -like '*Microsoft.SysinternalsSuite_8wekyb3d8bbwe'
                $signature = if ($isMsixAlias) {
                    [ordered]@{ checked = $false; valid = $true; status = 'MSIXAlias'; statusMessage = 'Microsoft-Store-App-Execution-Alias'; subject = 'Microsoft Store package' }
                }
                else {
                    Get-SlgSignatureInfo -Path $candidate -State $State
                }
                return [ordered]@{
                    found = $true
                    source = if ($isMsixAlias) { 'msix-alias' } elseif ($root -eq $State.CacheRoot) { 'slg-cache' } else { 'portable-root' }
                    path = $candidate
                    signature = $signature
                }
            }
        }
    }
    return [ordered]@{ found = $false; source = $null; path = $null; signature = $null }
}

function Get-SlgLiveArtifact {
    param(
        [Parameter(Mandatory)][object]$ManifestEntry,
        [Parameter(Mandatory)][string]$Architecture
    )

    if ($null -eq $ManifestEntry.live -or $null -eq $ManifestEntry.live.$Architecture) {
        return [ordered]@{ checked = $true; available = $false; path = $null; reason = "Für die Architektur '$Architecture' ist kein geprüftes Live-Artefakt hinterlegt." }
    }

    $path = [string]$ManifestEntry.live.$Architecture
    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($null -ne $item) {
            return [ordered]@{ checked = $true; available = $true; path = $path; reason = 'Live-UNC-Artefakt ist erreichbar.' }
        }
    }
    catch {
        return [ordered]@{ checked = $true; available = $false; path = $path; reason = $_.Exception.Message }
    }
    return [ordered]@{ checked = $true; available = $false; path = $path; reason = 'Das Live-UNC-Artefakt wurde nicht gefunden.' }
}

function Test-SlgOfficialUrl {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $uri = [Uri]$Url
        return $uri.Scheme -eq 'https' -and $uri.Host -in @('download.sysinternals.com', 'learn.microsoft.com', 'www.microsoft.com')
    }
    catch { return $false }
}

function Get-SlgAvailability {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ToolId
    )

    $tool = Get-SlgTool -State $State -ToolId $ToolId
    if ($null -eq $tool) { throw [System.ArgumentException]::new("Unbekannte Tool-ID: $ToolId") }
    $manifest = Get-SlgManifestEntry -State $State -ToolId $ToolId
    $architecture = Get-SlgArchitecture
    $windowsSupported = @($tool.platforms) -contains 'Windows'
    if (-not $windowsSupported) {
        return [ordered]@{
            toolId = $ToolId; checkedAt = [DateTimeOffset]::UtcNow.ToString('o'); architecture = $architecture; overall = 'unsupported-platform';
            explanation = 'Dieses Tool ist im offiziellen Katalog vorhanden, besitzt aber keine Windows-Ausführung für diesen Agenten.';
            local = [ordered]@{ found = $false }; live = [ordered]@{ checked = $false; available = $false; reason = 'Nicht für Windows.' }; download = [ordered]@{ available = $false }
        }
    }
    if ($null -eq $manifest) {
        return [ordered]@{
            toolId = $ToolId; checkedAt = [DateTimeOffset]::UtcNow.ToString('o'); architecture = $architecture; overall = 'catalog-only-pending-review';
            explanation = 'Dieses Windows-Tool ist katalogisiert, aber noch nicht mit einem geprüften Artefakt- und Risikoeintrag für die Ausführung freigegeben.';
            local = [ordered]@{ found = $false }; live = [ordered]@{ checked = $false; available = $false; reason = 'Kein Ausführungsmanifest.' }; download = [ordered]@{ available = $false }
        }
    }

    $local = Get-SlgLocalArtifact -State $State -ManifestEntry $manifest
    $live = Get-SlgLiveArtifact -ManifestEntry $manifest -Architecture $architecture
    $downloadAvailable = -not [string]::IsNullOrWhiteSpace($manifest.downloadUrl) -and (Test-SlgOfficialUrl -Url ([string]$manifest.downloadUrl))
    $overall = if ($local.found -and $local.signature.valid) { 'ready-local' } elseif ($live.available) { 'ready-live' } elseif ($downloadAvailable) { 'download-available' } else { 'not-available' }
    $explanation = switch ($overall) {
        'ready-local' { 'Eine lokale, vertrauenswürdige Quelle wurde gefunden.' }
        'ready-live' { 'Keine lokale vertrauenswürdige Quelle, aber das überprüfte Sysinternals-Live-UNC-Artefakt ist erreichbar.' }
        'download-available' { 'Keine startfähige lokale oder Live-Quelle; ein offizieller Microsoft-Download ist verlinkt.' }
        default { 'Weder lokale noch geprüfte Live- oder Downloadquelle ist momentan startbereit.' }
    }
    return [ordered]@{
        toolId = $ToolId; checkedAt = [DateTimeOffset]::UtcNow.ToString('o'); architecture = $architecture; overall = $overall; explanation = $explanation;
        local = $local; live = $live; download = [ordered]@{ available = $downloadAvailable; url = $manifest.downloadUrl }
    }
}

function Get-SlgToolView {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][object]$Tool,
        [switch]$IncludeAvailability
    )
    $manifest = Get-SlgManifestEntry -State $State -ToolId $Tool.id
    $isLegacy = $Tool.PSObject.Properties.Name -contains 'legacy' -and [bool]$Tool.legacy
    $view = [ordered]@{
        id = $Tool.id
        name = $Tool.name
        version = $Tool.version
        description = $Tool.description
        categories = @($Tool.categories)
        platforms = @($Tool.platforms)
        docUrl = $Tool.docUrl
        legacy = $isLegacy
        execution = if ($null -eq $manifest) { [ordered]@{ enabled = $false; reason = 'Katalogisiert, aber noch nicht im Ausführungsmanifest überprüft.' } } else { [ordered]@{ enabled = $true; kind = $manifest.kind; risks = @($manifest.risk.classes); supportsAcceptEula = [bool]$manifest.supportsAcceptEula } }
    }
    if ($IncludeAvailability) { $view.availability = Get-SlgAvailability -State $State -ToolId $Tool.id }
    return $view
}

function Test-SlgArgumentArray {
    param(
        [object]$Arguments,
        [Parameter(Mandatory)][object]$Manifest
    )
    $tokens = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Arguments) { return @($tokens) }
    foreach ($argument in @($Arguments)) {
        if ($argument -isnot [string]) { throw [System.ArgumentException]::new('Jeder Parameter muss ein eigener String-Token sein.') }
        if ($argument.Length -gt [int]$Manifest.policy.maxArgumentLength) { throw [System.ArgumentException]::new('Ein Parameter überschreitet das Größenlimit.') }
        if ($argument -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { throw [System.ArgumentException]::new('Parameter dürfen keine Steuerzeichen enthalten.') }
        $tokens.Add($argument)
    }
    if ($tokens.Count -gt [int]$Manifest.policy.maxArgumentCount) { throw [System.ArgumentException]::new('Zu viele Parameter.') }
    if ((@($tokens) -join '').Length -gt [int]$Manifest.policy.maxTotalArgumentLength) { throw [System.ArgumentException]::new('Die gesamte Parameterlänge überschreitet das Limit.') }
    return @($tokens)
}

function ConvertTo-SlgWindowsArgument {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * ($backslashes * 2 + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$builder.Append(('\' * $backslashes)); $backslashes = 0 }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function New-SlgPreview {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][object]$Body
    )
    $toolId = [string]$Body.toolId
    if ([string]::IsNullOrWhiteSpace($toolId)) { throw [System.ArgumentException]::new('toolId fehlt.') }
    $sourceMode = [string]$Body.sourceMode
    if ($sourceMode -notin @('local', 'live')) { throw [System.ArgumentException]::new('sourceMode muss local oder live sein.') }
    $tool = Get-SlgTool -State $State -ToolId $toolId
    $manifestEntry = Get-SlgManifestEntry -State $State -ToolId $toolId
    if ($null -eq $tool -or $null -eq $manifestEntry) { throw [System.InvalidOperationException]::new('Dieses Tool besitzt keinen freigegebenen Ausführungseintrag.') }
    $availability = Get-SlgAvailability -State $State -ToolId $toolId
    $executablePath = if ($sourceMode -eq 'local') { [string]$availability.local.path } else { [string]$availability.live.path }
    $usable = if ($sourceMode -eq 'local') { [bool]$availability.local.found -and [bool]$availability.local.signature.valid } else { [bool]$availability.live.available }
    if (-not $usable -or [string]::IsNullOrWhiteSpace($executablePath)) { throw [System.InvalidOperationException]::new("Die Quelle '$sourceMode' ist für $($tool.name) nicht startbereit.") }
    $arguments = Test-SlgArgumentArray -Arguments $Body.args -Manifest $State.Manifest
    $containsAcceptEula = @($arguments | Where-Object { $_ -ieq '-accepteula' }).Count -gt 0
    $previewId = [guid]::NewGuid().ToString('N')
    $risk = $manifestEntry.risk
    $preview = [ordered]@{
        id = $previewId
        toolId = $toolId
        toolName = $tool.name
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        expiresAt = [DateTimeOffset]::UtcNow.AddSeconds([int]$State.Manifest.policy.previewLifetimeSeconds).ToString('o')
        sourceMode = $sourceMode
        executablePath = $executablePath
        kind = $manifestEntry.kind
        args = @($arguments)
        riskClasses = @($risk.classes)
        requiresConfirmation = [bool]$risk.requiresConfirmation
        confirmationPhrase = [string]$risk.confirmationPhrase
        eulaExplicitlyRequested = $containsAcceptEula
        sensitiveOutput = [bool]$risk.sensitiveOutput
    }
    $State.Previews[$previewId] = $preview
    return [ordered]@{
        previewId = $preview.id
        expiresAt = $preview.expiresAt
        tool = [ordered]@{ id = $preview.toolId; name = $preview.toolName; kind = $preview.kind }
        sourceMode = $preview.sourceMode
        executablePath = $preview.executablePath
        argv = @($preview.args)
        risk = [ordered]@{ classes = @($preview.riskClasses); sensitiveOutput = $preview.sensitiveOutput; requiresConfirmation = $preview.requiresConfirmation; confirmationPhrase = $preview.confirmationPhrase; eulaExplicitlyRequested = $preview.eulaExplicitlyRequested }
    }
}

function Register-SlgRunEvents {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Run,
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][bool]$RedirectOutput
    )
    $messageData = [pscustomobject]@{ RunId = $Run.id }
    if ($RedirectOutput) {
        Register-ObjectEvent -InputObject $Process -EventName OutputDataReceived -SourceIdentifier "slg-run-$($Run.id)-out" -MessageData $messageData | Out-Null
        Register-ObjectEvent -InputObject $Process -EventName ErrorDataReceived -SourceIdentifier "slg-run-$($Run.id)-err" -MessageData $messageData | Out-Null
        $Process.BeginOutputReadLine()
        $Process.BeginErrorReadLine()
    }
    Register-ObjectEvent -InputObject $Process -EventName Exited -SourceIdentifier "slg-run-$($Run.id)-exit" -MessageData $messageData | Out-Null
}

function Start-SlgRun {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][object]$Body
    )
    $previewId = [string]$Body.previewId
    if ([string]::IsNullOrWhiteSpace($previewId) -or -not $State.Previews.ContainsKey($previewId)) { throw [System.ArgumentException]::new('Preview nicht gefunden oder bereits abgelaufen.') }
    $preview = $State.Previews[$previewId]
    $expiresAt = [DateTimeOffset]::Parse([string]$preview.expiresAt)
    if ($expiresAt -lt [DateTimeOffset]::UtcNow) { $State.Previews.Remove($previewId); throw [System.TimeoutException]::new('Preview ist abgelaufen. Bitte neu prüfen.') }
    if ([bool]$preview.requiresConfirmation) {
        if ([string]$Body.confirmationPhrase -cne [string]$preview.confirmationPhrase) { throw [System.UnauthorizedAccessException]::new('Die erforderliche Risikobestätigung stimmt nicht überein.') }
    }
    if ([bool]$preview.eulaExplicitlyRequested -and $Body.acceptEula -ne $true) { throw [System.UnauthorizedAccessException]::new('Die explizit gewählte EULA-Annahme muss separat bestätigt werden.') }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [string]$preview.executablePath
    $psi.Arguments = ((@($preview.args) | ForEach-Object { ConvertTo-SlgWindowsArgument -Value $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $preview.kind -eq 'cli'
    $psi.WorkingDirectory = $State.ProjectRoot
    $redirect = $preview.kind -eq 'cli'
    $psi.RedirectStandardOutput = $redirect
    $psi.RedirectStandardError = $redirect
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.EnableRaisingEvents = $true
    if (-not $process.Start()) { throw [System.ComponentModel.Win32Exception]::new('Der Prozessstart wurde von Windows abgelehnt.') }

    $runId = [guid]::NewGuid().ToString('N')
    $run = [ordered]@{
        id = $runId; toolId = $preview.toolId; toolName = $preview.toolName; sourceMode = $preview.sourceMode; kind = $preview.kind; executablePath = $preview.executablePath;
        argv = @($preview.args); pid = $process.Id; status = if ($redirect) { 'running' } else { 'native-window-started' }; startedAt = [DateTimeOffset]::UtcNow.ToString('o'); endedAt = $null; exitCode = $null;
        sensitiveOutput = [bool]$preview.sensitiveOutput; events = New-Object System.Collections.Generic.List[object]; process = $process; eventSourceIds = @()
    }
    $State.Runs[$runId] = $run
    Register-SlgRunEvents -State $State -Run $run -Process $process -RedirectOutput $redirect
    $run.eventSourceIds = if ($redirect) { @("slg-run-$runId-out", "slg-run-$runId-err", "slg-run-$runId-exit") } else { @("slg-run-$runId-exit") }
    $State.Previews.Remove($previewId)
    return Get-SlgRunView -Run $run
}

function Receive-SlgProcessEvents {
    param([Parameter(Mandatory)][hashtable]$State)
    $events = @(Get-Event | Where-Object { $_.SourceIdentifier -like 'slg-run-*' })
    foreach ($event in $events) {
        $runId = [string]$event.MessageData.RunId
        if (-not $State.Runs.ContainsKey($runId)) { Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue; continue }
        $run = $State.Runs[$runId]
        if ($event.SourceIdentifier -like '*-out' -or $event.SourceIdentifier -like '*-err') {
            $data = [string]$event.SourceEventArgs.Data
            if (-not [string]::IsNullOrEmpty($data)) {
                $stream = if ($event.SourceIdentifier -like '*-err') { 'stderr' } else { 'stdout' }
                if ($run.events.Count -lt 2000) {
                    $run.events.Add([ordered]@{ at = [DateTimeOffset]::UtcNow.ToString('o'); stream = $stream; text = $data })
                }
            }
        }
        elseif ($event.SourceIdentifier -like '*-exit') {
            $process = $run.process
            try { $run.exitCode = $process.ExitCode } catch { $run.exitCode = $null }
            $run.status = if ($run.status -eq 'canceled') { 'canceled' } else { 'completed' }
            $run.endedAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
    }
}

function Get-SlgRunView {
    param([Parameter(Mandatory)][hashtable]$Run)
    return [ordered]@{
        id = $Run.id; toolId = $Run.toolId; toolName = $Run.toolName; sourceMode = $Run.sourceMode; kind = $Run.kind; executablePath = $Run.executablePath;
        argv = @($Run.argv); pid = $Run.pid; status = $Run.status; startedAt = $Run.startedAt; endedAt = $Run.endedAt; exitCode = $Run.exitCode;
        sensitiveOutput = $Run.sensitiveOutput; events = @($Run.events)
    }
}

function Stop-SlgRun {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$RunId
    )
    if (-not $State.Runs.ContainsKey($RunId)) { throw [System.ArgumentException]::new('Run nicht gefunden.') }
    $run = $State.Runs[$RunId]
    if ($run.status -notin @('running', 'native-window-started')) { return Get-SlgRunView -Run $run }
    try {
        if (-not $run.process.HasExited) { $run.process.Kill() }
        $run.status = 'canceled'
        $run.endedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    catch {
        throw [System.InvalidOperationException]::new("Abbruch fehlgeschlagen: $($_.Exception.Message)")
    }
    return Get-SlgRunView -Run $run
}

function Clear-SlgExpiredPreviews {
    param([Parameter(Mandatory)][hashtable]$State)
    $expired = @($State.Previews.Keys | Where-Object { [DateTimeOffset]::Parse([string]$State.Previews[$_].expiresAt) -lt [DateTimeOffset]::UtcNow })
    foreach ($key in $expired) { $State.Previews.Remove($key) }
}
