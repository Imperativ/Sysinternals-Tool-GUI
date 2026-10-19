[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 18765,

    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$server = Join-Path $PSScriptRoot 'src\Start-SlgServer.ps1'
if (-not (Test-Path -LiteralPath $server -PathType Leaf)) {
    throw "SLG-Agent nicht gefunden: $server"
}

& $server -ProjectRoot $PSScriptRoot -Port $Port -NoBrowser:$NoBrowser
