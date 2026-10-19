# Architektur – PowerShell-Bootstrap

```text
Browser (http://127.0.0.1:18765)
        │  GET static UI / JSON API + CSRF token
        ▼
PowerShell HttpListener Agent
  ├── catalog.json              Toolmetadaten, Kategorien, Doku
  ├── execution-manifest.json   freigegebene Artefakte, Quellen, Risiko
  ├── Availability Resolver     MSIX / Cache / Portable Root / Live UNC
  ├── Invocation Compiler       Tool-ID + Argumenttokens → ProcessStartInfo
  ├── Risk Policy               Phrase-/EULA-Bestätigung
  └── Process Host              CLI-Stream oder nativer GUI-Prozess
```

## Datenhoheit

| Datenbestand | Eigentümer | Persistenz | Sensitivität |
|---|---|---|---|
| `assets/catalog.json` | Projekt | Repository | Keine Geheimnisse; offizielle Metadaten |
| `assets/execution-manifest.json` | Sicherheits-/Execution-Review | Repository | Keine Binaries; Start- und Risikofreigabe |
| `state/cache/` | Lokaler Operator | Kein automatischer Download im Bootstrap | Git-ignoriert |
| Run-Ausgaben/Previews | Laufzeit-Agent | Nur Arbeitsspeicher | Kann sensitiv sein; nicht persistiert |
| CSRF-Token | Laufzeit-Agent | Nur Arbeitsspeicher | Pro Prozessstart zufällig |

## Quellauflösung

1. **MSIX-Alias**: `%LOCALAPPDATA%\Microsoft\WindowsApps\Microsoft.SysinternalsSuite_8wekyb3d8bbwe`.
2. **SLG-Cache**: `state/cache` für eine spätere verifizierte Akquisitionskomponente.
3. **Portable Roots**: ausschließlich die durch `SLG_PORTABLE_ROOTS` gesetzten Pfade.
4. **Live UNC**: exakter Manifestpfad `\\live.sysinternals.com\tools\…`.
5. **Download-Handoff**: nur manifestierte Microsoft-HTTPS-URL im Standardbrowser.

SLG versucht weder Dateinamen zu erraten noch den Live-Share durch Ausführung zu testen. Ein Statusprobe liest ausschließlich Metadaten/Zugriff.

## Öffentliche API

| Methode | Route | Zweck |
|---|---|---|
| GET | `/api/v1/health` | Agent- und Revisionstatus |
| GET | `/api/v1/tools` | Suche, Kategorie und Katalog |
| GET | `/api/v1/tools/{id}` | Detail inklusive hostbezogener Verfügbarkeit |
| POST | `/api/v1/tools/{id}/availability:refresh` | erneute statuslose Auflösung |
| POST | `/api/v1/tools/{id}/download:open` | offizieller Download-Handoff |
| POST | `/api/v1/invocations:preview` | Validierte Source-/argv-/Risikovorschau |
| POST | `/api/v1/invocations:start` | Start nur mit frischer Preview und Bestätigungen |
| GET | `/api/v1/runs/{id}` | Laufstatus und flüchtige CLI-Ereignisse |
| POST | `/api/v1/runs/{id}:cancel` | Stopp ausschließlich eines von SLG gestarteten Prozesses |

Alle mutierenden Routen benötigen `X-SLG-CSRF`; ein vorhandener Origin-Header muss exakt dem Loopback-Ursprung entsprechen.

## Bewusste Bootstrap-Grenzen

- Die zunächst gewählte PowerShell-Implementierung löst den lokalen Toolchain-Blocker. Sie ist keine Abkehr von der Zielarchitektur; die Katalog-, Manifest-, Availability- und Invocation-Contracts bleiben für eine ASP.NET-Core-Implementierung wiederverwendbar.
- Ein Browser kann keine lokale EXE starten. Die Prozessgrenze bleibt daher beim Windows-Agenten.
- Der Bootstrap enthält keinen ZIP-Downloader/Installer. Das ist absichtlich, bis der geplante Staging-, Hash-, ZIP-Slip- und Authenticode-Pipeline-Teil auf einer verfügbaren .NET-Laufzeit integriert und getestet ist.
