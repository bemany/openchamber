# builder/ (fork-only)

Betriebsskripte für den Builder (xcode-builder), auf dem der LaunchAgent
`dev.openchamber.web` OpenChamber auf Port 3000 startet. Nicht für upstream.

- `switch-to-fork.sh`: Startskript auf den Release-Worktree (`~/Projects/openchamber-release`) umstellen, abgekoppelt neu starten, prüfen.
- `switch-to-npm.sh`: Rückweg auf die npm-Installation.
- `lib/activity.sh`: gemeinsame Aktivitätsprüfung vor jedem Neustart.
- `lib/phase.sh`: Einmal-Nachweis und zweite Prüfung der abgekoppelten Neustartphase.
- `test/activity-test.sh`: Tests mit temporärer SQLite-DB und gemocktem `ps`, `curl`, `launchctl` (`sh builder/test/activity-test.sh`).

`~/Projects/openchamber-upstream/switch-to-*.sh` sind Symlinks hierher.

## Aufruf

- `--check` oder `CHECK_ONLY=1`: Wird vor allem anderen behandelt (auch vor dem Aufräum-Trap), meldet
  nur die Aktivität und endet ohne Schreibzugriffe (Exit 0 = ruhig, 1 = aktiv), auch zusammen mit
  anderen Argumenten.
- `FORCE=1`: Schaltet trotz Aktivität um (beide Prüfungen), listet sie aber trotzdem auf.
- `--restart` ist die interne, abgekoppelte Phase. Sie läuft nur mit dem Einmal-Nachweis aus Phase 1:
  eine Datei mit Zufallstoken in einem per `mktemp -d` angelegten 0700-Verzeichnis direkt unter dem
  (kanonisierten) `$TMPDIR` (`openchamber-switch.*`). Verzeichnis und Token gehen per Umgebung, nicht
  über argv, an Phase 2. Beide Skripte übernehmen sie als allererstes in nicht exportierte Variablen und
  entfernen sie aus der Umgebung, kein Kindprozess (auch nicht `launchctl`) sieht sie. Phase 2 akzeptiert
  nur ein Verzeichnis an genau diesem Ort, das nur die Datei `token` enthält, verbraucht sie per `mv`
  (gelingt nur einmal), löscht nur diese Datei, dann das leere Verzeichnis (`rmdir`), und tut erst danach
  etwas. Direkte Aufrufe, selbst gesetzte Werte, falscher Ort, falsche Rechte, fremde Dateien und
  Wiederholungen werden abgewiesen; fremde Verzeichnisse bleiben unangetastet. Das schützt vor versehentlichen Aufrufen,
  ist aber keine Sicherheitsgrenze: Wer als derselbe Benutzer den Nachweis bewusst nachbaut, kommt durch.
- `ACTIVITY_IGNORE_SESSION=<ses_…>`: Aufruf aus einer Agent-Session, siehe unten.

Ablauf:
1. Phase 1 prüft die Voraussetzungen. Läuft die Zielversion schon (`cli.js serve` mit `--port 3000`),
   gleicht sie nur Sicherung/Startskript an und endet mit Exit 0, ohne Aktivitätsprüfung und Neustart.
2. Sonst Aktivitätsprüfung; bei Aktivität Abbruch, bevor Sicherung oder Startskript angefasst werden.
3. Sicherung anlegen, Phase 2 abgekoppelt (`nohup`) starten; Phase 1 kehrt sofort zurück.
4. Phase 2 prüft die Aktivität **ein zweites Mal** (ohne Ausnahmen), schreibt erst danach das
   Startskript um und ruft `launchctl kickstart -k`. Ist jetzt etwas aktiv: kein Neustart,
   Startskript unverändert (nur die Sicherung bleibt, sie schadet nicht), Grund im Log.

**Verbleibendes Rennfenster** (nach der zweiten Prüfung): zwischen dem Ende der zweiten Prüfung und dem Kickstart liegen nur das
Umschreiben des Startskripts (Millisekunden), die Prüfung selbst dauert etwa 1 bis 3 s (curl-Timeout 3 s).
Ein Zug, der genau in diesen Sekunden startet, kann noch abbrechen.

## Aus einer Agent-Session umschalten

Ohne Ausnahme blockiert sich ein Agent selbst (seine Session und die wartenden Eltern-Sessions laufen).
Statt `FORCE=1` die eigene Session-ID mitgeben:

```sh
ACTIVITY_IGNORE_SESSION=ses_… sh ~/Projects/openchamber-upstream/switch-to-fork.sh
```

- Phase 1 nimmt diese Session und alle Vorfahren (`parent_id`-Kette) von der Live- und der
  120-s-Regel aus und listet sie als „ignoriert (Aufrufer)“. Alles andere (andere Sessions, Kind-Sessions
  der eigenen, xcodebuild/simctl) blockiert weiter.
- Phase 2 wartet, bis diese Sessions nicht mehr live laufen (Abfrage alle `ACTIVITY_WAIT_INTERVAL` =
  10 s), wartet dann `ACTIVITY_SETTLE_SECONDS` (Default `ACTIVITY_RECENT_SECONDS` = 120 s) wegen ihres
  eigenen `time_updated` und fragt erneut. Läuft eine davon wieder (z. B. der Lead, der nach dem
  Subagent-Ergebnis aufwacht), geht es zurück in die Warteschleife. Erst wenn sie auch nach dem Nachlauf
  ruhig sind, prüft Phase 2 **ohne** Ausnahme. `ACTIVITY_WAIT_TIMEOUT` (Default 900 s) ist ein
  Gesamtbudget inklusive Nachlauf: Jede Wartezeit wird auf das Restbudget begrenzt; passt der Nachlauf
  nicht mehr hinein, ist das sofort eine Zeitüberschreitung; erreicht die Uhr die Frist (auch genau),
  gibt es keinen Erfolg mehr. In beiden Fällen kein Neustart, Meldung im Log. Ist der
  Live-Status zwischendurch nicht abrufbar, steht das mit Grund im Log und zählt als „läuft noch“. Der Agent sollte seinen Zug also zügig beenden; der Neustart folgt erst, wenn auch
  der Lead fertig ist.
- Eigene Session-ID finden: in OpenChamber (Session-Info) oder in der DB über den Titel:
  `sqlite3 -readonly ~/.local/share/opencode/opencode.db "select id, title from session_v2 order by time_updated desc limit 5"`.
- ID nicht in der DB (z. B. Tippfehler): Ausgenommen wird nur genau diese ID, ohne Vorfahren. Die echte
  eigene Session und ihre Eltern blockieren dann weiter (Selbstblockade statt Lücke). Ungültige Zeichen
  in der ID: blockiert.
- `FORCE=1` wirkt wie bisher: kein Warten, Aktivität wird nur gelistet.

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
     `--hostname`. Passwort aus `OPENCODE_SERVER_PASSWORD` in der Prozessumgebung (`ps eww`, Exitcode
     geprüft, leer oder Fehler = blockiert); es geht escapt als curl-Konfiguration nur per stdin an
     curl, nie in argv, Ausgabe oder Dateien.
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
Zahlen aus der Umgebung (`ACTIVITY_RECENT_SECONDS`, `ALLOW_STALE_HOURS`, `ACTIVITY_WAIT_TIMEOUT`,
`ACTIVITY_SETTLE_SECONDS`, `ACTIVITY_WAIT_INTERVAL` ≥ 1, `OPENCHAMBER_PORT`, `ACTIVITY_NOW_MS`) müssen
nicht-negative Ganzzahlen ohne führende Null sein; sonst blockiert die Prüfung bzw. das Warten mit Meldung.
Alle Stellschrauben stehen im Kopf von `lib/activity.sh`.

### Bekannte Grenzen

- Pfade mit Leerzeichen im Programmpfad werden erkannt, dafür kann eine Befehlszeile wie
  `/bin/cat /tmp/xcodebuild` fälschlich blockieren (sicherer Fehler).
- Ein Passwort mit Leerzeichen wäre aus `ps eww` nicht sicher lesbar; OpenChamber erzeugt base64url.
  Ein falsch gelesenes Passwort führt zu 401 und damit zu „blockiert“.
- Hostnamen nur aus `[A-Za-z0-9.-]` (IPv6 nicht unterstützt, dann blockiert).
- Wer aus einer OpenChamber-Session heraus umschaltet, blockiert sich ohne `ACTIVITY_IGNORE_SESSION` selbst.

## Für künftige Update-Skripte

Jedes Skript, das OpenChamber oder OpenCode auf diesem Rechner neu startet, nutzt diese Lib statt
einer eigenen Prüfung, und zwar vor dem Neustart ein zweites Mal, wenn zwischen Prüfung und Neustart
Zeit vergeht:

```sh
ACTIVITY_TAG="[mein-skript]"
. "$BUILDER_DIR/lib/activity.sh"
activity_check || [ "${FORCE:-0}" = 1 ] || { echo "Aktivität erkannt, später erneut oder FORCE=1" >&2; exit 1; }
```
