# Sysinternals Live GUI (SLG)

- Einheitlicher Projekt-/Repository-Name: `Sysinternals-live-GUI`
- GitHub: https://github.com/Imperativ/Sysinternals-live-GUI (vormals `Sysinternals-Tool-GUI`)
- Lokaler Projektordner: `E:/imp-projekte/Manus-Projekte/Sysinternals-live-GUI`
- Die lokale Implementierung und die ursprüngliche GitHub-Projektanlage gehören zu demselben Projekt; die vorhandene GitHub-Historie wird beibehalten.

SLG ist ein **lokaler Windows-Agent mit browserbasierter GUI** für die offiziellen Microsoft-Sysinternals-Utilities. Er bindet ausschließlich an `http://127.0.0.1`, katalogisiert 79 aktuelle bzw. im Live-Verzeichnis vorhandene Toolfamilien und trennt sauber zwischen:

- **lokal startbar**: Microsoft-Store-Alias, SLG-Cache oder explizit konfigurierte Portable-Root;
- **über Live startbar**: konkretes, im Manifest hinterlegtes UNC-Artefakt auf `\\live.sysinternals.com\tools\…`;
- **Download verfügbar**: offizieller Microsoft-Link vorhanden;
- **katalogisiert, aber nicht startfreigegeben**: keine geprüfte Artefakt-/Risikozuordnung;
- **nicht auf Windows ausführbar**: etwa macOS-/Linux-only-Tools.

> Die GUI läuft im Browser, führt Sysinternals-Binaries aber immer auf **diesem Windows-Host** aus. Sie ist absichtlich kein Fernsteuerungsdienst.

## Aktueller Implementierungsstand

Dieser lokale Projektstand enthält einen **funktionalen dependency-freien PowerShell-Bootstrap** statt der im Build-Plan empfohlenen .NET-10-Ausgabe. Der Grund ist die aktuelle lokale Entwicklungsumgebung: kein .NET-SDK verfügbar und sämtliche offiziellen SDK-Downloadwege scheitern im lokalen Schannel-/BITS-Kontext. Der Bootstrap hält die geplanten Sicherheitsgrenzen ein und kann später hinter derselben Manifest-/HTTP-Schnittstelle auf ASP.NET Core migriert werden.

Enthalten sind:

- deutscher Toolkatalog, Kategorie- und Volltextsuche;
- getrenntes Katalog- und Execution-Manifest;
- Host-/Architektur-, lokaler Store-/Cache-/Portable-Root- und Live-UNC-Status;
- nur manifestgebundene lokale oder Live-Starts;
- parameterbasierte `argv`-Vorschau ohne `cmd.exe`, PowerShell-Evaluation oder freie EXE-Auswahl;
- Risiko-/EULA-Bestätigung vor zustandsverändernden, persistenten, destruktiven oder Remote-Aktionen;
- Laufstatus und flüchtige CLI-Ausgabe im Browser;
- offizieller Download-Handoff für fehlende, manifestierte Tools.

Nicht enthalten: Binary-Redistribution, Policy-Umgehung, Credential-Speicher, Netzwerk-Listener außerhalb Loopback, persistenter Systemdienst, automatisierte ZIP-Installation oder Multi-Host-Remote-Steuerung.

## Starten

Der Agent ändert keine Execution Policy. Auf diesem Rechner ist PowerShell-Skriptausführung derzeit vollständig deaktiviert. Wenn du die lokale, nur für die aktuelle PowerShell-Sitzung gültige Ausführung erlauben möchtest, öffne **selbst** eine PowerShell im Projektordner und führe aus:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
.\Start-SysinternalsLiveGui.ps1
```

Optional ohne Browserstart oder auf abweichendem Loopback-Port:

```powershell
.\Start-SysinternalsLiveGui.ps1 -NoBrowser -Port 18765
```

Danach öffnest du `http://127.0.0.1:18765/`. Mit `Ctrl+C` beendest du den Agenten. Die Scope-Process-Policy erlischt, sobald dieses PowerShell-Fenster geschlossen wird; es werden keine globalen oder Benutzer-Policies verändert.

### Portable Installationen

Neben der Microsoft-Store-Suite und dem SLG-Cache kann SLG explizite Portable-Verzeichnisse prüfen. Setze sie vor dem Start als semikolongetrennte Liste:

```powershell
$env:SLG_PORTABLE_ROOTS = 'C:\Tools\Sysinternals;D:\Admin\Sysinternals'
.\Start-SysinternalsLiveGui.ps1
```

Ein Fundort wird nur als lokal startbar markiert, wenn die Authenticode-Prüfung erfolgreich ist und das Zertifikat zu Microsoft Corporation passt. MSIX-App-Execution-Aliase der Suite werden separat als Store-Quelle erkannt.

## Sicherheitsmodell

1. **Loopback only:** Listener auf `127.0.0.1`; andere Host-Header werden abgewiesen.
2. **CSRF-Schutz:** Jede zustandsverändernde API-Anfrage benötigt ein zufälliges, pro Agentstart erzeugtes Token; ein abweichender `Origin` wird abgewiesen.
3. **Keine Shell:** Der Launcher erhält nur Tool-ID, Source Mode und ein tokenisiertes Argumentarray. Er baut daraus eine korrekt gequotete Windows-Prozessargumentliste, ohne `cmd.exe`, `Invoke-Expression` oder freie Dateipfade.
4. **Allowlist:** Nur Artefakte aus `assets/execution-manifest.json` dürfen ausgeführt werden. Ein Katalogeintrag allein erlaubt keinen Start.
5. **Supply chain:** Der Download-Handoff akzeptiert nur hinterlegte HTTPS-URLs zu offiziellen Microsoft-Hosts. Die Anwendung enthält und verteilt keinerlei Sysinternals-Binaries.
6. **Risikogates:** Tools mit Prozess-, System-, Dienst-/Treiber-, Lösch- oder Remote-Wirkung verlangen die genaue Bestätigungsphrase. `-accepteula` wird nie vom Agenten ergänzt und muss separat bestätigt werden.
7. **Datensparsamkeit:** Parameter und Toolausgaben werden nicht dauerhaft gespeichert. Konsolenausgabe ist flüchtig und auf 2000 Ereignisse pro Lauf begrenzt.

Weitere Details: [Architektur](docs/architecture.md), [Threat Model](docs/threat-model.md) und [Build-Plan](outputs/sysinternals-live-gui-build-plan.md).

## Validierung

Die strukturelle Projektprüfung benötigt keine externen Abhängigkeiten:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
.\tests\Validate-SlgProject.ps1
```

Sie validiert die PowerShell-Syntax, JSON-Daten, Tool-/Manifestreferenzen, die fehlende Binary-Redistribution und grundlegende Launch-Sicherheitsinvarianten. Einen realen Live-UNC-/Toolstarttest erst auf einem kontrollierten Windows-Testsystem ausführen.

## Offizielle Quellen

- [Sysinternals Live](https://learn.microsoft.com/en-us/sysinternals/)
- [Sysinternals Utilities Index](https://learn.microsoft.com/en-us/sysinternals/downloads/)
- [Live-Verzeichnis](https://live.sysinternals.com/)
- [Sysinternals Software License Terms](https://learn.microsoft.com/en-us/sysinternals/license-terms)
- [Microsoft Store – Sysinternals Suite](https://learn.microsoft.com/en-us/sysinternals/downloads/microsoft-store)
