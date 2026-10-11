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
trap 'rm -rf "$TMP"' EXIT INT TERM
MOCK="$TMP/mock"
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
printf '#!/bin/sh\necho "$*" >> "$MOCK/launchctl.log"\n' > "$MOCK/launchctl"
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
      ACTIVITY_CURL="$MOCK/curl" ACTIVITY_ENV_CMD="$MOCK/env" ALLOW_STALE_HOURS="${ALLOW:-}"
    export ACTIVITY_DB ACTIVITY_NOW_MS ACTIVITY_TAG ACTIVITY_LIVE_CMD ACTIVITY_PS_CMD ACTIVITY_CURL ACTIVITY_ENV_CMD ALLOW_STALE_HOURS
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
  LIVE=; PS=; ALLOW=
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
  ( ACTIVITY_CURL="$MOCK/curl" ACTIVITY_ENV_CMD="$MOCK/env"; . "$LIB"; activity_live_default "$(cat "$MOCK/ps")" ) 2>&1
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

# === DB-Fehler ===================================================================
quiet; DBF="$TMP/fehlt/keine.sqlite"
check "DB fehlt -> blockiert" 1 "BLOCK  DB nicht lesbar"
quiet; new_db; session s1 "x"; msg s1 1 idle $((NOW - H))
( printf 'begin exclusive;\n'; sleep 3; printf 'commit;\n' ) | sqlite3 "$DBF" &
sleep 1
check "DB gesperrt -> blockiert" 1 "database is locked"
wait

# === Umschaltskripte: --check, --restart, zweite Prüfung =========================
# script_run <skript> <args…>; Umgebung: alles gemockt, Startskript in $TMP
script_env() {
  SWITCH_RELEASE="$TMP/release" SWITCH_NPM_CLI="$TMP/npm/bin/cli.js" SWITCH_START="$TMP/start/OpenChamber" \
    SWITCH_ERRLOG="$TMP/err.log" SWITCH_LAUNCHCTL="$MOCK/launchctl" SWITCH_CURL="$MOCK/health" \
    ACTIVITY_DB="$DBF" ACTIVITY_NOW_MS=$NOW ACTIVITY_PS_CMD="cat $MOCK/ps" \
    ACTIVITY_CURL="$MOCK/curl" ACTIVITY_ENV_CMD="$MOCK/env" "$@"
}
reset_start() {
  mkdir -p "$TMP/start" "$TMP/npm/bin"; rm -f "$MOCK/launchctl.log" "$TMP/start/"*
  printf '#!/bin/sh\nexec /opt/node %s serve --port 3000\n' "$TMP/npm/bin/cli.js" > "$TMP/start/OpenChamber"
  : > "$TMP/npm/bin/cli.js"
  cp "$TMP/start/OpenChamber" "$TMP/start.orig"
}
called() { [ -s "$MOCK/launchctl.log" ] && echo 1 || echo 0; }
unchanged() { cmp -s "$TMP/start/OpenChamber" "$TMP/start.orig" && echo 1 || echo 0; }
active() { quiet; new_db; session s2 "Läuft"; msg s2 1 assistant $((NOW - 300000)); api '{"data":{"s2":{"type":"running"}}}'; }

for S in switch-to-fork.sh switch-to-npm.sh; do
  SP="$HERE/../$S"
  # npm-Skript braucht als Ausgangslage ein Startskript, das auf den Fork zeigt
  start_for() { reset_start; if [ "$S" = switch-to-npm.sh ]; then
    printf '#!/bin/sh\nexec /opt/node %s serve --port 3000\n' "$TMP/release/packages/web/bin/cli.js" > "$TMP/start/OpenChamber"
    cp "$TMP/start/OpenChamber" "$TMP/start.orig"; fi; }

  quiet; new_db; start_for
  OUT=$(script_env env CHECK_ONLY=1 SWITCH_RESTART_TOKEN=tok sh "$SP" --restart 0 tok 2>&1); RC=$?
  result "$S: CHECK_ONLY=1 … --restart -> nur Prüfung" \
    "$([ $RC = 0 ] && [ "$(called)" = 0 ] && [ "$(unchanged)" = 1 ] && printf '%s' "$OUT" | grep -q 'Ergebnis: ruhig' && echo 1 || echo 0)" "rc=$RC
$OUT"
  quiet; new_db; start_for
  OUT=$(script_env sh "$SP" --restart 0 --check 2>&1); RC=$?
  result "$S: --restart --check -> nur Prüfung" \
    "$([ $RC = 0 ] && [ "$(called)" = 0 ] && [ "$(unchanged)" = 1 ] && echo 1 || echo 0)" "rc=$RC
$OUT"

  quiet; new_db; start_for
  OUT=$(script_env sh "$SP" --restart 0 2>&1); RC=$?
  result "$S: direktes --restart ohne Token -> abgewiesen" \
    "$([ $RC = 1 ] && [ "$(called)" = 0 ] && [ "$(unchanged)" = 1 ] && printf '%s' "$OUT" | grep -q 'interne Phase' && echo 1 || echo 0)" "rc=$RC
$OUT"
  OUT=$(script_env env SWITCH_RESTART_TOKEN=a sh "$SP" --restart 0 b 2>&1); RC=$?
  result "$S: --restart mit falschem Token -> abgewiesen" \
    "$([ $RC = 1 ] && [ "$(called)" = 0 ] && echo 1 || echo 0)" "rc=$RC
$OUT"

  active; start_for
  OUT=$(script_env env SWITCH_RESTART_TOKEN=tok sh "$SP" --restart 0 tok 2>&1); RC=$?
  result "$S: zweite Prüfung aktiv -> kein Neustart, Startskript unverändert" \
    "$([ $RC = 1 ] && [ "$(called)" = 0 ] && [ "$(unchanged)" = 1 ] && echo 1 || echo 0)" "rc=$RC
$OUT"

  quiet; new_db; start_for
  OUT=$(script_env env SWITCH_RESTART_TOKEN=tok sh "$SP" --restart 0 tok 2>&1); RC=$?
  result "$S: zweite Prüfung ruhig -> umgeschrieben und Neustart" \
    "$([ $RC = 0 ] && [ "$(called)" = 1 ] && [ "$(unchanged)" = 0 ] && grep -q 'kickstart -k' "$MOCK/launchctl.log" && echo 1 || echo 0)" "rc=$RC
$OUT"

  active; start_for
  OUT=$(script_env env FORCE=1 SWITCH_RESTART_TOKEN=tok sh "$SP" --restart 0 tok 2>&1); RC=$?
  result "$S: zweite Prüfung aktiv + FORCE=1 -> Neustart, Aktivität gelistet" \
    "$([ $RC = 0 ] && [ "$(called)" = 1 ] && printf '%s' "$OUT" | grep -q 'BLOCK  Session s2' && echo 1 || echo 0)" "rc=$RC
$OUT"
done

echo "---"
if [ $FAIL = 0 ]; then echo "alle $N Tests grün"; exit 0; fi
echo "$FAIL von $N Tests fehlgeschlagen"; exit 1
