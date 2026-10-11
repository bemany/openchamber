# builder/ (fork-only)

Betriebsskripte für den Builder (xcode-builder), auf dem der LaunchAgent
`dev.openchamber.web` OpenChamber auf Port 3000 startet. Nicht für upstream.

- `switch-to-fork.sh`: Startskript auf den Release-Worktree (`~/Projects/openchamber-release`) umstellen, abgekoppelt neu starten, prüfen.
- `switch-to-npm.sh`: Rückweg auf die npm-Installation.
- `lib/activity.sh`: gemeinsame Aktivitätsprüfung vor jedem Neustart.
- `test/activity-test.sh`: Tests mit temporärer SQLite-DB und gemocktem `ps`, `curl`, `launchctl` (`sh builder/test/activity-test.sh`).

`~/Projects/openchamber-upstream/switch-to-*.sh` sind Symlinks hierher.

## Aufruf

- `--check` oder `CHECK_ONLY=1`: Wird vor allem anderen behandelt, meldet nur die Aktivität und endet
  ohne Seiteneffekte (Exit 0 = ruhig, 1 = aktiv), auch zusammen mit anderen Argumenten.
- `FORCE=1`: Schaltet trotz Aktivität um (beide Prüfungen), listet sie aber trotzdem auf.
- `--restart` ist die interne, abgekoppelte Phase. Sie läuft nur mit dem Zufallstoken, das Phase 1
  beim `nohup`-Aufruf als Umgebungsvariable und Argument setzt; ein direkter Aufruf wird abgewiesen.

Ablauf: Phase 1 prüft Voraussetzungen und Aktivität, legt die Sicherung an und startet Phase 2
abgekoppelt. Phase 2 prüft die Aktivität **ein zweites Mal**, schreibt erst danach das Startskript um
und ruft `launchctl kickstart -k`. Ist bei der zweiten Prüfung etwas aktiv, bricht sie ab: kein
Neustart, Startskript unverändert (nur die Sicherung aus Phase 1 bleibt, sie schadet nicht).
Läuft die Zielversion schon, gleicht Phase 1 nur das Startskript an, ohne Neustart.

**Verbleibendes Rennfenster:** zwischen dem Ende der zweiten Prüfung und dem Kickstart liegen nur das
Umschreiben des Startskripts (Millisekunden), die Prüfung selbst dauert etwa 1 bis 3 s (curl-Timeout 3 s).
Ein Zug, der genau in diesen Sekunden startet, kann noch abbrechen.

## Aktivitätsregel (fail-closed)

Ein Neustart von OpenChamber beendet auch die verwaltete OpenCode-Instanz und bricht laufende
Agent-Züge ab. `activity_check` blockiert (Rückgabe 1), wenn eine dieser Bedingungen zutrifft, und
auch dann, wenn etwas nicht sicher geprüft werden kann:

1. **Sessions**: Jede Session, auch Kind-Sessions (`parent_id` gesetzt) und bewusst auch archivierte
   Sessions, deren letzter Eintrag in `session_message` (nach `seq`) nicht `idle` ist.
   `*-switched`-Einträge zählen nicht, sie werden oft nach dem `idle` angehängt.
   - Abgebrochene Züge schreiben kein `idle`. Deshalb entscheidet der Live-Status der von OpenChamber
     verwalteten OpenCode-Instanz: `GET /api/session/active`. Die Antwort `{"data":{"<id>":{…}}}`
     listet nur laufende Sessions. Gelistet = aktiv; DB-Kandidaten, die dort fehlen, werden als
     „vermutlich abgebrochen“ gelistet und ignoriert. Live laufende Sessions blockieren auch, wenn die
     DB schon `idle` zeigt.
   - Instanz: genau ein Prozess `… cli.js serve … --port 3000` (`OPENCHAMBER_PORT`) und genau ein
     Kindprozess `opencode serve` davon (PPID). Port aus `--port N` oder `--port=N`, Host aus
     `--hostname`. Passwort aus `OPENCODE_SERVER_PASSWORD` in der Prozessumgebung (`ps eww`); es geht
     escapt als curl-Konfiguration nur per stdin an curl, nie in argv, Ausgabe oder Dateien.
   - **Live-Status nicht verfügbar = blockiert**: keine oder mehrere passende Instanzen, Port nicht
     lesbar, curl-Fehler/Timeout, HTTP ≠ 200 (z. B. 401), kein JSON oder nicht die Form oben.
     Dann hilft nur `FORCE=1` oder der ausdrückliche Override `ALLOW_STALE_HOURS=N`: Kandidaten mit
     letztem Eintrag älter als N Stunden werden ignoriert, jüngere blockieren.
2. **Prozesse**: `xcodebuild`, `xcrun … simctl`, `simctl`, `xctest` (Liste in
   `ACTIVITY_PROCESS_PATTERNS`, leicht erweiterbar). Lange Builds und UI-Tests schreiben minutenlang
   nichts in die DB. Ein Programm zählt, wenn die Befehlszeile mit `prog` oder `<pfad>/prog` beginnt;
   `prog:arg` verlangt zusätzlich `arg` als spätere Wortgruppe (`xcrun --sdk … simctl` wird erkannt).
   CoreSimulator-Daemons zählen nicht, ebenso jedes `simctl list` (serve-sim fragt das alle paar
   Sekunden ab; `ACTIVITY_PROCESS_IGNORE`). `ps` scheitert oder liefert nichts = blockiert.
3. **Kürzlich geändert**: Sessions mit `session_v2.time_updated` in den letzten 120 s.

Die DB wird nur mit `sqlite3 -readonly` geöffnet. Fehlt sie oder ist sie gesperrt: blockiert.
Alle Stellschrauben stehen im Kopf von `lib/activity.sh`.

### Bekannte Grenzen

- Pfade mit Leerzeichen im Programmpfad werden erkannt, dafür kann eine Befehlszeile wie
  `/bin/cat /tmp/xcodebuild` fälschlich blockieren (sicherer Fehler).
- Ein Passwort mit Leerzeichen wäre aus `ps eww` nicht sicher lesbar; OpenChamber erzeugt base64url.
  Ein falsch gelesenes Passwort führt zu 401 und damit zu „blockiert“.
- Hostnamen nur aus `[A-Za-z0-9.-]` (IPv6 nicht unterstützt, dann blockiert).
- Wer aus einer OpenChamber-Session heraus umschaltet, blockiert sich selbst (die eigene Session läuft).

## Für künftige Update-Skripte

Jedes Skript, das OpenChamber oder OpenCode auf diesem Rechner neu startet, nutzt diese Lib statt
einer eigenen Prüfung, und zwar vor dem Neustart ein zweites Mal, wenn zwischen Prüfung und Neustart
Zeit vergeht:

```sh
ACTIVITY_TAG="[mein-skript]"
. "$BUILDER_DIR/lib/activity.sh"
activity_check || [ "${FORCE:-0}" = 1 ] || { echo "Aktivität erkannt, später erneut oder FORCE=1" >&2; exit 1; }
```
