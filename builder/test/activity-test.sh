#!/bin/sh
# Tests für builder/lib/activity.sh mit einer temporären SQLite-DB (Schema wie
# OpenCode session_v2/session_message), gemocktem Live-Status und Prozessliste.
#
#   sh builder/test/activity-test.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/activity-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

NOW=1800000000000          # festes "jetzt" in ms
H=3600000                  # eine Stunde in ms
OLD=$((NOW - 48 * H))      # session_v2.time_updated weit außerhalb der 2-Minuten-Regel
FAIL=0
N=0

new_db() {
  DBF="$TMP/db-$N.sqlite"
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

# check <name> <erwarteter Rückgabewert> <muss enthalten> [darf nicht enthalten]
check() {
  OUT=$(
    ACTIVITY_DB="$DBF" ACTIVITY_NOW_MS=$NOW STALE_HOURS=6 ACTIVITY_TAG="[t]" \
      ACTIVITY_LIVE_CMD="${LIVE:-false}" ACTIVITY_PS_CMD="${PS:-true}"
    export ACTIVITY_DB ACTIVITY_NOW_MS STALE_HOURS ACTIVITY_TAG ACTIVITY_LIVE_CMD ACTIVITY_PS_CMD
    . "$HERE/../lib/activity.sh"
    activity_check
  )
  RC=$?
  ok=1
  [ "$RC" = "$2" ] || ok=0
  printf '%s\n' "$OUT" | grep -qF -- "$3" || ok=0
  if [ -n "${4:-}" ] && printf '%s\n' "$OUT" | grep -qF -- "$4"; then ok=0; fi
  if [ $ok = 1 ]; then
    echo "ok   $1"
  else
    echo "FAIL $1 (rc=$RC, erwartet $2, Muster '$3')"
    printf '%s\n' "$OUT" | sed 's/^/     /'
    FAIL=$((FAIL + 1))
  fi
  N=$((N + 1)); LIVE=; PS=
}

# 1. idle zuletzt → nicht aktiv
new_db; session s1 "Fertig"; msg s1 1 user $((NOW - H)); msg s1 2 assistant $((NOW - H)); msg s1 3 idle $((NOW - H))
check "idle zuletzt -> ruhig" 0 "Ergebnis: ruhig" "BLOCK"

# 2. assistant zuletzt, jung → aktiv (ohne Live-Status über die Altersregel)
new_db; session s2 "Läuft"; msg s2 1 user $((NOW - 600000)); msg s2 2 assistant $((NOW - 300000))
check "assistant jung -> aktiv" 1 "BLOCK  Session s2"

# 3. idle, danach model-switched (und agent-switched) → nicht aktiv
new_db; session s3 "Recherche"; msg s3 1 assistant $((NOW - H)); msg s3 2 idle $((NOW - H))
msg s3 3 model-switched $((NOW - 60000)); msg s3 4 agent-switched $((NOW - 60000))
check "idle + switched danach -> ruhig" 0 "Ergebnis: ruhig" "s3"

# 4. Kind-Session aktiv, Parent idle → aktiv, Parent wird genannt
new_db; session p4 "Parent"; msg p4 1 idle $((NOW - H))
session c4 "Kind" p4; msg c4 1 user $((NOW - 120000)); msg c4 2 assistant $((NOW - 60000))
check "Kind-Session aktiv -> aktiv" 1 "BLOCK  Session c4  \"Kind\"  letzter=assistant"
new_db; session p4 "Parent"; msg p4 1 idle $((NOW - H))
session c4 "Kind" p4; msg c4 1 assistant $((NOW - 60000))
check "Kind-Session nennt Parent" 1 "parent=p4"

# 5. assistant zuletzt, älter als STALE_HOURS, kein Live-Status → ignoriert und gelistet
new_db; session s5 "Abgebrochen"; msg s5 1 assistant $((NOW - 7 * H))
check "alt ohne Live -> ignoriert" 0 "IGNORE Session s5" "BLOCK"
new_db; session s5 "Abgebrochen"; msg s5 1 assistant $((NOW - 7 * H))
check "alt ohne Live -> Altersregel gemeldet" 0 "nicht abfragbar, Altersregel"

# 6. Live-Status busy überschreibt das Alter
new_db; session s6 "Langer Build"; msg s6 1 assistant $((NOW - 7 * H))
LIVE="echo s6"; check "alt, live läuft -> aktiv" 1 "BLOCK  Session s6"

# 7. Live-Status abfragbar, Kandidat läuft nicht → abgebrochen, ignoriert (auch wenn jung)
new_db; session s7 "Abgebrochen jung"; msg s7 1 assistant $((NOW - 300000))
LIVE="echo other_session_not_in_db; true"; check "live: Kandidat nicht laufend -> ignoriert" 1 "IGNORE Session s7"
new_db; session s7 "Abgebrochen jung"; msg s7 1 assistant $((NOW - 300000))
LIVE="printf ''"; check "live leer, Kandidat jung -> ruhig" 0 "IGNORE Session s7" "BLOCK"

# 8. Live läuft, DB zeigt idle (z. B. Zug gerade gestartet) → trotzdem aktiv
new_db; session s8 "Gerade gestartet"; msg s8 1 idle $((NOW - H))
LIVE="echo s8"; check "live läuft, DB idle -> aktiv" 1 "BLOCK  Session s8 (live: läuft"

# 9. Prozesse: xcrun simctl / xcodebuild / xctest blockieren, CoreSimulator-Daemons nicht
new_db
PS="printf '%s\n' '101 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService' '102 /usr/libexec/simdiskimaged' '103 launchd_sim /x' '104 /usr/bin/xcrun xcode-select'"
check "nur Simulator-Daemons -> ruhig" 0 "Ergebnis: ruhig" "Prozess"
new_db; PS="printf '%s\n' '201 /usr/bin/xcrun simctl io booted screenshot /tmp/a.png'"
check "xcrun simctl -> aktiv" 1 "BLOCK  Prozess 201 /usr/bin/xcrun simctl"
new_db; PS="printf '%s\n' '202 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -scheme X'"
check "xcodebuild -> aktiv" 1 "BLOCK  Prozess 202"
new_db; PS="printf '%s\n' '203 /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest /tmp/X.xctest'"
check "xctest -> aktiv" 1 "BLOCK  Prozess 203"
new_db; PS="printf '%s\n' '  204 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl list devices booted -j'"
check "simctl list (serve-sim-Polling) -> ruhig" 0 "Ergebnis: ruhig" "Prozess"
new_db; PS="printf '%s\n' '  205 /usr/bin/xcrun simctl install booted /tmp/A.app'"
check "führende Leerzeichen der PID entfernt" 1 "BLOCK  Prozess 205 /usr/bin/xcrun"

# 10. 2-Minuten-Regel auf session_v2.time_updated bleibt
new_db; session s10 "Eben geändert" "" $((NOW - 30000)); msg s10 1 idle $((NOW - 30000))
check "time_updated < 2 min -> aktiv" 1 "BLOCK  Kürzlich s10"

# 11. DB nicht lesbar → gilt als aktiv
DBF="$TMP/fehlt/keine.sqlite"
check "DB fehlt -> aktiv" 1 "DB nicht lesbar"

# 12. Live-Status-Parser: Antwort von /api/session/active
. "$HERE/../lib/activity.sh"
J='{"data":{"ses_a":{"type":"running"},"ses_b":{"type":"retry"}}}'
GOT=$(sqlite3 :memory: "select key from json_each('$J', '\$.data')" | tr '\n' ' ')
if [ "$GOT" = "ses_a ses_b " ]; then echo "ok   json_each liest IDs"; else echo "FAIL json_each: '$GOT'"; FAIL=$((FAIL + 1)); fi
N=$((N + 1))

echo "---"
if [ $FAIL = 0 ]; then echo "alle $N Tests grün"; exit 0; fi
echo "$FAIL von $N Tests fehlgeschlagen"; exit 1
