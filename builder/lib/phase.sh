# Abgekoppelte Neustartphase der Umschaltskripte. POSIX sh, nach lib/activity.sh
# geladen; nutzt say/die des Skripts.
#
#   phase_proof_create      # Phase 1: Einmal-Nachweis anlegen, setzt PROOF_DIR/PROOF_TOKEN
#   phase_proof_claim       # Phase 2: Nachweis prüfen und verbrauchen, sonst die
#   phase_gate              # Phase 2: auf Aufrufer warten, zweite Prüfung ohne Ausnahme
#   phase_spawn <log> args  # Phase 1: Phase 2 abgekoppelt starten
#
# Der Nachweis ist eine Datei mit Zufallstoken in einem per mktemp -d angelegten
# 0700-Verzeichnis direkt unter $TMPDIR. Verzeichnis und Token gehen per
# Umgebung (nicht argv) an Phase 2. Die Skripte übernehmen sie als erstes in
# nicht exportierte Variablen (_PROOF_DIR, _PROOF_TOKEN) und entfernen sie aus
# der Umgebung. Phase 2 verbraucht die Datei per mv (gelingt nur einmal), löscht
# nur diese Datei und dann das leere Verzeichnis (rmdir).

PHASE_PROOF_PREFIX="openchamber-switch."

# Kanonisches Ablageverzeichnis (TMPDIR, wie mktemp es nutzt)
phase_proof_base() { (cd "${TMPDIR:-/tmp}" && pwd -P); }

phase_proof_create() {
  _base=$(phase_proof_base) || die "TMPDIR nicht nutzbar"
  PROOF_DIR=$(mktemp -d "$_base/${PHASE_PROOF_PREFIX}XXXXXX") || die "mktemp fehlgeschlagen"
  chmod 700 "$PROOF_DIR"
  PROOF_TOKEN=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [ ${#PROOF_TOKEN} = 32 ] || die "Zufallstoken fehlgeschlagen"
  (umask 077 && printf '%s\n' "$PROOF_TOKEN" > "$PROOF_DIR/token") || die "Nachweis nicht schreibbar"
}

# Erwartet _PROOF_DIR/_PROOF_TOKEN (vom Skript ganz am Anfang aus der Umgebung übernommen).
# Alles, was nicht genau nach unserem Nachweis aussieht, bleibt unangetastet.
phase_proof_claim() {
  _d=${_PROOF_DIR:-}
  _t=${_PROOF_TOKEN:-}
  _PROOF_DIR=; _PROOF_TOKEN=
  _fail="--restart ist eine interne Phase und nicht direkt aufrufbar"
  [ -n "$_d" ] && [ -n "$_t" ] || die "$_fail (kein Nachweis)"
  case "$(basename "$_d")" in "$PHASE_PROOF_PREFIX"*) ;; *) die "$_fail (Nachweis am falschen Ort)" ;; esac
  _base=$(phase_proof_base) || die "$_fail (TMPDIR nicht nutzbar)"
  _parent=$(cd "$(dirname "$_d")" 2>/dev/null && pwd -P) || die "$_fail (Nachweis fehlt)"
  [ "$_parent" = "$_base" ] || die "$_fail (Nachweis am falschen Ort)"
  _d="$_base/$(basename "$_d")"
  [ -d "$_d" ] && [ ! -L "$_d" ] && [ -O "$_d" ] || die "$_fail (Nachweis fehlt)"
  [ "$(ls -ld "$_d" | cut -c1-10)" = "drwx------" ] || die "$_fail (Nachweis-Verzeichnis nicht 0700)"
  [ "$(ls -A "$_d")" = token ] || die "$_fail (Nachweis fehlt, schon verbraucht oder Verzeichnis nicht leer)"
  [ -f "$_d/token" ] && [ ! -L "$_d/token" ] || die "$_fail (Nachweis keine Datei)"
  mv "$_d/token" "$_d/token.claimed.$$" 2>/dev/null || die "$_fail (Nachweis schon verbraucht)"
  _got=$(cat "$_d/token.claimed.$$" 2>/dev/null || true)
  rm -f "$_d/token.claimed.$$"
  rmdir "$_d" 2>/dev/null || say "Hinweis: $_d nicht leer, bleibt liegen"
  [ "$_got" = "$_t" ] || die "$_fail (Nachweis passt nicht)"
  _t=; _got=
}

# Mit ACTIVITY_IGNORE_SESSION: warten, bis Aufrufer und Vorfahren fertig sind
# (activity_wait_ignored, inkl. Nachlauf und Rückkehr in die Warteschleife),
# dann ohne Ausnahme prüfen. FORCE=1 überspringt das Warten und lässt
# Aktivität durch, listet sie aber.
phase_gate() {
  if [ -n "${ACTIVITY_IGNORE_SESSION:-}" ] && [ "${FORCE:-0}" != "1" ]; then
    activity_wait_ignored || die "Aufrufer-Sessions nicht rechtzeitig fertig: kein Neustart, Startskript unverändert."
  fi
  unset ACTIVITY_IGNORE_SESSION
  echo "Zweite Aktivitätsprüfung $(date)"
  if ! activity_check; then
    if [ "${FORCE:-0}" = "1" ]; then
      say "FORCE=1: Aktivität ignoriert"
    else
      die "Aktivität bei der zweiten Prüfung: kein Neustart, Startskript unverändert. Später erneut oder FORCE=1."
    fi
  fi
}

# Phase 2 starten: abgekoppelt per nohup (SWITCH_SYNC=1 nur für Tests: im
# Vordergrund, Exitstatus wird weitergegeben). $1 = Log, weitere Argumente an das Skript.
phase_spawn() {
  _log=$1; shift
  phase_proof_create
  _rc=0
  if [ "${SWITCH_SYNC:-0}" = "1" ]; then
    SWITCH_PROOF_DIR="$PROOF_DIR" SWITCH_PROOF_TOKEN="$PROOF_TOKEN" FORCE="${FORCE:-0}" \
      /bin/sh "$0" "$@" > "$_log" 2>&1 < /dev/null || _rc=$?
  else
    SWITCH_PROOF_DIR="$PROOF_DIR" SWITCH_PROOF_TOKEN="$PROOF_TOKEN" FORCE="${FORCE:-0}" \
      nohup /bin/sh "$0" "$@" > "$_log" 2>&1 < /dev/null &
  fi
  PROOF_TOKEN=
  return $_rc
}
