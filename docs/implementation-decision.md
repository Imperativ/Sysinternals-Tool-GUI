# Implementierungsentscheidung: lokaler PowerShell-Bootstrap

**Datum:** 2026-10-14  
**Status:** Accepted for bootstrap

## Kontext

Der freigegebene Build-Plan empfiehlt einen lokalen .NET-10-LTS-Agenten mit ASP.NET Core/Blazor. Auf der aktuellen Arbeitsstation waren jedoch weder .NET-SDK noch alternative C#-Buildtools installiert. Der Abruf des offiziellen Microsoft-SDK-Binärarchivs scheiterte reproduzierbar sowohl über den lokalen Schannel-Client (`SEC_E_NO_CREDENTIALS`) als auch über BITS (`NullReferenceException`).

Eine globale Runtime-Installation, Änderung von TLS-/Zertifikatseinstellungen oder das Umgehen der lokalen PowerShell-Execution-Policy wäre nicht automatisch vertretbar.

## Entscheidung

Für den ersten ausführbaren lokalen Inkrement wird Windows PowerShell 5.1 mit `HttpListener`, statischem HTML/CSS/JavaScript, JSON-Manifests und `System.Diagnostics.ProcessStartInfo` verwendet.

## Folgen

- Die lokale GUI funktioniert ohne NuGet, Node.js, .NET-SDK oder einen Webserverdienst.
- Die Sicherheitsarchitektur bleibt erhalten: Loopback, CSRF, Manifest-Allowlist, Signaturprüfung, tokenisiertes argv, Risiko-Gates und keine Shell.
- SQLite, automatischer verifizierter ZIP-Download, SignalR und der vollwertige ASP.NET-Build bleiben als nächste Umsetzungsschritte offen.
- Die Daten- und HTTP-Verträge sind bewusst so abgegrenzt, dass eine Migration auf .NET keine Nutzerschnittstelle neu erfinden muss.

## Revisit trigger

Diese Entscheidung wird ersetzt, sobald ein offiziell bezogenes, prüfbares .NET-10-SDK lokal verfügbar ist und der ASP.NET-Core-Agent auf diesem Host gebaut und getestet werden kann.
