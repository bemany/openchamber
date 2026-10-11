#!/bin/sh
# Tests für builder/lib/activity.sh und die --check/--restart-Zweige der
# Umschaltskripte. Temporäre SQLite-DB (Schema wie OpenCode session_v2/
# session_message), gemockte ps-, curl-, Umgebungs- und launchctl-Aufrufe.
# Fasst weder die produktive DB noch launchctl noch Port 3000 an.
#
#   sh builder/test/activity-test.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/../lib/activity.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/activity-test.XXXXXX")
MOCK="$TMP/mock"
# Abgekoppelte Phase 2 aus dem nohup-Test samt Kindprozessen beenden und auf ihr
# Ende warten; erst danach wird $TMP (mit der Freigabe) gelöscht.
killtree() { for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done; kill "$1" 2>/dev/null; }
stop_phase2() {
  [ -f "$MOCK/phase2.pid" ] || return 0
  p2=$(cat "$MOCK/phase2.pid")
  case "$(ps -o args= -p "$p2" 2>/dev/null)" in *" --restart "*) killtree "$p2" ;; esac
  i=0; while kill -0 "$p2" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  rm -f "$MOCK/phase2.pid"
}
cleanup() { stop_phase2; rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$MOCK"

NOW=1800000000000          # festes "jetzt" in ms
H=3600000                  # eine Stunde in ms
OLD=$((NOW - 48 * H))      # session_v2.time_updated weit außerhalb der 2-Minuten-Regel
FAIL=0
N=0

# --- Mocks --------------------------------------------------------------------
# curl: liest die Konfiguration von stdin, antwortet aus $MOCK/curl.{body,code,fail}
cat > "$MOCK/curl" <<'EOF'
#!/bin/sh
cat > "$MOCK/curl.cfg"
for a in "$@"; do url=$a; done
echo "$url" > "$MOCK/curl.url"
if [ -f "$MOCK/curl.fail" ]; then echo "curl: (28) Operation timed out" >&2; printf '\n000'; exit 28; fi
printf '%s\n%s' "$(cat "$MOCK/curl.body")" "$(cat "$MOCK/curl.code")"
EOF
# Prozessumgebung: "ps eww"-artige Zeile mit Passwort aus $MOCK/pw
cat > "$MOCK/env" <<'EOF'
#!/bin/sh
echo "/x/opencode serve --port 4096 HOME=/x OPENCODE_SERVER_PASSWORD=$(cat "$MOCK/pw") TERM=dumb"
EOF
# launchctl und Health-curl für die Skripte
printf '#!/bin/sh\necho "$*" >> "$MOCK/launchctl.log"\nenv | grep PROOF > "$MOCK/launchctl.env" || true\n' > "$MOCK/launchctl"
printf '#!/bin/sh\nprintf 200\n' > "$MOCK/health"
chmod +x "$MOCK"/*
export MOCK

new_db() {
  DBF="$TMP/db-$N.sqlite"
  rm -f "$DBF"
  sqlite3 "$DBF" <<'SQL'
CREATE TABLE `session_v2` (
  `id` text PRIMARY KEY, `project_id` text NOT NULL, `workspace_id` text, `parent_id` text,
  `fork_session_id` text, `fork_boundary` text, `slug` text NOT NULL, `directory` text NOT NULL,
  `path` text, `title` text, `version` text NOT NULL, `share_url` text, `summary_additions` integer,
  `summary_deletions` integer, `summary_files` integer, `summary_diffs` text, `metadata` text,
  `cost` real DEFAULT 0 NOT NULL, `tokens_input` integer DEFAULT 0 NOT NULL,
  `tokens_output` integer DEFAULT 0 NOT NULL, `tokens_reasoning` integer DEFAULT 0 NOT NULL,
  `tokens_cache_read` integer DEFAULT 0 NOT NULL, `tokens_cache_write` integer DEFAULT 0 NOT NULL,
  `revert` text, `permission` text, `agent` text, `model` text, `time_created` integer NOT NULL,
  `time_updated` integer NOT NULL, `time_compacting` integer, `time_archived` integer,
  `time_suspended` integer, `resume_attempts` integer DEFAULT 0 NOT NULL, `time_idle` integer,
  `time_viewed` integer, `idle_outcome` text
);
CREATE TABLE "session_message" (
  `id` text PRIMARY KEY, `session_id` text NOT NULL, `type` text NOT NULL, `seq` integer NOT NULL,
  `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL
);
CREATE UNIQUE INDEX `session_message_session_seq_idx` ON `session_message` (`session_id`,`seq`);
SQL
}

# session <id> <title> [parent] [time_updated]
session() {
  sqlite3 "$DBF" "insert into session_v2 (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated)
    values ('$1', 'p', $( [ -n "${3:-}" ] && echo "'$3'" || echo null ), 's', '/tmp', '$2', '1', $OLD, ${4:-$OLD})"
}

# msg <session> <seq> <type> <time>
msg() {
  sqlite3 "$DBF" "insert into session_message values ('m_$1_$2', '$1', '$3', $2, $4, $4, '{}')"
}

# Prozessliste (pid ppid args) für ACTIVITY_PS_CMD
ps_lines() { printf '%s\n' "$@" > "$MOCK/ps"; }
OC='100 1 /opt/node /srv/openchamber/packages/web/bin/cli.js serve --foreground --port 3000 --host 0.0.0.0'
OCS='200 100 /Users/u/.opencode/bin/opencode serve --hostname 127.0.0.1 --port 4096'
api() { printf '%s' "$1" > "$MOCK/curl.body"; printf '%s' "${2:-200}" > "$MOCK/curl.code"; rm -f "$MOCK/curl.fail"; }

result() { # <name> <ok 0/1> <Ausgabe>
  N=$((N + 1))
  if [ "$2" = 1 ]; then echo "ok   $1"; else
    echo "FAIL $1"; printf '%s\n' "$3" | sed 's/^/     /'; FAIL=$((FAIL + 1))
  fi
}

# check <name> <erwarteter Rückgabewert> <muss enthalten> [darf nicht enthalten]
# Live-Quelle: LIVE (Befehl) oder, wenn leer, die echte activity_live_default mit Mocks.
check() {
  OUT=$(
    ACTIVITY_DB="$DBF" ACTIVITY_NOW_MS=$NOW ACTIVITY_TAG="[t]" \
      ACTIVITY_LIVE_CMD="${LIVE:-}" ACTIVITY_PS_CMD="${PS:-cat $MOCK/ps}" \
      ACTIVITY_CURL="$MOCK/curl" ACTIVITY_ENV_CMD="$MOCK/env" ALLOW_STALE_HOURS="${ALLOW:-}" \
      ACTIVITY_IGNORE_SESSION="${IGN:-}"
    export ACTIVITY_DB ACTIVITY_NOW_MS ACTIVITY_TAG ACTIVITY_LIVE_CMD ACTIVITY_PS_CMD ACTIVITY_CURL ACTIVITY_ENV_CMD ALLOW_STALE_HOURS ACTIVITY_IGNORE_SESSION
    . "$LIB"
    activity_check 2>&1
  )
  RC=$?
  ok=1
  [ "$RC" = "$2" ] || ok=0
  printf '%s\n' "$OUT" | grep -qF -- "$3" || ok=0
  if [ -n "${4:-}" ] && printf '%s\n' "$OUT" | grep -qF -- "$4"; then ok=0; fi
  result "$1" $ok "rc=$RC (erwartet $2), Muster '$3'
$OUT"
  LIVE=; PS=; ALLOW=; IGN=
}

# Standard: ruhige Prozessliste mit eindeutiger Instanz, API meldet nichts laufend
quiet() { ps_lines "1 0 /sbin/launchd" "$OC" "$OCS"; api '{"data":{}}'; printf 'pw' > "$MOCK/pw"; }

# === DB-Regeln ===================================================================
quiet; new_db; session s1 "Fertig"; msg s1 1 user $((NOW - H)); msg s1 2 assistant $((NOW - H)); msg s1 3 idle $((NOW - H))
check "idle zuletzt -> ruhig" 0 "Ergebnis: ruhig" "BLOCK"

quiet; new_db; session s2 "Läuft"; msg s2 1 user $((NOW - 600000)); msg s2 2 assistant $((NOW - 300000))
api '{"data":{"s2":{"type":"running"}}}'
check "assistant zuletzt, live läuft -> aktiv" 1 "BLOCK  Session s2"

quiet; new_db; session s3 "Recherche"; msg s3 1 assistant $((NOW - H)); msg s3 2 idle $((NOW - H))
msg s3 3 model-switched $((NOW - 60000)); msg s3 4 agent-switched $((NOW - 60000))
check "idle + switched danach -> ruhig" 0 "Ergebnis: ruhig" "s3"

quiet; new_db; session p4 "Parent"; msg p4 1 idle $((NOW - H))
session c4 "Kind" p4; msg c4 1 user $((NOW - 120000)); msg c4 2 assistant $((NOW - 60000))
api '{"data":{"c4":{"type":"running"}}}'
check "Kind-Session aktiv -> aktiv, Parent genannt" 1 "BLOCK  Session c4  \"Kind\"  letzter=assistant"
check "Kind-Session nennt Parent" 1 "parent=p4"

quiet; new_db; session s6 "Langer Build"; msg s6 1 assistant $((NOW - 7 * H))
api '{"data":{"s6":{"type":"busy"}}}'
check "alt, live läuft -> aktiv" 1 "BLOCK  Session s6"

quiet; new_db; session s7 "Abgebrochen"; msg s7 1 assistant $((NOW - 300000))
check "live {data:{}}, Kandidat jung -> ignoriert, ruhig" 0 "IGNORE Session s7" "BLOCK"

quiet; new_db; session s8 "Gerade gestartet"; msg s8 1 idle $((NOW - H))
api '{"data":{"s8":{"type":"running"}}}'
check "live läuft, DB idle -> aktiv" 1 "BLOCK  Session s8 (live: läuft"

quiet; new_db; session s10 "Eben geändert" "" $((NOW - 30000)); msg s10 1 idle $((NOW - 30000))
check "time_updated < 2 min -> aktiv" 1 "BLOCK  Kürzlich s10"

# === Fail-closed: Live-Status nicht verfügbar ====================================
quiet; new_db; session s5 "Abgebrochen alt"; msg s5 1 assistant $((NOW - 7 * H))
LIVE=false; check "Live fehlt, Kandidat alt -> blockiert" 1 "BLOCK  Session s5"
quiet; new_db; LIVE=false; check "Live fehlt, keine Kandidaten -> blockiert" 1 "BLOCK  Live-Status nicht verfügbar"
LIVE=false; check "Live fehlt -> Meldung nennt FORCE/ALLOW" 1 "FORCE=1 oder ALLOW_STALE_HOURS"
quiet; new_db; session s5 "Abgebrochen alt"; msg s5 1 assistant $((NOW - 7 * H))
LIVE=false; ALLOW=6; check "ALLOW_STALE_HOURS=6, Kandidat alt -> ignoriert" 0 "IGNORE Session s5" "BLOCK"
quiet; new_db; session s5 "Jung"; msg s5 1 assistant $((NOW - H))
LIVE=false; ALLOW=6; check "ALLOW_STALE_HOURS=6, Kandidat jung -> blockiert" 1 "BLOCK  Session s5"

# === activity_live_default (echte Abfrage, gemockt) ==============================
live_run() { # gibt Ausgabe und rc der Live-Abfrage auf Basis von $MOCK/ps
  ( ACTIVITY_CURL="$MOCK/curl" ACTIVITY_ENV_CMD="${ENVCMD:-$MOCK/env}"; . "$LIB"; activity_live_default "$(cat "$MOCK/ps")" ) 2>&1
}
live_case() { # <name> <rc> <muss enthalten>
  OUT=$(live_run); RC=$?
  ok=1; [ "$RC" = "$2" ] || ok=0; printf '%s\n' "$OUT" | grep -qF -- "$3" || ok=0
  result "$1" $ok "rc=$RC (erwartet $2), Muster '$3'
$OUT"
}

quiet; api '{"data":{"ses_a":{"type":"running"},"ses_b":{"type":"retry"}}}'
live_case "Live: --port N, IDs gelesen" 0 "ses_b"
result "Live: richtige URL" "$(grep -qx 'http://127.0.0.1:4096/api/session/active' "$MOCK/curl.url" && echo 1 || echo 0)" "$(cat "$MOCK/curl.url")"

ps_lines "100 1 /opt/node /srv/bin/cli.js serve --port=3000" "201 100 /x/opencode serve --hostname=127.0.0.1 --port=4097"
live_case "Live: --port=N-Form" 0 "ses_a"
result "Live: --port=N ergibt Port 4097" "$(grep -q ':4097/' "$MOCK/curl.url" && echo 1 || echo 0)" "$(cat "$MOCK/curl.url")"

ps_lines "1 0 /sbin/launchd" "$OCS"
live_case "Live: kein OpenChamber-Prozess -> Fehler" 1 "nicht eindeutig gefunden (0"
ps_lines "$OC" "101 1 /opt/node /other/bin/cli.js serve --port 3000" "$OCS"
live_case "Live: zwei OpenChamber auf 3000 -> Fehler" 1 "nicht eindeutig gefunden (2"
ps_lines "$OC" "$OCS" "201 100 /x/opencode serve --port 4097"
live_case "Live: zwei OpenCode-Kinder -> Fehler" 1 "nicht eindeutig gefunden (2"
ps_lines "$OC" "200 1 /x/opencode serve --port 4096" "300 1 /opt/node /x/bin/cli.js serve --port 3299" "301 300 /x/opencode serve --port 4199"
live_case "Live: OpenCode nicht Kind von 3000 (fremde Instanz) -> Fehler" 1 "nicht eindeutig gefunden (0"
ps_lines "$OC" "200 100 /x/opencode serve"
live_case "Live: ohne Port -> Fehler" 1 "Port der OpenCode-Instanz"

quiet; : > "$MOCK/curl.fail"
live_case "Live: curl-Fehler/Timeout -> Fehler" 1 "fehlgeschlagen"
quiet; api '{"_tag":"UnauthorizedError"}' 401
live_case "Live: 401 -> Fehler" 1 "HTTP 401 (Passwort fehlt oder falsch)"
quiet; api '<!doctype html><html></html>'
live_case "Live: HTML-Antwort -> Fehler" 1 "nicht die Form"
quiet; api '{"data":[]}'
live_case "Live: data kein Objekt -> Fehler" 1 "nicht die Form"
quiet; api '{"data":{"ses_a":1}}'
live_case "Live: Wert kein Objekt -> Fehler" 1 "nicht die Form"
quiet; api '{"other":{}}'
live_case "Live: data fehlt -> Fehler" 1 "nicht die Form"
quiet; api "{\"data\":{\"it's\":{\"type\":\"running\"}}}"
live_case "Live: Apostroph im JSON" 0 "it's"
quiet
live_case "Live: {data:{}} -> ok, leer" 0 ""

quiet; printf '%s' 'a"b\c d' > "$MOCK/pw"
cat > "$MOCK/env" <<'EOF'
#!/bin/sh
printf '%s\n' '/x/opencode serve OPENCODE_SERVER_PASSWORD=a"b\c' 
EOF
live_run > /dev/null
result "Passwort in curl-Konfig escapt" "$(grep -qxF 'user = "opencode:a\"b\\c"' "$MOCK/curl.cfg" && echo 1 || echo 0)" "$(sed 's/opencode:.*/opencode:<…>/' "$MOCK/curl.cfg")"
quiet; new_db; printf 'Geh31m-Pw' > "$MOCK/pw"
cat > "$MOCK/env" <<'EOF'
#!/bin/sh
echo "/x/opencode serve --port 4096 HOME=/x OPENCODE_SERVER_PASSWORD=$(cat "$MOCK/pw") TERM=dumb"
EOF
api '{"_tag":"UnauthorizedError"}' 401
check "Passwort erscheint nicht in der Ausgabe" 1 "HTTP 401" "Geh31m-Pw"

# Prozessumgebung: Exitcode geprüft, leer = Fehler
printf '#!/bin/sh\necho "/x/opencode serve OPENCODE_SERVER_PASSWORD=pw"\nexit 1\n' > "$MOCK/envpartial"; chmod +x "$MOCK/envpartial"
quiet; ENVCMD=false live_case "Live: Prozessumgebung Fehler -> Fehler" 1 "Prozessumgebung von PID 200 nicht lesbar"
quiet; ENVCMD="$MOCK/envpartial" live_case "Live: Prozessumgebung Teil-Ausgabe + Fehlercode -> Fehler" 1 "nicht lesbar"
quiet; ENVCMD=true live_case "Live: Prozessumgebung leer -> Fehler" 1 "Prozessumgebung von PID 200 leer"
result "Live: nach Umgebungsfehler kein curl-Aufruf" "$(rm -f "$MOCK/curl.url"; ENVCMD=false live_run >/dev/null; [ ! -f "$MOCK/curl.url" ] && echo 1 || echo 0)" ""

# === Live-Fehler blockieren activity_check =======================================
quiet; new_db; : > "$MOCK/curl.fail"
check "activity_check: curl-Fehler -> blockiert" 1 "BLOCK  Live-Status nicht verfügbar: Abfrage"
quiet; new_db; ps_lines "1 0 /sbin/launchd"
check "activity_check: keine Instanz -> blockiert" 1 "BLOCK  Live-Status nicht verfügbar: OpenChamber"

# === Prozesse ====================================================================
quiet; new_db; PS=false
check "ps-Fehler -> blockiert" 1 "BLOCK  Prozessliste nicht lesbar"
quiet; new_db; PS=true
check "ps leer -> blockiert" 1 "BLOCK  Prozessliste nicht lesbar"
quiet; new_db
ps_lines "$OC" "$OCS" \
  "101 1 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService" \
  "102 1 /usr/libexec/simdiskimaged" "103 1 launchd_sim /x" "104 1 /usr/bin/xcrun xcode-select" \
  "105 7977 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl list devices booted -j" \
  "106 1 /usr/bin/xcrun simctl list devices" "107 1 simctl list" "108 1 xcrun --sdk iphonesimulator simctl list runtimes" \
  "109 1 /usr/bin/grep xcodebuild"
check "Daemons und simctl list (alle Varianten) -> ruhig" 0 "Ergebnis: ruhig" "Prozess"
quiet; new_db; ps_lines "$OC" "$OCS" "  201     1 /usr/bin/xcrun simctl io booted screenshot /tmp/a.png"
check "xcrun simctl (führende Leerzeichen) -> aktiv" 1 "BLOCK  Prozess 201 /usr/bin/xcrun simctl io"
quiet; new_db; ps_lines "$OC" "$OCS" "202 1 xcrun --sdk iphonesimulator simctl boot X"
check "xcrun --sdk … simctl -> aktiv" 1 "BLOCK  Prozess 202"
quiet; new_db; ps_lines "$OC" "$OCS" "203 1 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -scheme X"
check "xcodebuild -> aktiv" 1 "BLOCK  Prozess 203"
quiet; new_db; ps_lines "$OC" "$OCS" "204 1 /Users/a b/Xcode Beta.app/Contents/Developer/usr/bin/xcodebuild build"
check "xcodebuild mit Leerzeichen im Pfad -> aktiv" 1 "BLOCK  Prozess 204"
quiet; new_db; ps_lines "$OC" "$OCS" "205 1 /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest /tmp/X.xctest"
check "xctest -> aktiv" 1 "BLOCK  Prozess 205"
quiet; new_db; ps_lines "$OC" "$OCS" "206 1 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl install booted /tmp/A.app"
check "simctl install -> aktiv" 1 "BLOCK  Prozess 206"

# === Ausnahme für den Aufrufer (ACTIVITY_IGNORE_SESSION) ==========================
ign_db() { new_db; session root "Lead"; msg root 1 assistant $((NOW - 600000))
  session mid "Worker" root; msg mid 1 assistant $((NOW - 300000))
  session me "Ich" mid; msg me 1 assistant $((NOW - 60000))
  session other "Fremd"; msg other 1 idle $((NOW - H)); }
quiet; ign_db; api '{"data":{"root":{},"mid":{},"me":{}}}'
IGN=me; check "Ignore: Aufrufer und Vorfahren ausgenommen -> ruhig" 0 "IGNORE Session root" "BLOCK"
quiet; ign_db; api '{"data":{"root":{},"mid":{},"me":{}}}'
IGN=me; check "Ignore: als Aufrufer gelistet" 0 "ignoriert (Aufrufer)"
quiet; ign_db; api '{"data":{"root":{},"mid":{},"me":{},"other":{}}}'
IGN=me; check "Ignore: andere Session läuft -> aktiv" 1 "BLOCK  Session other"
quiet; ign_db; api '{"data":{"root":{},"mid":{},"me":{}}}'
IGN=mid; check "Ignore: nur Vorfahren, Kind läuft -> aktiv" 1 "BLOCK  Session me"
quiet; ign_db; api '{"data":{"me":{}}}'; sqlite3 "$DBF" "update session_v2 set time_updated = $((NOW - 10000)) where id in ('me', 'other')"
IGN=me; check "Ignore: 120-s-Regel nimmt Aufrufer aus, andere nicht" 1 "BLOCK  Kürzlich other"
quiet; ign_db; api '{"data":{"me":{}}}'; sqlite3 "$DBF" "update session_v2 set time_updated = $((NOW - 10000)) where id = 'me'"
IGN=me; check "Ignore: 120-s-Regel Aufrufer -> IGNORE" 0 "IGNORE Kürzlich me"
quiet; ign_db; api '{"data":{"me":{}}}'
IGN="me'; drop table x; --"; check "Ignore: ungültige ID -> blockiert" 1 "ACTIVITY_IGNORE_SESSION ungültig"
quiet; ign_db; api '{"data":{"me":{}}}'
IGN=ses_unbekannt; check "Ignore: unbekannte ID nimmt nichts aus" 1 "BLOCK  Session me"

# === activity_runs_cli ==========================================================
runs_case() { # <name> <cli> <0/1 erwartet>
  R=$( ACTIVITY_PS_CMD="${PS:-cat $MOCK/ps}"; . "$LIB"; activity_runs_cli "$2" && echo 0 || echo 1 )
  result "$1" "$([ "$R" = "$3" ] && echo 1 || echo 0)" "rc=$R"; PS=
}
ps_lines "1 0 /sbin/launchd" "100 1 /opt/node /a/bin/cli.js serve --foreground --port 3000 --host 0.0.0.0"
runs_case "runs: --port 3000 -> läuft" /a/bin/cli.js 0
runs_case "runs: anderer cli-Pfad -> nein" /b/bin/cli.js 1
ps_lines "100 1 /opt/node /a/bin/cli.js serve --port=3000"
runs_case "runs: --port=3000 -> läuft" /a/bin/cli.js 0
ps_lines "100 1 /opt/node /a/bin/cli.js serve --port 3299"
runs_case "runs: anderer Port -> nein" /a/bin/cli.js 1
PS=false; runs_case "runs: ps-Fehler -> nein" /a/bin/cli.js 1

# === Warteschleife mit gemockter Uhr und Zahlenprüfung ===========================
# Uhr: Zeile n von $MOCK/clock beim n-ten Aufruf (auch leer), nach dem Ende die
# letzte Zeile; "FAIL" = Exitcode 3 ohne Ausgabe
cat > "$MOCK/clock" <<'EOF'
#!/bin/sh
n=$(( $(cat "$MOCK/clock.n" 2>/dev/null || echo 0) + 1 )); echo $n > "$MOCK/clock.n"
total=$(wc -l < "$MOCK/clock.seq" | tr -d ' ')
[ "$n" -le "$total" ] || n=$total
v=$(sed -n "${n}p" "$MOCK/clock.seq")
[ "$v" != FAIL ] || exit 3
echo "$v"
EOF
chmod +x "$MOCK/clock"
clock_seq() { rm -f "$MOCK/clock.n"; printf '%s\n' "$@" > "$MOCK/clock.seq"; }
lib_run() { # <Setup (eval)> <Befehl (eval)>; Ausgabe und rc
  ( ACTIVITY_DB="$DBF" ACTIVITY_NOW_MS=$NOW ACTIVITY_TAG="[t]" ACTIVITY_PS_CMD="cat $MOCK/ps" \
      ACTIVITY_CURL="$MOCK/curl" ACTIVITY_ENV_CMD="$MOCK/env"
    export ACTIVITY_DB ACTIVITY_NOW_MS ACTIVITY_TAG ACTIVITY_PS_CMD ACTIVITY_CURL ACTIVITY_ENV_CMD
    eval "$1"; . "$LIB"; eval "$2" ) 2>&1
}
lib_case() { # <name> <rc> <muss enthalten> <Setup> <Befehl>
  OUT=$(lib_run "$4" "$5"); RC=$?
  ok=1; [ "$RC" = "$2" ] || ok=0; printf '%s\n' "$OUT" | grep -qF -- "$3" || ok=0
  result "$1" $ok "rc=$RC (erwartet $2), Muster '$3'
$OUT"
}
WAIT_ENV='export ACTIVITY_IGNORE_SESSION=me ACTIVITY_LIVE_CMD=true ACTIVITY_SETTLE_SECONDS=0 ACTIVITY_WAIT_TIMEOUT=10 ACTIVITY_WAIT_INTERVAL=1 ACTIVITY_DATE_CMD=$MOCK/clock'
# Uhr-Aufrufe: Start, Schleifenanfang, vor dem Nachlauf, Erfolgsprüfung
quiet; ign_db; clock_seq 100 100 100 110
lib_case "Warten: Erfolgsprüfung genau an der Deadline -> Zeitüberschreitung" 1 "Zeitüberschreitung nach 10 s" "$WAIT_ENV" activity_wait_ignored
quiet; ign_db; clock_seq 100 100 100 109
lib_case "Warten: Erfolgsprüfung 1 s vor der Deadline -> Erfolg" 0 "auch nach 0 s nicht live" "$WAIT_ENV" activity_wait_ignored
quiet; ign_db; clock_seq 100 110
lib_case "Warten: Schleifenanfang genau an der Deadline -> Zeitüberschreitung" 1 "Zeitüberschreitung" "$WAIT_ENV" activity_wait_ignored
quiet; ign_db; clock_seq 100 100 105
lib_case "Warten: Nachlauf passt nicht ins Restbudget -> sofort Zeitüberschreitung" 1 "passt nicht mehr ins Restbudget (5 s)" "$WAIT_ENV; export ACTIVITY_SETTLE_SECONDS=6" activity_wait_ignored
quiet; ign_db; clock_seq 100
lib_case "Warten: Intervall 0 -> ungültig" 1 "ACTIVITY_WAIT_INTERVAL ungültig: '0' (mindestens 1)" "$WAIT_ENV; export ACTIVITY_WAIT_INTERVAL=0" activity_wait_ignored
lib_case "Warten: Timeout negativ -> ungültig" 1 "ACTIVITY_WAIT_TIMEOUT ungültig: '-5'" "$WAIT_ENV; export ACTIVITY_WAIT_TIMEOUT=-5" activity_wait_ignored
lib_case "Warten: Nachlauf keine Zahl -> ungültig" 1 "ACTIVITY_SETTLE_SECONDS ungültig: '2m'" "$WAIT_ENV; export ACTIVITY_SETTLE_SECONDS=2m" activity_wait_ignored
lib_case "Warten: Uhr kaputt -> Fehler" 1 "Uhr nicht lesbar" "$WAIT_ENV; export ACTIVITY_DATE_CMD=false" activity_wait_ignored
# Jeder Uhrwert wird geprüft: gültig, dann Text/leer/Fehlercode -> kein Erfolg
quiet; ign_db; clock_seq 100 100 100 abc
lib_case "Uhr: Text an der Erfolgsprüfung -> kein Erfolg" 1 "Uhr nicht lesbar: 'abc'" "$WAIT_ENV" activity_wait_ignored
quiet; ign_db; clock_seq 100 100 100 ''
lib_case "Uhr: leer an der Erfolgsprüfung -> kein Erfolg" 1 "Uhr nicht lesbar: ''" "$WAIT_ENV" activity_wait_ignored
quiet; ign_db; clock_seq 100 100 100 FAIL
lib_case "Uhr: Fehlercode an der Erfolgsprüfung -> kein Erfolg" 1 "Uhr nicht lesbar: 'Fehlercode 3'" "$WAIT_ENV" activity_wait_ignored
quiet; ign_db; clock_seq 100 100 100 -5
lib_case "Uhr: negativ an der Erfolgsprüfung -> kein Erfolg" 1 "Zeitüberschreitung (Uhr)" "$WAIT_ENV" activity_wait_ignored
quiet; ign_db; clock_seq 100 abc
lib_case "Uhr: Text am Schleifenanfang -> Zeitüberschreitung" 1 "Zeitüberschreitung (Uhr)" "$WAIT_ENV" activity_wait_ignored
quiet; ign_db; clock_seq 100 100 FAIL
lib_case "Uhr: Fehlercode vor dem Nachlauf -> Zeitüberschreitung" 1 "Zeitüberschreitung (Uhr)" "$WAIT_ENV" activity_wait_ignored
quiet; ign_db; clock_seq 100 100 '1e9'
lib_case "Uhr: Text vor dem Intervall-Schlaf -> Zeitüberschreitung" 1 "Uhr nicht lesbar: '1e9'" "$WAIT_ENV; export ACTIVITY_LIVE_CMD='echo me'" activity_wait_ignored
quiet; ign_db; clock_seq FAIL
lib_case "Uhr: Fehlercode beim Start -> Fehler" 1 "Uhr nicht lesbar" "$WAIT_ENV" activity_wait_ignored

# Obergrenzen gegen 64-Bit-Überlauf
quiet; ign_db; clock_seq 100
lib_case "Warten: Timeout > 86400 -> ungültig" 1 "ACTIVITY_WAIT_TIMEOUT ungültig: '86401' (höchstens 86400)" "$WAIT_ENV; export ACTIVITY_WAIT_TIMEOUT=86401" activity_wait_ignored
lib_case "Warten: Intervall > 3600 -> ungültig" 1 "(höchstens 3600)" "$WAIT_ENV; export ACTIVITY_WAIT_INTERVAL=3601" activity_wait_ignored
quiet; new_db
lib_case "Check: ALLOW_STALE_HOURS=3000000000000 -> blockiert" 1 "BLOCK  ALLOW_STALE_HOURS ungültig: '3000000000000' (höchstens 8760)" "export ACTIVITY_LIVE_CMD=false ALLOW_STALE_HOURS=3000000000000" activity_check
lib_case "Check: ALLOW_STALE_HOURS=8760 -> Override greift" 0 "ALLOW_STALE_HOURS=8760" "export ACTIVITY_LIVE_CMD=false ALLOW_STALE_HOURS=8760" activity_check
lib_case "Check: ACTIVITY_RECENT_SECONDS > 86400 -> blockiert" 1 "(höchstens 86400)" "export ACTIVITY_RECENT_SECONDS=999999999999999" activity_check
lib_case "Check: ACTIVITY_NOW_MS zu groß -> blockiert" 1 "ACTIVITY_NOW_MS ungültig: '99999999999999' (höchstens 9999999999999)" "export ACTIVITY_NOW_MS=99999999999999" activity_check
lib_case "Check: OPENCHAMBER_PORT 0 -> blockiert" 1 "OPENCHAMBER_PORT ungültig: '0' (mindestens 1)" "export OPENCHAMBER_PORT=0" activity_check
lib_case "Check: OPENCHAMBER_PORT 70000 -> blockiert" 1 "(höchstens 65535)" "export OPENCHAMBER_PORT=70000" activity_check

quiet; new_db
lib_case "Check: ACTIVITY_RECENT_SECONDS keine Zahl -> blockiert" 1 "BLOCK  ACTIVITY_RECENT_SECONDS ungültig: 'abc'" "export ACTIVITY_RECENT_SECONDS=abc" activity_check
lib_case "Check: ACTIVITY_RECENT_SECONDS führende Null -> blockiert" 1 "ACTIVITY_RECENT_SECONDS ungültig: '08'" "export ACTIVITY_RECENT_SECONDS=08" activity_check
lib_case "Check: ALLOW_STALE_HOURS negativ -> blockiert" 1 "BLOCK  ALLOW_STALE_HOURS ungültig: '-1'" "export ACTIVITY_LIVE_CMD=false ALLOW_STALE_HOURS=-1" activity_check
lib_case "Check: ALLOW_STALE_HOURS gültig -> Override greift" 0 "ALLOW_STALE_HOURS=6" "export ACTIVITY_LIVE_CMD=false ALLOW_STALE_HOURS=6" activity_check
lib_case "Check: ACTIVITY_NOW_MS keine Zahl -> blockiert" 1 "ACTIVITY_NOW_MS ungültig" "export ACTIVITY_NOW_MS=1e12" activity_check
lib_case "Check: OPENCHAMBER_PORT keine Zahl -> blockiert" 1 "OPENCHAMBER_PORT ungültig" "export OPENCHAMBER_PORT=x3000" activity_check

# === DB-Fehler ===================================================================
quiet; DBF="$TMP/fehlt/keine.sqlite"
check "DB fehlt -> blockiert" 1 "BLOCK  DB nicht lesbar"
quiet; new_db; session s1 "x"; msg s1 1 idle $((NOW - H))
# Sperre halten, bis der Test sie freigibt; erst prüfen, wenn sie nachweislich greift
( printf 'begin exclusive;\n'; i=0; while [ ! -f "$MOCK/unlock" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  printf 'commit;\n' ) | sqlite3 "$DBF" &
i=0; while sqlite3 -readonly "$DBF" "select 1" >/dev/null 2>&1 && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
check "DB gesperrt -> blockiert" 1 "database is locked"
: > "$MOCK/unlock"; wait; rm -f "$MOCK/unlock"

# === Umschaltskripte: Phase 1, --check, Nachweis, zweite Prüfung =================
# Alles gemockt: Startskript, Release-Worktree und npm-cli in $TMP, launchctl/curl
# als Skripte, Live-Status über einen Zähler-Mock, Phase 2 synchron (SWITCH_SYNC=1).
REL="$TMP/release"
mkdir -p "$REL/packages/web/bin" "$REL/packages/web/dist" "$REL/node_modules" "$TMP/npm/bin" "$TMP/tmpdir"
git -C "$REL" init -q && git -C "$REL" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
: > "$REL/packages/web/bin/cli.js"; : > "$REL/packages/web/dist/index.html"; : > "$TMP/npm/bin/cli.js"
RELHEAD=$(git -C "$REL" rev-parse HEAD)
FORKCLI="$REL/packages/web/bin/cli.js"
NPMCLI="$TMP/npm/bin/cli.js"

# Live-Status pro Aufruf: $MOCK/live.<n> (fehlt: live.default), Zähler in live.n
cat > "$MOCK/live" <<'EOF'
#!/bin/sh
n=$(( $(cat "$MOCK/live.n" 2>/dev/null || echo 0) + 1 )); echo $n > "$MOCK/live.n"
# live.fail.<n>: Live-Status nicht abrufbar
if [ -f "$MOCK/live.fail.$n" ]; then echo "Mock: Abfrage $n fehlgeschlagen"; exit 1; fi
# live.wait.<n>: Handshake; Phase 2 (oberster Vorfahr mit " --restart ") merken
# und warten, bis der Test $MOCK/go anlegt (höchstens 30 s)
if [ -f "$MOCK/live.wait.$n" ]; then
  p=$PPID; top=
  while [ "${p:-1}" -gt 1 ]; do
    case "$(ps -o args= -p "$p")" in *" --restart "*) top=$p ;; esac
    p=$(ps -o ppid= -p "$p" | tr -d ' ')
  done
  [ -z "$top" ] || echo "$top" > "$MOCK/phase2.pid"
  i=0; while [ ! -f "$MOCK/go" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
fi
if [ -f "$MOCK/live.$n" ]; then cat "$MOCK/live.$n"; else cat "$MOCK/live.default"; fi
EOF
chmod +x "$MOCK/live"
live_seq() { rm -f "$MOCK"/live.[0-9]* "$MOCK"/live.fail.* "$MOCK"/live.wait.* "$MOCK/live.n" "$MOCK/go"; printf '%s' "$1" | tr ' ' '\n' > "$MOCK/live.default"; shift
  k=1; for v in "$@"; do printf '%s' "$v" | tr ' ' '\n' > "$MOCK/live.$k"; k=$((k + 1)); done; }

script_env() {
  env SWITCH_RELEASE="$REL" EXPECTED_COMMIT="$RELHEAD" SWITCH_NPM_CLI="$NPMCLI" SWITCH_START="$TMP/start/OpenChamber" \
    SWITCH_ERRLOG="$TMP/err.log" SWITCH_LAUNCHCTL="$MOCK/launchctl" SWITCH_CURL="$MOCK/health" \
    SWITCH_SYNC=1 LOG="$TMP/phase2.log" TMPDIR="$TMP/tmpdir" \
    ACTIVITY_DB="$DBF" ACTIVITY_NOW_MS=$NOW ACTIVITY_PS_CMD="cat $MOCK/ps" ACTIVITY_LIVE_CMD="$MOCK/live" \
    ACTIVITY_RECENT_SECONDS=1 ACTIVITY_WAIT_INTERVAL=1 "$@"
}
# Startskript zeigt auf <cli>; keine Sicherung, kein Log, kein launchctl-Aufruf
reset_start() {
  rm -rf "$TMP/start" "$MOCK/launchctl.log" "$TMP/phase2.log" "$TMP/tmpdir"/*; mkdir -p "$TMP/start"
  printf '#!/bin/sh\nexec /opt/node %s serve --port 3000\n' "$1" > "$TMP/start/OpenChamber"
  cp "$TMP/start/OpenChamber" "$TMP/start.orig"
}
called() { [ -s "$MOCK/launchctl.log" ] && echo 1 || echo 0; }
unchanged() { cmp -s "$TMP/start/OpenChamber" "$TMP/start.orig" && echo 1 || echo 0; }
noproof() { [ -z "$(ls -A "$TMP/tmpdir")" ] && echo 1 || echo 0; }
noTmp() { [ -z "$(ls "$TMP/start" | grep '\.tmp\.')" ] && echo 1 || echo 0; }
# DB: s2 hat einen offenen Zug (assistant zuletzt); live entscheidet
db_s2() { new_db; session s2 "Läuft"; msg s2 1 assistant $((NOW - 300000)); }
ps_idle() { ps_lines "1 0 /sbin/launchd" "100 1 /opt/node /old/bin/cli.js serve --port 3000"; }
both() { [ "$1" = 1 ] && [ "$2" = 1 ] && echo 1 || echo 0; }
all() { for x in "$@"; do [ "$x" = 1 ] || { echo 0; return; }; done; echo 1; }
has() { printf '%s' "$OUT" | grep -qF -- "$1" && echo 1 || echo 0; }
loghas() { grep -qF -- "$1" "$TMP/phase2.log" 2>/dev/null && echo 1 || echo 0; }

for S in switch-to-fork.sh switch-to-npm.sh; do
  SP="$HERE/../$S"
  if [ "$S" = switch-to-fork.sh ]; then FROM=$NPMCLI; TO=$FORKCLI; else FROM=$FORKCLI; TO=$NPMCLI; fi

  # --check / CHECK_ONLY vor allem anderen, auch zusammen mit --restart
  db_s2; ps_idle; live_seq ''; reset_start "$FROM"
  OUT=$(script_env CHECK_ONLY=1 sh "$SP" --restart 0 2>&1); RC=$?
  result "$S: CHECK_ONLY=1 … --restart -> nur Prüfung" "$(all "$([ $RC = 0 ] && echo 1)" "$(called | tr 1 2 | tr 0 1)" "$(unchanged)" "$(has 'Ergebnis: ruhig')")" "rc=$RC
$OUT"
  reset_start "$FROM"
  OUT=$(script_env sh "$SP" --restart 0 --check 2>&1); RC=$?
  result "$S: --restart --check -> nur Prüfung" "$(all "$([ $RC = 0 ] && echo 1)" "$(called | tr 1 2 | tr 0 1)" "$(unchanged)")" "rc=$RC
$OUT"

  # --restart ohne echten Nachweis aus Phase 1
  reset_start "$FROM"
  OUT=$(script_env sh "$SP" --restart 0 2>&1); RC=$?
  result "$S: --restart ohne Nachweis -> abgewiesen" "$(all "$([ $RC = 1 ] && echo 1)" "$(called | tr 1 2 | tr 0 1)" "$(unchanged)" "$(has 'interne Phase')")" "rc=$RC
$OUT"
  OUT=$(script_env SWITCH_PROOF_DIR="$TMP/tmpdir/openchamber-switch.fake" SWITCH_PROOF_TOKEN=abc sh "$SP" --restart 0 2>&1); RC=$?
  result "$S: --restart, selbst gesetzte Variablen ohne Datei -> abgewiesen" "$(all "$([ $RC = 1 ] && echo 1)" "$(called | tr 1 2 | tr 0 1)" "$(has 'Nachweis fehlt')")" "rc=$RC
$OUT"
  mkdir -p "$TMP/forged"; chmod 700 "$TMP/forged"; echo abc > "$TMP/forged/token"
  OUT=$(script_env SWITCH_PROOF_DIR="$TMP/forged" SWITCH_PROOF_TOKEN=abc sh "$SP" --restart 0 2>&1); RC=$?
  result "$S: --restart, Nachweis am falschen Ort -> abgewiesen" "$(all "$([ $RC = 1 ] && echo 1)" "$(called | tr 1 2 | tr 0 1)" "$(has 'falschen Ort')")" "rc=$RC
$OUT"
  F="$TMP/tmpdir/openchamber-switch.open"; mkdir -p "$F"; chmod 755 "$F"; echo abc > "$F/token"
  OUT=$(script_env SWITCH_PROOF_DIR="$F" SWITCH_PROOF_TOKEN=abc sh "$SP" --restart 0 2>&1); RC=$?
  result "$S: --restart, Nachweis-Verzeichnis nicht 0700 -> abgewiesen" "$(all "$([ $RC = 1 ] && echo 1)" "$(called | tr 1 2 | tr 0 1)" "$(has 'nicht 0700')")" "rc=$RC
$OUT"
  rm -rf "$F"; F="$TMP/tmpdir/openchamber-switch.wrong"; mkdir -p "$F"; chmod 700 "$F"; echo abc > "$F/token"
  OUT=$(script_env SWITCH_PROOF_DIR="$F" SWITCH_PROOF_TOKEN=xyz sh "$SP" --restart 0 2>&1); RC=$?
  result "$S: --restart, falsches Token -> abgewiesen, Nachweis verbraucht" "$(all "$([ $RC = 1 ] && echo 1)" "$(called | tr 1 2 | tr 0 1)" "$(has 'passt nicht')" "$([ ! -d "$F" ] && echo 1)")" "rc=$RC
$OUT"

  # --check ist schreibfrei: eine Datei mit dem TMP-Namen ($START.tmp.<pid>) bleibt erhalten
  db_s2; ps_idle; live_seq ''; reset_start "$FROM"
  OUT=$(script_env sh -c 'touch "$1.tmp.$$"; exec sh "$2" --check' _ "$TMP/start/OpenChamber" "$SP" 2>&1); RC=$?
  result "$S: --check lässt Datei mit TMP-Namen stehen" "$(all "$([ $RC = 0 ] && echo 1)" "$(noTmp | tr 1 2 | tr 0 1)")" "rc=$RC
$(ls "$TMP/start")
$OUT"

  # Fremde Verzeichnisse openchamber-switch.* bleiben unangetastet
  F="$TMP/elsewhere/openchamber-switch.abc"; mkdir -p "$F"; chmod 700 "$F"; echo abc > "$F/token"; echo x > "$F/other"
  OUT=$(script_env SWITCH_PROOF_DIR="$F" SWITCH_PROOF_TOKEN=abc sh "$SP" --restart 0 2>&1); RC=$?
  result "$S: fremdes 0700-Verzeichnis an anderem Ort -> abgewiesen, unangetastet" "$(all "$([ $RC = 1 ] && echo 1)" "$(has 'falschen Ort')" "$([ -f "$F/token" ] && [ -f "$F/other" ] && echo 1)" "$(called | tr 1 2 | tr 0 1)")" "rc=$RC
$OUT"
  F="$TMP/tmpdir/openchamber-switch.full"; mkdir -p "$F"; chmod 700 "$F"; echo abc > "$F/token"; echo x > "$F/other"
  OUT=$(script_env SWITCH_PROOF_DIR="$F" SWITCH_PROOF_TOKEN=abc sh "$SP" --restart 0 2>&1); RC=$?
  result "$S: Nachweis-Verzeichnis mit fremder Datei -> abgewiesen, unangetastet" "$(all "$([ $RC = 1 ] && echo 1)" "$(has 'nicht leer')" "$([ -f "$F/token" ] && [ -f "$F/other" ] && echo 1)")" "rc=$RC
$OUT"
  rm -rf "$F" "$TMP/elsewhere"

  # Echter Nachweis gilt genau einmal; Wiederholung mit denselben Werten scheitert
  db_s2; ps_idle; live_seq ''; reset_start "$FROM"
  PRF=$(TMPDIR="$TMP/tmpdir"; die() { exit 1; }; . "$HERE/../lib/phase.sh"; phase_proof_create; echo "$PROOF_DIR $PROOF_TOKEN")
  OUT=$(script_env SWITCH_PROOF_DIR="${PRF% *}" SWITCH_PROOF_TOKEN="${PRF#* }" sh "$SP" --restart 0 2>&1); RC=$?
  result "$S: --restart mit echtem Nachweis -> Neustart, Nachweis gelöscht" "$(all "$([ $RC = 0 ] && echo 1)" "$(called)" "$(noproof)")" "rc=$RC
$OUT"
  reset_start "$FROM"
  OUT=$(script_env SWITCH_PROOF_DIR="${PRF% *}" SWITCH_PROOF_TOKEN="${PRF#* }" sh "$SP" --restart 0 2>&1); RC=$?
  result "$S: --restart, Nachweis wiederverwendet -> abgewiesen" "$(all "$([ $RC = 1 ] && echo 1)" "$(called | tr 1 2 | tr 0 1)" "$(has 'interne Phase')")" "rc=$RC
$OUT"

  # Phase 1: Aktivität blockt vor Sicherung und Umschreiben
  db_s2; ps_idle; live_seq 's2'; reset_start "$FROM"
  OUT=$(script_env sh "$SP" 2>&1); RC=$?
  result "$S: Phase 1 aktiv -> Abbruch, nichts geändert" "$(all "$([ $RC = 1 ] && echo 1)" "$(called | tr 1 2 | tr 0 1)" "$(unchanged)" "$([ ! -f "$TMP/start/OpenChamber.npm-2.2.0.bak" ] && echo 1)" "$(noproof)" "$(has 'BLOCK  Session s2')")" "rc=$RC
$OUT"

  # Ziel läuft schon: Exit 0 ohne Prüfung, auch wenn etwas aktiv ist
  db_s2; live_seq 's2'; reset_start "$TO"; ps_lines "1 0 /sbin/launchd" "100 1 /opt/node $TO serve --foreground --port 3000"
  OUT=$(script_env sh "$SP" 2>&1); RC=$?
  result "$S: Ziel läuft schon -> Exit 0 ohne Prüfung" "$(all "$([ $RC = 0 ] && echo 1)" "$(called | tr 1 2 | tr 0 1)" "$(has 'läuft bereits')" "$(has 'Ergebnis' | tr 1 2 | tr 0 1)")" "rc=$RC
$OUT"
  ps_lines "1 0 /sbin/launchd" "100 1 /opt/node $TO serve --port 3299"
  OUT=$(script_env sh "$SP" 2>&1); RC=$?
  result "$S: Ziel nur auf anderem Port -> prüft (aktiv)" "$(all "$([ $RC = 1 ] && echo 1)" "$(has 'BLOCK  Session s2')")" "rc=$RC
$OUT"

  # Integration: Phase 1 ruhig -> Phase 2 ruhig -> Umschreiben + Neustart
  db_s2; ps_idle; live_seq ''; reset_start "$FROM"
  OUT=$(script_env sh "$SP" 2>&1); RC=$?
  result "$S: Integration ruhig -> Neustart" "$(all "$([ $RC = 0 ] && echo 1)" "$(called)" "$(unchanged | tr 1 2 | tr 0 1)" "$(grep -qF "$TO" "$TMP/start/OpenChamber" && echo 1)" "$(loghas 'Zweite Aktivitätsprüfung')" "$(loghas '--- Ende')" "$(noproof)" "$(noTmp)")" "rc=$RC
$OUT
$(cat "$TMP/phase2.log" 2>/dev/null)"

  # Vorab exportierte _PROOF_DIR/_PROOF_TOKEN erreichen keinen Kindprozess
  db_s2; ps_idle; live_seq ''; reset_start "$FROM"; rm -f "$MOCK/launchctl.env"
  OUT=$(script_env _PROOF_DIR=/tmp/vorab _PROOF_TOKEN=vorab sh "$SP" 2>&1); RC=$?
  result "$S: vorab exportierte _PROOF_* bei launchctl nicht sichtbar" "$(all "$([ $RC = 0 ] && echo 1)" "$(called)" "$([ -f "$MOCK/launchctl.env" ] && [ ! -s "$MOCK/launchctl.env" ] && echo 1)")" "rc=$RC
$(sed 's/=.*/=<…>/' "$MOCK/launchctl.env" 2>/dev/null)"

  # Wechsel ruhig -> aktiv zwischen beiden Prüfungen: kein Neustart
  db_s2; ps_idle; live_seq 's2' ''; reset_start "$FROM"
  OUT=$(script_env sh "$SP" 2>&1); RC=$?
  result "$S: ruhig -> aktiv vor Neustart -> kein Neustart, Exit 1" "$(all "$([ $RC = 1 ] && echo 1)" "$(called | tr 1 2 | tr 0 1)" "$(unchanged)" "$(loghas 'zweiten Prüfung: kein Neustart')" "$(noproof)")" "rc=$RC
$OUT
$(cat "$TMP/phase2.log" 2>/dev/null)"

  # FORCE=1: zweite Prüfung aktiv -> trotzdem Neustart, Aktivität gelistet
  db_s2; ps_idle; live_seq 's2' ''; reset_start "$FROM"
  OUT=$(script_env FORCE=1 sh "$SP" 2>&1); RC=$?
  result "$S: FORCE=1, aktiv in Phase 2 -> Neustart, gelistet" "$(all "$([ $RC = 0 ] && echo 1)" "$(called)" "$(loghas 'BLOCK  Session s2')")" "rc=$RC
$(cat "$TMP/phase2.log" 2>/dev/null)"

  # Aufrufer-Ausnahme: Phase 1 ruhig trotz eigener Session, Phase 2 wartet, dann Neustart
  ign_db; ps_idle; live_seq '' 'root mid me' 'root mid me' 'mid'; reset_start "$FROM"
  OUT=$(script_env ACTIVITY_IGNORE_SESSION=me sh "$SP" 2>&1); RC=$?
  result "$S: Ignore + Warten -> Neustart nach Ende des Aufrufers" "$(all "$([ $RC = 0 ] && echo 1)" "$(has 'ignoriert (Aufrufer)')" "$(called)" "$(loghas 'läuft noch: root mid me')" "$(loghas 'Aufrufer-Sessions laufen nicht mehr')")" "rc=$RC
$OUT
$(cat "$TMP/phase2.log" 2>/dev/null)"

  # Aufrufer wacht nach dem Nachlauf wieder auf (Lead nach Subagent): weiter warten, dann Neustart
  ign_db; ps_idle; live_seq '' 'me' '' 'root' 'root' '' ''; reset_start "$FROM"
  OUT=$(script_env ACTIVITY_IGNORE_SESSION=me sh "$SP" 2>&1); RC=$?
  result "$S: Aufrufer wieder live nach Nachlauf -> weiter warten, dann Neustart" "$(all "$([ $RC = 0 ] && echo 1)" "$(loghas 'wieder live: root')" "$(loghas 'auch nach 1 s nicht live')" "$(called)")" "rc=$RC
$(cat "$TMP/phase2.log" 2>/dev/null)"
  ign_db; ps_idle; live_seq 'root' 'me' ''; reset_start "$FROM"
  OUT=$(script_env ACTIVITY_IGNORE_SESSION=me ACTIVITY_WAIT_TIMEOUT=3 sh "$SP" 2>&1); RC=$?
  result "$S: Aufrufer bleibt nach Nachlauf live -> Gesamt-Timeout, kein Neustart" "$(all "$([ $RC = 1 ] && echo 1)" "$(loghas 'wieder live')" "$(loghas 'Zeitüberschreitung')" "$(called | tr 1 2 | tr 0 1)")" "rc=$RC
$(cat "$TMP/phase2.log" 2>/dev/null)"

  # Gesamtbudget inkl. Nachlauf: Timeout 1 s, Nachlauf 120 s -> kein Neustart, Laufzeit ≈ Timeout
  ign_db; ps_idle; live_seq '' 'me'; reset_start "$FROM"
  T0=$(date +%s)
  OUT=$(script_env ACTIVITY_IGNORE_SESSION=me ACTIVITY_WAIT_TIMEOUT=1 ACTIVITY_SETTLE_SECONDS=120 sh "$SP" 2>&1); RC=$?
  T1=$(date +%s)
  result "$S: Timeout 1 s, Nachlauf 120 s -> kein Neustart, Laufzeit weit unter Nachlauf" "$(all "$([ $RC = 1 ] && echo 1)" "$([ $((T1 - T0)) -le 10 ] && echo 1)" "$(loghas 'passt nicht mehr ins Restbudget')" "$(loghas 'Zeitüberschreitung nach 1 s')" "$(called | tr 1 2 | tr 0 1)")" "rc=$RC dauer=$((T1 - T0))
$(cat "$TMP/phase2.log" 2>/dev/null)"

  # Live-Status nach dem Nachlauf nicht abrufbar: eigene Meldung, weiter warten, dann Neustart
  ign_db; ps_idle; live_seq '' 'me' '' 'x' '' ''; rm -f "$MOCK/live.3"; : > "$MOCK/live.fail.3"; reset_start "$FROM"
  OUT=$(script_env ACTIVITY_IGNORE_SESSION=me sh "$SP" 2>&1); RC=$?
  result "$S: Live nach Nachlauf nicht abrufbar -> eigene Meldung, weiter warten" "$(all "$([ $RC = 0 ] && echo 1)" "$(loghas 'Live-Status nicht abrufbar: Mock: Abfrage 3 fehlgeschlagen, warte weiter')" "$(loghas 'wieder live' | tr 1 2 | tr 0 1)" "$(called)")" "rc=$RC
$(cat "$TMP/phase2.log" 2>/dev/null)"

  # Aufrufer-Ausnahme mit Zeitüberschreitung: kein Neustart
  ign_db; ps_idle; live_seq 'me' ; reset_start "$FROM"
  OUT=$(script_env ACTIVITY_IGNORE_SESSION=me ACTIVITY_WAIT_TIMEOUT=2 sh "$SP" 2>&1); RC=$?
  result "$S: Ignore + Zeitüberschreitung -> kein Neustart, Exit 1" "$(all "$([ $RC = 1 ] && echo 1)" "$(called | tr 1 2 | tr 0 1)" "$(unchanged)" "$(loghas 'Zeitüberschreitung')" "$(loghas 'nicht rechtzeitig fertig')")" "rc=$RC
$(cat "$TMP/phase2.log" 2>/dev/null)"

  # Aufrufer-Ausnahme, aber nach dem Warten ist eine andere Session aktiv
  ign_db; ps_idle; live_seq 'other' 'me' 'me'; reset_start "$FROM"
  OUT=$(script_env ACTIVITY_IGNORE_SESSION=me sh "$SP" 2>&1); RC=$?
  result "$S: Ignore, danach andere Session aktiv -> kein Neustart, Exit 1" "$(all "$([ $RC = 1 ] && echo 1)" "$(called | tr 1 2 | tr 0 1)" "$(loghas 'BLOCK  Session other')")" "rc=$RC
$(cat "$TMP/phase2.log" 2>/dev/null)"
done

# Echter nohup-Pfad (ohne SWITCH_SYNC), mit Handshake: Phase 2 hängt in ihrer
# Live-Abfrage, bis der Test $MOCK/go anlegt. Das geschieht erst, nachdem Phase 1
# zurückgekehrt ist; bis dahin darf launchctl nicht aufgerufen worden sein.
for S in switch-to-fork.sh switch-to-npm.sh; do
  SP="$HERE/../$S"
  if [ "$S" = switch-to-fork.sh ]; then FROM=$NPMCLI; else FROM=$FORKCLI; fi
  stop_phase2; db_s2; ps_idle; live_seq ''; : > "$MOCK/live.wait.2"; reset_start "$FROM"; rm -f "$MOCK/launchctl.env"
  OUT=$(script_env SWITCH_SYNC=0 sh "$SP" 2>&1); RC=$?
  i=0; while [ ! -f "$MOCK/phase2.pid" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  P2=$(cat "$MOCK/phase2.pid" 2>/dev/null || true)
  ALIVE=$([ -n "$P2" ] && kill -0 "$P2" 2>/dev/null && echo 1 || echo 0)
  EARLY=$(called)
  : > "$MOCK/go"
  i=0; while [ $i -lt 300 ] && ! grep -qF -- '--- Ende' "$TMP/phase2.log" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  # Nur nach sauberem Ende vergessen; sonst beendet stop_phase2/cleanup sie
  ! grep -qF -- '--- Ende' "$TMP/phase2.log" 2>/dev/null || rm -f "$MOCK/phase2.pid"
  result "$S: nohup-Pfad: Phase 1 zurück, Phase 2 läuft abgekoppelt weiter" "$(all "$([ $RC = 0 ] && echo 1)" "$(has 'Neustart läuft abgekoppelt')" "$ALIVE" "$([ "$EARLY" = 0 ] && echo 1)" "$(called)" "$(loghas '--- Ende')")" "rc=$RC phase2=$P2 lebt=$ALIVE früh=$EARLY
$OUT
$(cat "$TMP/phase2.log" 2>/dev/null)"
  result "$S: nohup-Pfad: Nachweis verbraucht, keine Nachweis-Variablen bei launchctl" "$(all "$(noproof)" "$([ -f "$MOCK/launchctl.env" ] && [ ! -s "$MOCK/launchctl.env" ] && echo 1)")" "$(ls -A "$TMP/tmpdir"; cat "$MOCK/launchctl.env" 2>/dev/null | sed 's/=.*/=<…>/')"
done

# switch-to-npm.sh: Startskript fehlt -> sauberer Abbruch vor sed, keine Temp-Datei
db_s2; ps_idle; live_seq ''; reset_start "$FORKCLI"; rm -f "$TMP/start/OpenChamber"
OUT=$(script_env sh "$HERE/../switch-to-npm.sh" 2>&1); RC=$?
result "switch-to-npm.sh: Startskript fehlt -> Abbruch" "$(all "$([ $RC = 1 ] && echo 1)" "$(has 'fehlt, Startskript von Hand prüfen')" "$(called | tr 1 2 | tr 0 1)" "$(noTmp)")" "rc=$RC
$OUT"

echo "---"
if [ $FAIL = 0 ]; then echo "alle $N Tests grün"; exit 0; fi
echo "$FAIL von $N Tests fehlgeschlagen"; exit 1
