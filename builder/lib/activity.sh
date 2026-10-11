# Aktivitätsprüfung vor einem Neustart von OpenChamber (und damit der
# verwalteten OpenCode-Instanz). POSIX sh, wird per `. lib/activity.sh` geladen.
#
#   activity_check          # listet Blockierendes, Rückgabe 0 = ruhig, 1 = aktiv
#
# Regel (Esref-Vorgabe 11.10.2026), drei Bedingungen, jede blockiert:
#  1. Sessions (inkl. Kind-Sessions) aus session_message, deren letzter Eintrag
#     nach seq kein `idle` ist. `*-switched`-Einträge (agent/model/location)
#     zählen nicht, sie werden oft nach dem idle angehängt.
#     - Live-Status abfragbar (GET /api/session/active der laufenden OpenCode-
#       Instanz): aktiv ist, was dort gelistet ist. DB-Kandidaten, die dort
#       fehlen, sind abgebrochene Züge (kein idle geschrieben) und werden nur
#       gelistet. Live laufende Sessions ohne DB-Kandidat blockieren auch.
#     - Live-Status nicht abfragbar: DB-Kandidaten mit letztem Eintrag jünger
#       als STALE_HOURS blockieren, ältere gelten als "vermutlich abgebrochen".
#  2. Laufende Prozesse aus ACTIVITY_PROCESS_PATTERNS (xcodebuild, simctl, …),
#     die minutenlang nichts in die DB schreiben.
#  3. Sessions, deren session_v2.time_updated jünger als ACTIVITY_RECENT_SECONDS ist.
#
# Überschreibbar (v. a. für Tests):
#   ACTIVITY_DB                Pfad zur OpenCode-DB (nur -readonly geöffnet)
#   STALE_HOURS                Default 6
#   ACTIVITY_RECENT_SECONDS    Default 120
#   ACTIVITY_NOW_MS            Jetzt in ms (Default: date)
#   ACTIVITY_LIVE_CMD          Befehl, der laufende Session-IDs zeilenweise ausgibt;
#                              Exit != 0 = Live-Status nicht abfragbar
#   ACTIVITY_LIVE=0            Live-Status gar nicht abfragen
#   ACTIVITY_PS_CMD            Default "ps -axo pid=,args="
#   ACTIVITY_PROCESS_PATTERNS  Basename des Programms, "prog:arg1" verlangt
#                              zusätzlich dieses erste Argument
#   ACTIVITY_PROCESS_IGNORE    awk-Regex auf die ganze Befehlszeile, Treffer zählen
#                              nicht (Default: "simctl list", das serve-sim alle
#                              paar Sekunden nur lesend aufruft)
#   ACTIVITY_TAG               Präfix der Ausgabezeilen

ACTIVITY_DB="${ACTIVITY_DB:-$HOME/.local/share/opencode/opencode.db}"
STALE_HOURS="${STALE_HOURS:-6}"
ACTIVITY_RECENT_SECONDS="${ACTIVITY_RECENT_SECONDS:-120}"
ACTIVITY_PS_CMD="${ACTIVITY_PS_CMD:-ps -axo pid=,args=}"
# Nicht die CoreSimulator-Daemons (CoreSimulatorService, simdiskimaged,
# launchd_sim, …): die laufen bei gebootetem Simulator immer.
ACTIVITY_PROCESS_PATTERNS="${ACTIVITY_PROCESS_PATTERNS:-xcodebuild xcrun:simctl simctl xctest}"
ACTIVITY_PROCESS_IGNORE="${ACTIVITY_PROCESS_IGNORE:-/simctl list( |$)}"
ACTIVITY_TAG="${ACTIVITY_TAG:-[activity]}"

activity_say() { echo "$ACTIVITY_TAG $*"; }

# Laufende Session-IDs der OpenCode-Instanzen (`opencode serve … --port N`).
# Das Passwort steht in der Prozessumgebung (OPENCODE_SERVER_PASSWORD, von
# OpenChamber gesetzt); es geht nur per stdin an curl und wird nie ausgegeben.
activity_live_default() {
  _pids=$(ps -axo pid=,args= | awk '{ n = split($2, a, "/"); if (a[n] == "opencode" && $3 == "serve") print $1 }')
  [ -n "$_pids" ] || return 1
  for _pid in $_pids; do
    _args=$(ps -o args= -p "$_pid") || return 1
    _port=$(echo "$_args" | awk '{ for (i = 1; i < NF; i++) if ($i == "--port") print $(i + 1) }')
    _host=$(echo "$_args" | awk '{ for (i = 1; i < NF; i++) if ($i == "--hostname") print $(i + 1) }')
    [ -n "$_port" ] || return 1
    _json=$(
      ps eww -o command= -p "$_pid" | tr ' ' '\n' | sed -n 's/^OPENCODE_SERVER_PASSWORD=//p' | head -n 1 |
        awk 'NF { printf "user = \"opencode:%s\"\n", $0 }' |
        curl -sf -m 3 -K - -H 'Accept: application/json' "http://${_host:-127.0.0.1}:$_port/api/session/active"
    ) || return 1
    _json=$(printf '%s' "$_json" | sed "s/'/''/g")
    # Ohne Objekt unter .data ist die Antwort unbrauchbar, nicht "nichts läuft".
    [ "$(sqlite3 :memory: "select json_type('$_json', '\$.data')" 2>/dev/null)" = object ] || return 1
    sqlite3 :memory: "select key from json_each('$_json', '\$.data')" || return 1
  done
}

activity_live() {
  [ "${ACTIVITY_LIVE:-1}" = 0 ] && return 1
  if [ -n "${ACTIVITY_LIVE_CMD:-}" ]; then
    eval "$ACTIVITY_LIVE_CMD"
  else
    activity_live_default
  fi
}

# Zeilen "pid args" der laufenden Build-/Simulator-Befehle
activity_processes() {
  eval "$ACTIVITY_PS_CMD" | sed 's/^ *//' | awk -v pats="$ACTIVITY_PROCESS_PATTERNS" -v ign="$ACTIVITY_PROCESS_IGNORE" '
    BEGIN { np = split(pats, p, " ") }
    ign != "" && $0 ~ ign { next }
    {
      n = split($2, a, "/"); prog = a[n]
      for (i = 1; i <= np; i++) {
        split(p[i], q, ":")
        if (prog == q[1] && (q[2] == "" || $3 == q[2])) { print substr($0, 1, 160); break }
      }
    }'
}

activity_check() {
  _now=${ACTIVITY_NOW_MS:-$(($(date +%s) * 1000))}
  _stale_ms=$((STALE_HOURS * 3600000))
  _recent_ms=$((ACTIVITY_RECENT_SECONDS * 1000))
  _tab=$(printf '\t')
  _blocked=0

  # 1. DB-Kandidaten: id, Titel, Typ, Zeit, Parent, Alter in ms
  _cand=$(sqlite3 -readonly -separator "$_tab" "$ACTIVITY_DB" "
    with last as (
      select session_id, type, time_updated,
             row_number() over (partition by session_id order by seq desc) as rn
      from session_message where type not like '%-switched')
    select s.id,
           substr(replace(replace(coalesce(s.title, ''), char(9), ' '), char(10), ' '), 1, 50),
           l.type,
           datetime(l.time_updated / 1000, 'unixepoch', 'localtime'),
           coalesce(s.parent_id, '-'),
           $_now - l.time_updated
    from last l join session_v2 s on s.id = l.session_id
    where l.rn = 1 and l.type != 'idle'
    order by l.time_updated desc") || {
    activity_say "DB nicht lesbar: $ACTIVITY_DB (gilt als aktiv)"
    return 1
  }

  if _live=$(activity_live); then
    activity_say "Live-Status: abgefragt ($(printf '%s\n' "$_live" | grep -c .) laufend)"
    _mode=live
  else
    activity_say "Live-Status: nicht abfragbar, Altersregel (STALE_HOURS=$STALE_HOURS)"
    _mode=age
    _live=
  fi

  _report=$(printf '%s\n' "$_cand" | awk -F "$_tab" -v mode="$_mode" -v stale="$_stale_ms" -v live="$(printf '%s' "$_live" | tr '\n' ' ')" '
    BEGIN { n = split(live, ids, " "); for (i = 1; i <= n; i++) if (ids[i] != "") running[ids[i]] = 1 }
    NF >= 6 {
      seen[$1] = 1
      line = sprintf("%s  \"%s\"  letzter=%s  %s  parent=%s", $1, $2, $3, $4, $5)
      if (mode == "live") {
        if ($1 in running) print "BLOCK  Session " line " (live: läuft)"
        else print "IGNORE Session " line " (live: nicht laufend, vermutlich abgebrochen)"
      } else {
        if ($6 < stale) print "BLOCK  Session " line
        else print "IGNORE Session " line " (älter als " stale / 3600000 " h, vermutlich abgebrochen)"
      }
    }
    END { for (id in running) if (!(id in seen)) print "BLOCK  Session " id " (live: läuft, DB-Eintrag idle oder unbekannt)" }')

  # 2. Prozesse
  _procs=$(activity_processes | sed 's/^/BLOCK  Prozess /')

  # 3. Sessions, die in den letzten ACTIVITY_RECENT_SECONDS geändert wurden
  _recent=$(sqlite3 -readonly -separator "$_tab" "$ACTIVITY_DB" "
    select id, substr(replace(replace(coalesce(title, ''), char(9), ' '), char(10), ' '), 1, 50),
           datetime(time_updated / 1000, 'unixepoch', 'localtime')
    from session_v2 where time_updated > $_now - $_recent_ms order by time_updated desc") || {
    activity_say "DB nicht lesbar: $ACTIVITY_DB (gilt als aktiv)"
    return 1
  }
  _recent=$(printf '%s\n' "$_recent" | awk -F "$_tab" -v s="$ACTIVITY_RECENT_SECONDS" \
    'NF >= 3 { printf "BLOCK  Kürzlich %s  \"%s\"  geändert %s (< %s s)\n", $1, $2, $3, s }')

  for _part in "$_report" "$_procs" "$_recent"; do
    [ -n "$_part" ] || continue
    printf '%s\n' "$_part" | while IFS= read -r _l; do activity_say "$_l"; done
    printf '%s\n' "$_part" | grep -q '^BLOCK' && _blocked=1
  done

  if [ "$_blocked" = 1 ]; then
    activity_say "Ergebnis: AKTIV (Neustart würde obige Züge/Prozesse abbrechen)"
    return 1
  fi
  activity_say "Ergebnis: ruhig"
  return 0
}
