#!/bin/sh
# Rückweg: LaunchAgent dev.openchamber.web wieder auf die npm-Installation
# (~/.bun/install/global/node_modules/@openchamber/web). Idempotent.
#
#   sh switch-to-npm.sh            # stellt Startskript wieder her, startet neu, prüft
#   FORCE=1 sh switch-to-npm.sh    # auch wenn gerade Sessions aktiv sind (im Notfall immer)
#   sh switch-to-npm.sh --check    # nur Aktivität melden (auch CHECK_ONLY=1), ändert nichts
#   ACTIVITY_IGNORE_SESSION=ses_… sh switch-to-npm.sh   # aus einer Agent-Session (README.md)
#
# Aktivitätsregel und Ablauf: builder/README.md.
#
# Wie beim Umschalten beendet der Neustart die verwaltete OpenCode-Instanz;
# deshalb laufen zweite Aktivitätsprüfung, Wiederherstellen des Startskripts,
# Neustart und Prüfung abgekoppelt (interne Phase --restart, nur mit
# Einmal-Nachweis) nach $LOG.

# Nachweis für die interne Phase als allererstes aus der Umgebung nehmen
# (nicht exportiert weiterführen), damit kein Kindprozess ihn sieht.
unset _PROOF_DIR _PROOF_TOKEN
_PROOF_DIR=${SWITCH_PROOF_DIR:-}
_PROOF_TOKEN=${SWITCH_PROOF_TOKEN:-}
unset SWITCH_PROOF_DIR SWITCH_PROOF_TOKEN
set -eu

FORK_CLI="${SWITCH_RELEASE:-$HOME/Projects/openchamber-release}/packages/web/bin/cli.js"
NPM_CLI="${SWITCH_NPM_CLI:-$HOME/.bun/install/global/node_modules/@openchamber/web/bin/cli.js}"
START="${SWITCH_START:-$HOME/.config/openchamber/bin/OpenChamber}"
BACKUP="$START.npm-2.2.0.bak"
SERVICE="gui/$(id -u)/dev.openchamber.web"
ERRLOG="${SWITCH_ERRLOG:-$HOME/Library/Logs/OpenChamber/startup.err.log}"
LAUNCHCTL="${SWITCH_LAUNCHCTL:-launchctl}"
CURL="${SWITCH_CURL:-curl}"
# Verzeichnis des Skripts (auch über Symlink aufgerufen), für lib/
SELF="$0"
while [ -L "$SELF" ]; do
  LINK=$(readlink "$SELF")
  case "$LINK" in /*) SELF="$LINK" ;; *) SELF="$(dirname "$SELF")/$LINK" ;; esac
done
BUILDER_DIR=$(cd "$(dirname "$SELF")" && pwd)

say() { echo "[switch-to-npm] $*"; }
die() { echo "[switch-to-npm] FEHLER: $*" >&2; exit 1; }

ACTIVITY_TAG="[switch-to-npm]"
. "$BUILDER_DIR/lib/activity.sh"
. "$BUILDER_DIR/lib/phase.sh"
. "$BUILDER_DIR/lib/startscript.sh"
runs() { activity_runs_cli "$1"; }

# Nur prüfen: vor jedem anderen Zweig, endet immer ohne Seiteneffekte (Exit 1 = aktiv)
for a in "$@"; do case "$a" in --check) CHECK_ONLY=1 ;; --dry-run) DRY_RUN=1 ;; esac; done
if [ "${CHECK_ONLY:-0}" = "1" ]; then
  if activity_check; then exit 0; fi
  exit 1
fi

# Temp-Datei für das Startskript; Trap erst hier, damit --check nichts anfasst
TMP="$START.tmp.$$"
[ "${DRY_RUN:-0}" = "1" ] || trap 'rm -f "$TMP"' EXIT

# Startskript wiederherstellen: bevorzugt aus der Sicherung, sonst Pfad zurücktauschen
restore_start() {
  [ -f "$START" ] || die "$START fehlt, Startskript von Hand prüfen"
  if grep -qF "$NPM_CLI" "$START"; then
    say "Startskript zeigt schon auf npm"
  elif { [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; } && ! private_file_ok "$BACKUP"; then
    die "Sicherung $BACKUP ist kein privates reguläres eigenes File (Symlink, fremd oder Rechte für Gruppe/Welt). Bitte prüfen."
  elif [ -f "$BACKUP" ] && grep -qF "$NPM_CLI" "$BACKUP"; then
    cp -p "$BACKUP" "$TMP"
    mv "$TMP" "$START"
    say "Startskript aus $BACKUP wiederhergestellt"
  else
    sed "s|$FORK_CLI|$NPM_CLI|" "$START" > "$TMP"
    grep -qF "$NPM_CLI" "$TMP" || die "Wiederherstellung fehlgeschlagen, Startskript von Hand prüfen"
    chmod 700 "$TMP"
    mv "$TMP" "$START"
    say "Pfad im Startskript zurückgetauscht (keine Sicherung gefunden)"
  fi
}

# --dry-run: Phase 1 komplett lesend, meldet was passieren würde. Schreibt nichts,
# startet keine Phase 2. Exit 0 = würde umschalten (oder nichts zu tun), 1 = blockiert/Fehler.
dry() { echo "[switch-to-npm] [dry-run] $*"; }
dry_run() {
  [ -f "$NPM_CLI" ] || die "npm-Installation fehlt: $NPM_CLI"
  dry "OK  npm-Installation vorhanden: $NPM_CLI"
  [ -f "$START" ] || die "$START fehlt, Startskript von Hand prüfen"
  if grep -qF "$NPM_CLI" "$START"; then
    dry "OK  Startskript zeigt schon auf npm, würde nicht geändert"
  elif [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
    private_file_ok "$BACKUP" || die "Sicherung $BACKUP ist kein privates reguläres eigenes File (Symlink, fremd oder Rechte für Gruppe/Welt)"
    grep -qF "$NPM_CLI" "$BACKUP" || die "$BACKUP enthält nicht den npm-Pfad"
    dry "würde Startskript aus $BACKUP wiederherstellen"
  elif grep -qF "$FORK_CLI" "$START"; then
    dry "würde im Startskript $FORK_CLI -> $NPM_CLI zurücktauschen (keine Sicherung gefunden)"
  else
    die "keine npm-Sicherung und Startskript enthält $FORK_CLI nicht; SWITCH_RELEASE=<aktueller Fork-Pfad> setzen"
  fi
  if runs "$NPM_CLI"; then
    dry "npm-Version läuft bereits: würde nur das Startskript angleichen, kein Neustart"
    exit 0
  fi
  if activity_check; then
    dry "OK  Aktivitätsprüfung ruhig"
  elif [ "${FORCE:-0}" = "1" ]; then
    dry "Aktivität erkannt, FORCE=1: würde trotzdem umschalten"
  else
    dry "BLOCKIERT: Aktivität erkannt (siehe oben), würde nicht umschalten"
    exit 1
  fi
  if [ -n "${ACTIVITY_IGNORE_SESSION:-}" ] && [ "${FORCE:-0}" != "1" ]; then
    dry "Phase 2 würde warten, bis die Aufrufer-Sessions fertig sind (höchstens ${ACTIVITY_WAIT_TIMEOUT:-900} s), dann ohne Ausnahme prüfen"
  fi
  dry "Ergebnis: würde auf npm umschalten und OpenChamber neu starten. Nichts geändert."
  exit 0
}
if [ "${DRY_RUN:-0}" = "1" ]; then
  dry_run
fi

# Interne Phase (abgekoppelt), nur mit dem Einmal-Nachweis aus Phase 1
if [ "${1:-}" = "--restart" ]; then
  phase_proof_claim
  ERR_LINES="${2:-0}"
  phase_gate
  restore_start
  echo "Neustart $(date)"
  $LAUNCHCTL kickstart -k "$SERVICE"
  ok=0; i=0
  while [ $i -lt 60 ]; do
    i=$((i + 1))
    if [ "$($CURL -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:3000/health)" = 200 ]; then ok=1; break; fi
    sleep 1
  done
  if [ $ok = 1 ]; then echo "OK: /health 200 nach ${i}s"; else echo "FEHLER: /health nach 60s nicht erreichbar"; fi
  if runs "$NPM_CLI"; then echo "OK: npm-Prozess läuft"; else echo "FEHLER: npm-Prozess nicht gefunden"; fi
  echo "--- neue Zeilen in startup.err.log:"
  tail -n +$((ERR_LINES + 1)) "$ERRLOG" 2>/dev/null | cut -c1-200 | tail -40
  echo "--- Ende"
  exit 0
fi
[ $# -eq 0 ] || die "Unbekanntes Argument: $1"

[ -f "$NPM_CLI" ] || die "npm-Installation fehlt: $NPM_CLI"
[ -f "$START" ] || die "$START fehlt, Startskript von Hand prüfen"

# Läuft npm schon? Dann nur das Startskript angleichen, ohne Prüfung und Neustart.
if runs "$NPM_CLI"; then
  restore_start
  say "npm-Version läuft bereits, kein Neustart nötig"
  exit 0
fi

if [ "${FORCE:-0}" != "1" ]; then
  activity_check || die "Aktivität erkannt (siehe oben). Später erneut oder FORCE=1."
else
  activity_check || say "FORCE=1: Aktivität ignoriert"
fi

LOG="${LOG:-/tmp/openchamber-switch-back-$(date +%Y%m%d-%H%M%S).log}"
ERR_LINES=$(wc -l < "$ERRLOG" 2>/dev/null | tr -d ' ' || echo 0)
phase_spawn "$LOG" --restart "$ERR_LINES"
say "Neustart läuft abgekoppelt (mit zweiter Aktivitätsprüfung). Prüfung: cat $LOG"
