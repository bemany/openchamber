# Abgekoppelte Neustartphase der Umschaltskripte. POSIX sh, nach lib/activity.sh
# geladen; nutzt say/die des Skripts.
#
#   phase_proof_create      # Phase 1: Einmal-Nachweis anlegen, setzt PROOF_DIR/PROOF_TOKEN
#   phase_proof_claim       # Phase 2: Nachweis prüfen und verbrauchen, sonst die
#   phase_gate              # Phase 2: auf Aufrufer warten, zweite Prüfung ohne Ausnahme
#
# Der Nachweis ist eine Datei mit Zufallstoken in einem per mktemp -d angelegten
# 0700-Verzeichnis. Verzeichnis und Token gehen per Umgebung (nicht argv) an
# Phase 2; Phase 2 verbraucht die Datei per mv (gelingt nur einmal), löscht das
# Verzeichnis und entfernt die Variablen, bevor sie irgendetwas anderes tut.

PHASE_PROOF_PREFIX="openchamber-switch."

phase_proof_create() {
  PROOF_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${PHASE_PROOF_PREFIX}XXXXXX") || die "mktemp fehlgeschlagen"
  chmod 700 "$PROOF_DIR"
  PROOF_TOKEN=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [ ${#PROOF_TOKEN} = 32 ] || die "Zufallstoken fehlgeschlagen"
  (umask 077 && printf '%s\n' "$PROOF_TOKEN" > "$PROOF_DIR/token") || die "Nachweis nicht schreibbar"
}

phase_proof_claim() {
  _d=${SWITCH_PROOF_DIR:-}
  _t=${SWITCH_PROOF_TOKEN:-}
  unset SWITCH_PROOF_DIR SWITCH_PROOF_TOKEN
  _fail="--restart ist eine interne Phase und nicht direkt aufrufbar"
  [ -n "$_d" ] && [ -n "$_t" ] || die "$_fail (kein Nachweis)"
  case "$(basename "$_d")" in "$PHASE_PROOF_PREFIX"*) ;; *) die "$_fail (Nachweis am falschen Ort)" ;; esac
  [ -d "$_d" ] && [ ! -L "$_d" ] && [ -O "$_d" ] || die "$_fail (Nachweis fehlt)"
  [ "$(ls -ld "$_d" | cut -c1-10)" = "drwx------" ] || die "$_fail (Nachweis-Verzeichnis nicht 0700)"
  mv "$_d/token" "$_d/token.claimed.$$" 2>/dev/null || die "$_fail (Nachweis fehlt oder schon verbraucht)"
  _got=$(cat "$_d/token.claimed.$$" 2>/dev/null || true)
  rm -rf "$_d"
  [ "$_got" = "$_t" ] || die "$_fail (Nachweis passt nicht)"
  _t=; _got=
}

# Mit ACTIVITY_IGNORE_SESSION: erst warten, bis Aufrufer und Vorfahren nicht mehr
# live laufen (ACTIVITY_WAIT_TIMEOUT), dann ACTIVITY_RECENT_SECONDS abwarten
# (ihr eigenes time_updated), dann ohne Ausnahme prüfen. FORCE=1 überspringt das
# Warten und lässt Aktivität durch, listet sie aber.
phase_gate() {
  if [ -n "${ACTIVITY_IGNORE_SESSION:-}" ] && [ "${FORCE:-0}" != "1" ]; then
    activity_wait_ignored || die "Aufrufer-Sessions nicht rechtzeitig fertig: kein Neustart, Startskript unverändert."
    say "Warte ${ACTIVITY_RECENT_SECONDS} s (120-s-Regel der eben beendeten Sessions)"
    sleep "$ACTIVITY_RECENT_SECONDS"
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

# Phase 2 starten: abgekoppelt per nohup (SWITCH_SYNC=1 nur für Tests: im Vordergrund).
# $1 = Log, weitere Argumente an das Skript.
phase_spawn() {
  _log=$1; shift
  phase_proof_create
  if [ "${SWITCH_SYNC:-0}" = "1" ]; then
    SWITCH_PROOF_DIR="$PROOF_DIR" SWITCH_PROOF_TOKEN="$PROOF_TOKEN" FORCE="${FORCE:-0}" \
      /bin/sh "$0" "$@" > "$_log" 2>&1 < /dev/null || true
  else
    SWITCH_PROOF_DIR="$PROOF_DIR" SWITCH_PROOF_TOKEN="$PROOF_TOKEN" FORCE="${FORCE:-0}" \
      nohup /bin/sh "$0" "$@" > "$_log" 2>&1 < /dev/null &
  fi
  PROOF_TOKEN=
}
