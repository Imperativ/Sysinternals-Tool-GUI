# Sysinternals Live GUI – Umsetzung

- [x] **Planung und Sicherheitsgrenzen:** Vollständigen Build-Plan mit Quellen, PRD, Phasen, Tasks und Traceability erstellen.
- [x] **PowerShell-Bootstrap:** Lokalen Loopback-Agenten, deutschen Katalog, Ausführungsmanifest und responsive Browser-GUI implementieren.
- [x] **Ausführungsgrenze:** Manifestgebundene lokale/Live-Quellen, CSRF, Token-Argumente, Risikobestätigung und EULA-Opt-in implementieren.
- [x] **Grundlegende Projektvalidierung:** Syntax-, JSON-, Kreuzreferenz- und No-Binary-/Launch-Invarianten als dependency-freies Prüfskript implementieren.
- [x] **Laufzeitsmoke-Test:** Agent mit `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned` temporär auf Loopback gestartet; Health, statische Assets, Routenmanifest, 79er-Katalog, Suche, Availability und CSRF-/Origin-/Unknown-Tool-Ablehnungen erfolgreich geprüft. Kein Sysinternals-Binary wurde dabei ausgeführt.
- [ ] **.NET-10-Migration:** Sobald die lokale Microsoft-SDK-Installation prüfbar möglich ist, ASP.NET-Core/Blazor-Agent, SQLite und verifizierte Staging-Akquise gemäß Build-Plan umsetzen.
- [ ] **Artefaktabdeckung ausbauen:** Weitere Toolfamilien nach individueller Live-Artefakt-, Parameter- und Risiko-Review in das Execution-Manifest aufnehmen.
