# Threat Model – Sysinternals Live GUI

| Bedrohung | Gegenmaßnahme im Bootstrap | Restrisiko / nächste Ausbaustufe |
|---|---|---|
| Fremde Website versucht lokalen Toolstart | Loopback-Hostprüfung, pro Start zufälliger CSRF-Token, Origin-Abgleich sofern vorhanden | Lokaler Schadcode im selben Benutzerkontext ist nicht durch eine Weboberfläche zu lösen. |
| Argument-Injection in `cmd.exe`/PowerShell | Es gibt keinen Shell-Launcher. Nur `ProcessStartInfo` mit einer selbst gequoteten Argumentliste. | Tooleigene Parameter sind weiterhin mächtig; Risiko-Policy und Operatorverantwortung bleiben nötig. |
| Start beliebiger lokaler EXEs | Tool-ID wird ausschließlich gegen das Execution Manifest aufgelöst. Der Client übergibt keinen Pfad. | Manifest-Review muss konsequent bleiben. |
| Manipuliertes Portable-Binary | `Get-AuthenticodeSignature`, Status `Valid`, erwarteter Microsoft-Signer. | MSIX-Alias wird über den Windows-Paketmechanismus vertraut; spätere .NET-Version ergänzt WinVerifyTrust-Details. |
| Manipulierter Download-Link | Nur HTTPS und feste Microsoft-Host-Allowlist, URL kommt nicht vom Client. | Der Bootstrap öffnet lediglich die offizielle Quelle; automatische Akquise folgt erst mit Hash-/ZIP-Inspektion. |
| Versehentliche destruktive Aktion | Risiko-Klassen im Manifest, konkrete Bestätigungsphrase, keine automatische EULA-Annahme. | Vollständige Parameter-Wizards und Richtlinien für jedes Tool sind ein Folgepaket. |
| Sensible Toolausgabe in Logs | Keine Persistenz, Stream nur im RAM, maximal 2000 Events. | Nutzer kann Daten außerhalb der Anwendung exportieren; das kann SLG nicht verhindern. |
| Remote-RCE über Netzwerk | Keine Bindung außerhalb `127.0.0.1`, kein Service, keine Tokens/Credentials. | Remote-Steuerung ist explizit out of scope und braucht mTLS/Auth/Audit-Design. |
| Unternehmensrichtlinie wird umgangen | Keine Policy-, UAC-, AppLocker- oder App-Control-Modifikation. Fehler werden sichtbar zurückgemeldet. | Ein erlaubter Sysinternals-Start kann dennoch von policy blockiert werden; das ist erwartetes Verhalten. |
