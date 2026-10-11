# builder/ (fork-only)

Betriebsskripte für den Builder (xcode-builder), auf dem der LaunchAgent
`dev.openchamber.web` OpenChamber auf Port 3000 startet. Nicht für upstream.

- `switch-to-fork.sh`: Startskript auf den Release-Worktree (`~/Projects/openchamber-release`) umstellen, abgekoppelt neu starten, prüfen.
- `switch-to-npm.sh`: Rückweg auf die npm-Installation.
- `lib/activity.sh`: gemeinsame Aktivitätsprüfung vor jedem Neustart.
- `test/activity-test.sh`: Tests der Prüfung mit temporärer SQLite-DB (`sh builder/test/activity-test.sh`).

Beide Skripte kennen `--check` (oder `CHECK_ONLY=1`): nur die Aktivität melden, nichts ändern.
`FORCE=1` schaltet trotz Aktivität um, listet sie aber trotzdem auf.
`~/Projects/openchamber-upstream/switch-to-*.sh` sind Symlinks hierher.

## Aktivitätsregel

Ein Neustart von OpenChamber beendet auch die verwaltete OpenCode-Instanz und bricht laufende
Agent-Züge ab. `activity_check` blockiert (Rückgabe 1), wenn eine dieser Bedingungen zutrifft:

1. **Sessions**: Jede Session, auch Kind-Sessions (`parent_id` gesetzt), deren letzter Eintrag in
   `session_message` (nach `seq`) nicht `idle` ist. `*-switched`-Einträge zählen nicht, sie werden
   oft nach dem `idle` angehängt.
   - Abgebrochene Züge schreiben kein `idle`. Deshalb fragt die Prüfung den Live-Status der
     laufenden OpenCode-Instanz ab: `GET /api/session/active` (Port aus `opencode serve … --port N`,
     Basic Auth mit `OPENCODE_SERVER_PASSWORD` aus der Prozessumgebung, das Passwort geht nur per
     stdin an curl). Die Antwort listet nur laufende Sessions. Aktiv ist, was dort steht; DB-Kandidaten,
     die dort fehlen, werden als "vermutlich abgebrochen" gelistet und ignoriert.
   - Ist der Live-Status nicht abfragbar, blockieren DB-Kandidaten mit letztem Eintrag jünger als
     `STALE_HOURS` (Default 6); ältere werden gelistet und ignoriert.
2. **Prozesse**: `xcodebuild`, `xcrun simctl …`, `simctl`, `xctest` (Liste in
   `ACTIVITY_PROCESS_PATTERNS`, leicht erweiterbar). Lange Builds und UI-Tests schreiben minutenlang
   nichts in die DB. CoreSimulator-Daemons zählen nicht, ebenso `simctl list` (serve-sim fragt das
   alle paar Sekunden ab; `ACTIVITY_PROCESS_IGNORE`).
3. **Kürzlich geändert**: Sessions mit `session_v2.time_updated` in den letzten 120 s.

Die DB wird nur mit `sqlite3 -readonly` geöffnet. Ist sie nicht lesbar, gilt das als aktiv.
Alle Stellschrauben (DB-Pfad, Zeit, Live-Quelle, Prozessliste) stehen im Kopf von `lib/activity.sh`.

## Für künftige Update-Skripte

Jedes Skript, das OpenChamber oder OpenCode auf diesem Rechner neu startet, nutzt diese Lib statt
einer eigenen Prüfung:

```sh
ACTIVITY_TAG="[mein-skript]"
. "$BUILDER_DIR/lib/activity.sh"
activity_check || [ "${FORCE:-0}" = 1 ] || { echo "Aktivität erkannt, später erneut oder FORCE=1" >&2; exit 1; }
```
