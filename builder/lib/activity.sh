# Aktivitätsprüfung vor einem Neustart von OpenChamber (und damit der
# verwalteten OpenCode-Instanz). POSIX sh, wird per `. lib/activity.sh` geladen.
#
#   activity_check          # listet Blockierendes, Rückgabe 0 = ruhig, 1 = aktiv
#
# Fail-closed: Was nicht sicher als ruhig erkannt wird, blockiert. Jede Bedingung
# blockiert für sich (Details und Grenzen in builder/README.md):
#  1. Sessions (inkl. Kind- und archivierter Sessions) aus session_message, deren
#     letzter Eintrag nach seq kein `idle` ist; `*-switched`-Einträge zählen nicht.
#     Der Live-Status der von OpenChamber verwalteten OpenCode-Instanz
#     (GET /api/session/active) entscheidet: dort gelistet = aktiv, nicht
#     gelistet = vermutlich abgebrochen, ignoriert. Live laufende Sessions ohne
#     DB-Kandidat blockieren auch. Live-Status nicht verfügbar = blockiert
#     (außer ALLOW_STALE_HOURS=N: dann blockieren nur Kandidaten jünger als N h).
#  2. Laufende Prozesse aus ACTIVITY_PROCESS_PATTERNS (xcodebuild, simctl, …).
#     Prozessliste nicht lesbar = blockiert.
#  3. Sessions, deren session_v2.time_updated jünger als ACTIVITY_RECENT_SECONDS ist.
#  DB nicht lesbar (fehlt, gesperrt) = blockiert.
#
#   ACTIVITY_IGNORE_SESSION=<id>  nimmt diese Session und ihre Vorfahren (parent_id)
#   von Live- und 120-s-Regel aus (Aufrufer aus einer Agent-Session). Wer neu
#   startet, muss danach activity_wait_ignored und eine Prüfung ohne Ausnahme machen.
#
#   activity_wait_ignored   # wartet, bis die ausgenommenen Sessions nicht mehr live sind
#   activity_runs_cli <cli> # läuft "<cli> serve … --port $OPENCHAMBER_PORT"?
#
# Überschreibbar (v. a. für Tests):
#   ACTIVITY_DB                Pfad zur OpenCode-DB (nur -readonly geöffnet)
#   ALLOW_STALE_HOURS          Ausdrücklicher Override bei fehlendem Live-Status (leer = aus)
#   ACTIVITY_RECENT_SECONDS    Default 120
#   ACTIVITY_NOW_MS            Jetzt in ms (Default: date)
#   ACTIVITY_PS_CMD            Default "ps -axo pid=,ppid=,args=" (Spalten pid ppid args)
#   ACTIVITY_ENV_CMD           Gibt Befehlszeile samt Umgebung eines Prozesses aus,
#                              PID wird angehängt. Default "ps eww -o command= -p"
#   ACTIVITY_CURL              Default "curl"
#   ACTIVITY_LIVE_CMD          Ersetzt die Live-Abfrage ganz: gibt laufende Session-IDs
#                              zeilenweise aus, Exit != 0 = nicht verfügbar
#   OPENCHAMBER_PORT           Port des OpenChamber-Prozesses (`cli.js serve`), Default 3000
#   ACTIVITY_PROCESS_PATTERNS  Programmnamen; "prog:arg" verlangt zusätzlich ein
#                              späteres Argument arg (z. B. xcrun … simctl)
#   ACTIVITY_PROCESS_IGNORE    awk-Regex auf die Befehlszeile, Treffer zählen nicht
#                              (Default: "simctl list", das serve-sim nur lesend pollt)
#   ACTIVITY_WAIT_TIMEOUT      Sekunden für activity_wait_ignored, Default 900
#   ACTIVITY_WAIT_INTERVAL     Sekunden zwischen zwei Abfragen beim Warten, Default 10
#   ACTIVITY_SETTLE_SECONDS    Nachlauf nach dem Ende der Aufrufer, Default ACTIVITY_RECENT_SECONDS
#   ACTIVITY_DATE_CMD          Uhr in Sekunden für die Warteschleife, Default "date +%s"
#  Zahlen müssen nicht-negative Ganzzahlen sein (Intervall mindestens 1), sonst blockiert.
#   ACTIVITY_TAG               Präfix der Ausgabezeilen

ACTIVITY_DB="${ACTIVITY_DB:-$HOME/.local/share/opencode/opencode.db}"
ALLOW_STALE_HOURS="${ALLOW_STALE_HOURS:-}"
ACTIVITY_RECENT_SECONDS="${ACTIVITY_RECENT_SECONDS:-120}"
ACTIVITY_PS_CMD="${ACTIVITY_PS_CMD:-ps -axo pid=,ppid=,args=}"
ACTIVITY_ENV_CMD="${ACTIVITY_ENV_CMD:-ps eww -o command= -p}"
ACTIVITY_CURL="${ACTIVITY_CURL:-curl}"
OPENCHAMBER_PORT="${OPENCHAMBER_PORT:-3000}"
# Nicht die CoreSimulator-Daemons (CoreSimulatorService, simdiskimaged,
# launchd_sim, …): die laufen bei gebootetem Simulator immer.
ACTIVITY_PROCESS_PATTERNS="${ACTIVITY_PROCESS_PATTERNS:-xcodebuild xcrun:simctl simctl xctest}"
ACTIVITY_PROCESS_IGNORE="${ACTIVITY_PROCESS_IGNORE-(^|[ /])simctl list( |\$)}"
ACTIVITY_TAG="${ACTIVITY_TAG:-[activity]}"

activity_say() { echo "$ACTIVITY_TAG $*"; }

# activity_int <name> <wert> [minimum]: nicht-negative Ganzzahl ohne führende
# Null, höchstens 15 Stellen, >= minimum. Sonst Meldung auf stdout und Exit 1.
activity_int() {
  case "$2" in
    '' | *[!0-9]* | 0?* | ????????????????*) echo "$1 ungültig: '$2' (nicht-negative Ganzzahl erwartet)"; return 1 ;;
  esac
  [ "$2" -ge "${3:-0}" ] || { echo "$1 ungültig: '$2' (mindestens ${3:-0})"; return 1; }
}

activity_clock() { eval "${ACTIVITY_DATE_CMD:-date +%s}"; }

# Wert einer Option aus einer Befehlszeile ("--name N" oder "--name=N")
activity_opt() {
  printf '%s\n' "$1" | awk -v o="--$2" '{
    for (i = 1; i <= NF; i++) {
      if ($i == o && i < NF) { print $(i + 1); exit }
      if (index($i, o "=") == 1) { print substr($i, length(o) + 2); exit }
    }
  }'
}

# Laufende Session-IDs der von OpenChamber verwalteten OpenCode-Instanz.
# $1 = Prozessliste (pid ppid args). Bei jedem Fehler: Grund auf stdout, Exit 1.
# Das Passwort (OPENCODE_SERVER_PASSWORD aus der Prozessumgebung) geht nur per
# stdin als curl-Konfiguration an curl, nie in argv, Ausgabe oder Dateien.
activity_live_default() {
  _ps=$1
  [ -n "$_ps" ] || { echo "keine Prozessliste"; return 1; }

  # Genau ein OpenChamber-Prozess "… cli.js serve … --port $OPENCHAMBER_PORT"
  _oc=$(printf '%s\n' "$_ps" | awk -v want="$OPENCHAMBER_PORT" '{
    port = ""; srv = 0
    for (i = 3; i <= NF; i++) {
      if ($i ~ /(^|\/)cli\.js$/ && $(i + 1) == "serve") srv = 1
      if ($i == "--port" && i < NF) port = $(i + 1)
      else if (index($i, "--port=") == 1) port = substr($i, 8)
    }
    if (srv && port == want) print $1
  }')
  _n=$(printf '%s' "$_oc" | grep -c .)
  [ "$_n" = 1 ] || { echo "OpenChamber auf Port $OPENCHAMBER_PORT nicht eindeutig gefunden ($_n Prozesse)"; return 1; }

  # Genau ein Kindprozess "opencode serve"
  _line=$(printf '%s\n' "$_ps" | awk -v parent="$_oc" '$2 == parent { n = split($3, a, "/"); if (a[n] == "opencode" && $4 == "serve") print }')
  _n=$(printf '%s' "$_line" | grep -c .)
  [ "$_n" = 1 ] || { echo "verwaltete OpenCode-Instanz (Kind von PID $_oc) nicht eindeutig gefunden ($_n Prozesse)"; return 1; }
  _pid=$(printf '%s\n' "$_line" | awk '{ print $1 }')
  _port=$(activity_opt "$_line" port)
  _host=$(activity_opt "$_line" hostname)
  case "$_port" in '' | *[!0-9]*) echo "Port der OpenCode-Instanz (PID $_pid) nicht lesbar"; return 1 ;; esac
  case "$_host" in '' | 0.0.0.0) _host=127.0.0.1 ;; *[!A-Za-z0-9.-]*) echo "Host '$_host' nicht unterstützt"; return 1 ;; esac

  # Prozessumgebung erst vollständig erfassen (Exitcode geprüft), dann parsen
  _env=$(eval "$ACTIVITY_ENV_CMD \"\$_pid\"" 2>/dev/null) || { _env=; echo "Prozessumgebung von PID $_pid nicht lesbar"; return 1; }
  [ -n "$_env" ] || { echo "Prozessumgebung von PID $_pid leer"; return 1; }
  _pw=$(printf '%s\n' "$_env" | tr ' ' '\n' | sed -n 's/^OPENCODE_SERVER_PASSWORD=//p' | head -n 1)
  _env=
  # curl-Konfiguration: Wert in Anführungszeichen, \ und " escapen
  _pw=$(printf '%s' "$_pw" | sed 's/[\\"]/\\&/g')
  _resp=$(
    { [ -z "$_pw" ] || printf 'user = "opencode:%s"\n' "$_pw"; } |
      $ACTIVITY_CURL -sS -m 3 -K - -H 'Accept: application/json' -w '\n%{http_code}' \
        "http://$_host:$_port/api/session/active" 2>&1
  ) || { echo "Abfrage $_host:$_port fehlgeschlagen: $(printf '%s\n' "$_resp" | tail -n 1 | cut -c1-120)"; return 1; }
  _pw=
  _code=$(printf '%s\n' "$_resp" | tail -n 1)
  [ "$_code" = 200 ] || { echo "Abfrage $_host:$_port: HTTP $_code$( [ "$_code" = 401 ] && echo ' (Passwort fehlt oder falsch)')"; return 1; }

  # Erwartet {"data": {"<id>": {…}, …}}; alles andere ist kein "nichts läuft"
  _body=$(printf '%s\n' "$_resp" | sed '$d' | sed "s/'/''/g")
  _ok=$(sqlite3 :memory: "select case when json_valid(x) then
      (case when json_type(x, '\$.data') = 'object'
            and (select count(*) from json_each(x, '\$.data') where type <> 'object') = 0
       then 1 else 0 end) else 0 end from (select '$_body' as x)" 2>/dev/null)
  [ "$_ok" = 1 ] || { echo "Antwort von $_host:$_port hat nicht die Form {\"data\":{…}}"; return 1; }
  sqlite3 :memory: "select key from json_each('$_body', '\$.data')" || { echo "Antwort nicht auswertbar"; return 1; }
}

activity_live() {
  if [ -n "${ACTIVITY_LIVE_CMD:-}" ]; then
    eval "$ACTIVITY_LIVE_CMD"
  else
    activity_live_default "$1"
  fi
}

# Zeilen "pid args" der laufenden Build-/Simulator-Befehle. $1 = Prozessliste.
# Ein Programm zählt, wenn die Befehlszeile mit "prog" oder "<pfad>/prog" beginnt
# (der Pfad darf Leerzeichen enthalten).
activity_processes() {
  printf '%s\n' "$1" | awk -v pats="$ACTIVITY_PROCESS_PATTERNS" -v ign="$ACTIVITY_PROCESS_IGNORE" '
    BEGIN { np = split(pats, p, " ") }
    NF < 3 { next }
    {
      args = $0; sub(/^ *[^ ]+ +[^ ]+ +/, "", args)
      if (ign != "" && args ~ ign) next
      for (i = 1; i <= np; i++) {
        split(p[i], q, ":")
        re = "^(/.*/)?" q[1] "( |$)"
        if (q[2] != "") re = "^(/.*/)?" q[1] " (.* )?" q[2] "( |$)"
        if (args ~ re) { print $1 " " substr(args, 1, 150); break }
      }
    }'
}

# Läuft "<…> <cli> serve … --port $OPENCHAMBER_PORT" (auch --port=N)? Fehler = nein.
activity_runs_cli() {
  _rps=$(eval "$ACTIVITY_PS_CMD") || return 1
  printf '%s\n' "$_rps" | awk -v cli="$1" -v want="$OPENCHAMBER_PORT" '{
    port = ""; srv = 0
    for (i = 3; i <= NF; i++) {
      if ($i == cli && $(i + 1) == "serve") srv = 1
      if ($i == "--port" && i < NF) port = $(i + 1)
      else if (index($i, "--port=") == 1) port = substr($i, 8)
    }
    if (srv && port == want) f = 1
  } END { exit !f }'
}

# ACTIVITY_IGNORE_SESSION und seine Vorfahren (parent_id-Kette), eine ID pro Zeile.
# Ungültige ID oder DB-Fehler: Grund auf stdout, Exit 1.
activity_ignored_ids() {
  _id=${ACTIVITY_IGNORE_SESSION:-}
  case "$_id" in '' | *[!A-Za-z0-9_]*) echo "ACTIVITY_IGNORE_SESSION ungültig: '$_id'"; return 1 ;; esac
  _anc=$(sqlite3 -readonly "$ACTIVITY_DB" "
    with recursive anc(id, parent) as (
      select id, parent_id from session_v2 where id = '$_id'
      union select s.id, s.parent_id from session_v2 s join anc a on s.id = a.parent)
    select id from anc" 2>&1) || { echo "DB nicht lesbar für ACTIVITY_IGNORE_SESSION: $(printf '%s' "$_anc" | head -n 1)"; return 1; }
  # Unbekannte ID: nur sie selbst (Tippfehler führt so höchstens zur Selbstblockade)
  [ -n "$_anc" ] || _anc=$_id
  printf '%s\n' "$_anc"
}

# Welche der ausgenommenen Sessions ($1, eine pro Zeile) laufen gerade live?
# Ausgabe: IDs mit Leerzeichen getrennt (leer = keine). Exit 1 = Live-Status
# nicht verfügbar (Grund auf stdout).
activity_ignored_live() {
  _wps=$(eval "$ACTIVITY_PS_CMD") || _wps=
  _wlive=$(activity_live "$_wps") || { printf '%s' "$_wlive" | tail -n 1; return 1; }
  printf '%s\n' "$_wlive" | awk -v ids="$(printf '%s' "$1" | tr '\n' ' ')" '
    BEGIN { n = split(ids, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    ($0 in want) { printf "%s ", $0 }'
}

# Wartet, bis keine der ausgenommenen Sessions mehr live läuft und das auch nach
# ACTIVITY_SETTLE_SECONDS (Default ACTIVITY_RECENT_SECONDS, wegen ihres eigenen
# time_updated) noch so ist. Wacht eine wieder auf (Lead nach Subagent), geht es
# zurück in die Warteschleife. ACTIVITY_WAIT_TIMEOUT ist ein Gesamtbudget
# inklusive Nachlauf: jedes sleep wird auf den Rest begrenzt, ein abgekürzter
# Nachlauf oder eine abgelaufene Frist ist kein Erfolg.
# 0 = fertig, 1 = Zeitüberschreitung oder IDs nicht ermittelbar. Live-Status
# nicht abrufbar zählt als "läuft noch".
activity_wait_ignored() {
  _ids=$(activity_ignored_ids) || { activity_say "$_ids"; return 1; }
  _timeout=${ACTIVITY_WAIT_TIMEOUT:-900}
  _settle=${ACTIVITY_SETTLE_SECONDS:-$ACTIVITY_RECENT_SECONDS}
  _int=${ACTIVITY_WAIT_INTERVAL:-10}
  _bad=$(activity_int ACTIVITY_WAIT_TIMEOUT "$_timeout" && activity_int ACTIVITY_SETTLE_SECONDS "$_settle" &&
    activity_int ACTIVITY_WAIT_INTERVAL "$_int" 1) || { activity_say "$_bad"; return 1; }
  _t=$(activity_clock) && activity_int Uhr "$_t" >/dev/null || { activity_say "Uhr nicht lesbar: '$_t'"; return 1; }
  _deadline=$((_t + _timeout))
  _last=
  activity_say "Warte, bis die Aufrufer-Sessions fertig sind: $(printf '%s' "$_ids" | tr '\n' ' ')(höchstens $_timeout s inkl. $_settle s Nachlauf)"
  while :; do
    _rest=$((_deadline - $(activity_clock)))
    if [ "$_rest" -le 0 ]; then
      activity_say "Zeitüberschreitung nach $_timeout s"
      return 1
    fi
    _now_msg=
    if _still=$(activity_ignored_live "$_ids"); then
      if [ -z "$_still" ]; then
        _rest=$((_deadline - $(activity_clock)))
        if [ "$_rest" -lt "$_settle" ]; then
          activity_say "Aufrufer-Sessions laufen nicht mehr, aber der Nachlauf ($_settle s) passt nicht mehr ins Restbudget ($_rest s)"
          activity_say "Zeitüberschreitung nach $_timeout s"
          return 1
        fi
        activity_say "Aufrufer-Sessions laufen nicht mehr, warte $_settle s"
        sleep "$_settle"
        if _still=$(activity_ignored_live "$_ids"); then
          if [ -z "$_still" ]; then
            if [ "$(activity_clock)" -ge "$_deadline" ]; then
              activity_say "Zeitüberschreitung nach $_timeout s"
              return 1
            fi
            activity_say "Aufrufer-Sessions auch nach $_settle s nicht live"
            return 0
          fi
          activity_say "Aufrufer-Sessions wieder live: $_still, warte weiter"
        else
          activity_say "Live-Status nicht abrufbar: $_still, warte weiter"
        fi
        _last=
      else
        _now_msg="läuft noch: $_still"
      fi
    else
      _now_msg="Live-Status nicht abrufbar: $_still"
    fi
    [ -z "$_now_msg" ] || [ "$_now_msg" = "$_last" ] || activity_say "$_now_msg"
    _last=$_now_msg
    _rest=$((_deadline - $(activity_clock)))
    _sl=$_int
    [ "$_rest" -ge "$_sl" ] || _sl=$_rest
    [ "$_sl" -le 0 ] || sleep "$_sl"
  done
}

activity_check() {
  _tab=$(printf '\t')
  _out=

  activity_add() { _out="$_out$1
"; }

  # Zahlen aus der Umgebung prüfen, bevor gerechnet wird; ungültig = blockiert
  _recent_s=$ACTIVITY_RECENT_SECONDS
  _bad=$(activity_int ACTIVITY_RECENT_SECONDS "$_recent_s") || { activity_add "BLOCK  $_bad"; _recent_s=0; }
  _bad=$(activity_int OPENCHAMBER_PORT "$OPENCHAMBER_PORT") || activity_add "BLOCK  $_bad"
  _now=${ACTIVITY_NOW_MS:-$(($(date +%s) * 1000))}
  _bad=$(activity_int ACTIVITY_NOW_MS "$_now") || { activity_add "BLOCK  $_bad"; _now=0; }
  _recent_ms=$((_recent_s * 1000))

  # Prozessliste einmal erfassen, Exitcode prüfen, dann erst filtern
  _psok=1
  _ps=$(eval "$ACTIVITY_PS_CMD") || _psok=0
  [ -n "$_ps" ] || _psok=0
  [ $_psok = 1 ] || activity_add "BLOCK  Prozessliste nicht lesbar ($ACTIVITY_PS_CMD)"

  # 1. DB-Kandidaten: id, Titel, Typ, Zeit, Parent, Alter in ms
  _dbok=1
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
    order by l.time_updated desc" 2>&1) || {
    _dbok=0
    activity_add "BLOCK  DB nicht lesbar: $ACTIVITY_DB ($(printf '%s' "$_cand" | head -n 1 | cut -c1-100))"
    _cand=
  }

  # Ausgenommene Aufrufer-Sessions (ACTIVITY_IGNORE_SESSION samt Vorfahren)
  _ign=
  if [ -n "${ACTIVITY_IGNORE_SESSION:-}" ]; then
    if _ign=$(activity_ignored_ids); then
      activity_add "INFO   Ausgenommen (Aufrufer): $(printf '%s' "$_ign" | tr '\n' ' ')"
    else
      activity_add "BLOCK  $_ign"
      _ign=
    fi
  fi
  _ignl=$(printf '%s' "$_ign" | tr '\n' ' ')

  _stale_ms=
  if _live=$(activity_live "$_ps"); then
    _mode=live
    activity_add "INFO   Live-Status: abgefragt ($(printf '%s' "$_live" | grep -c .) laufend)"
  else
    _reason=$(printf '%s' "$_live" | tail -n 1)
    _live=
    _bad=
    [ -z "$ALLOW_STALE_HOURS" ] || _bad=$(activity_int ALLOW_STALE_HOURS "$ALLOW_STALE_HOURS") || :
    case "$ALLOW_STALE_HOURS" in
      '' | *[!0-9]* | 0?* | ????????????????*)
        _mode=none
        [ -z "$_bad" ] || activity_add "BLOCK  $_bad"
        activity_add "BLOCK  Live-Status nicht verfügbar: ${_reason:-unbekannt} (FORCE=1 oder ALLOW_STALE_HOURS=N)"
        ;;
      *)
        _mode=age
        _stale_ms=$((ALLOW_STALE_HOURS * 3600000))
        activity_add "WARN   Live-Status nicht verfügbar: ${_reason:-unbekannt}; ALLOW_STALE_HOURS=$ALLOW_STALE_HOURS"
        ;;
    esac
  fi

  _rep=$(printf '%s\n' "$_cand" | awk -F "$_tab" -v mode="$_mode" -v stale="$_stale_ms" -v live="$(printf '%s' "$_live" | tr '\n' ' ')" -v ign="$_ignl" '
    BEGIN {
      n = split(live, ids, " "); for (i = 1; i <= n; i++) if (ids[i] != "") running[ids[i]] = 1
      n = split(ign, ids, " "); for (i = 1; i <= n; i++) if (ids[i] != "") ignored[ids[i]] = 1
    }
    NF >= 6 {
      seen[$1] = 1
      line = sprintf("%s  \"%s\"  letzter=%s  %s  parent=%s", $1, $2, $3, $4, $5)
      if ($1 in ignored) print "IGNORE Session " line " (ignoriert (Aufrufer))"
      else if (mode == "live") {
        if ($1 in running) print "BLOCK  Session " line " (live: läuft)"
        else print "IGNORE Session " line " (live: nicht laufend, vermutlich abgebrochen)"
      } else if (mode == "age") {
        if ($6 < stale) print "BLOCK  Session " line " (jünger als " stale / 3600000 " h)"
        else print "IGNORE Session " line " (älter als " stale / 3600000 " h, per ALLOW_STALE_HOURS ignoriert)"
      } else print "BLOCK  Session " line " (Live-Status unbekannt)"
    }
    END {
      for (id in running) if (!(id in seen)) {
        if (id in ignored) print "IGNORE Session " id " (live: läuft, ignoriert (Aufrufer))"
        else print "BLOCK  Session " id " (live: läuft, DB-Eintrag idle oder unbekannt)"
      }
    }')
  [ -z "$_rep" ] || activity_add "$_rep"

  # 2. Prozesse
  if [ $_psok = 1 ]; then
    _procs=$(activity_processes "$_ps" | sed 's/^/BLOCK  Prozess /')
    [ -z "$_procs" ] || activity_add "$_procs"
  fi

  # 3. Sessions, die in den letzten ACTIVITY_RECENT_SECONDS geändert wurden
  if [ $_dbok = 1 ]; then
    if _recent=$(sqlite3 -readonly -separator "$_tab" "$ACTIVITY_DB" "
      select id, substr(replace(replace(coalesce(title, ''), char(9), ' '), char(10), ' '), 1, 50),
             datetime(time_updated / 1000, 'unixepoch', 'localtime')
      from session_v2 where time_updated > $_now - $_recent_ms order by time_updated desc" 2>&1); then
      _recent=$(printf '%s\n' "$_recent" | awk -F "$_tab" -v s="$ACTIVITY_RECENT_SECONDS" -v ign="$_ignl" '
        BEGIN { n = split(ign, a, " "); for (i = 1; i <= n; i++) ignored[a[i]] = 1 }
        NF >= 3 {
          if ($1 in ignored) printf "IGNORE Kürzlich %s  \"%s\"  geändert %s (ignoriert (Aufrufer))\n", $1, $2, $3
          else printf "BLOCK  Kürzlich %s  \"%s\"  geändert %s (< %s s)\n", $1, $2, $3, s
        }')
      [ -z "$_recent" ] || activity_add "$_recent"
    else
      activity_add "BLOCK  DB nicht lesbar: $ACTIVITY_DB ($(printf '%s' "$_recent" | head -n 1 | cut -c1-100))"
    fi
  fi

  printf '%s' "$_out" | while IFS= read -r _l; do activity_say "$_l"; done
  if printf '%s' "$_out" | grep -q '^BLOCK'; then
    activity_say "Ergebnis: AKTIV (Neustart würde obige Züge/Prozesse abbrechen)"
    return 1
  fi
  activity_say "Ergebnis: ruhig"
  return 0
}
