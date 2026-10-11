#!/bin/sh
# Schaltet den LaunchAgent dev.openchamber.web von der npm-Version auf den Fork
# im Release-Worktree um. Idempotent: zweimal ausführen schadet nicht.
#
#   sh switch-to-fork.sh            # prüft, sichert, schaltet um, prüft
#   FORCE=1 sh switch-to-fork.sh    # auch wenn gerade Sessions aktiv sind
#   sh switch-to-fork.sh --check    # nur Aktivität melden (auch CHECK_ONLY=1), ändert nichts
#   ACTIVITY_IGNORE_SESSION=ses_… sh switch-to-fork.sh   # aus einer Agent-Session (README.md)
#
# Aktivitätsregel und Ablauf: builder/README.md.
#
# ACHTUNG: Der Neustart beendet auch die von OpenChamber gestartete OpenCode-
# Instanz. Laufende Agent-Züge brechen ab. Deshalb laufen zweite Aktivitäts-
# prüfung, Umschreiben des Startskripts, Neustart und Prüfung abgekoppelt per
# nohup (interne Phase --restart, nur mit Einmal-Nachweis) und schreiben nach $LOG.

# Nachweis für die interne Phase als allererstes aus der Umgebung nehmen
# (nicht exportiert weiterführen), damit kein Kindprozess ihn sieht.
unset _PROOF_DIR _PROOF_TOKEN
_PROOF_DIR=${SWITCH_PROOF_DIR:-}
_PROOF_TOKEN=${SWITCH_PROOF_TOKEN:-}
unset SWITCH_PROOF_DIR SWITCH_PROOF_TOKEN
set -eu

RELEASE="${SWITCH_RELEASE:-$HOME/Projects/openchamber-release}"
EXPECTED_COMMIT="${EXPECTED_COMMIT:-d9dfc650946dad34a089ce901a76360bfbe30590}"
FORK_CLI="$RELEASE/packages/web/bin/cli.js"
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

say() { echo "[switch-to-fork] $*"; }
die() { echo "[switch-to-fork] FEHLER: $*" >&2; exit 1; }

ACTIVITY_TAG="[switch-to-fork]"
. "$BUILDER_DIR/lib/activity.sh"
. "$BUILDER_DIR/lib/phase.sh"
runs() { activity_runs_cli "$1"; }

# Nur prüfen: vor jedem anderen Zweig, endet immer ohne Seiteneffekte (Exit 1 = aktiv)
for a in "$@"; do case "$a" in --check) CHECK_ONLY=1 ;; esac; done
if [ "${CHECK_ONLY:-0}" = "1" ]; then
  if activity_check; then exit 0; fi
  exit 1
fi

# Temp-Datei für das Startskript; Trap erst hier, damit --check nichts anfasst
TMP="$START.tmp.$$"
trap 'rm -f "$TMP"' EXIT

# Startskript auf den Fork umschreiben (nur der cli.js-Pfad), atomar per mv
rewrite_start() {
  [ -f "$START" ] || die "$START fehlt"
  if grep -qF "$FORK_CLI" "$START"; then
    say "Startskript zeigt schon auf den Fork"
    return 0
  fi
  sed "s|$NPM_CLI|$FORK_CLI|" "$START" > "$TMP"
  grep -qF "$FORK_CLI" "$TMP" || die "Pfadersetzung fehlgeschlagen"
  chmod 700 "$TMP"
  mv "$TMP" "$START"
  say "Startskript umgestellt"
}

# Sicherung (nur einmal, und nur wenn sie wirklich die npm-Version enthält)
ensure_backup() {
  if [ ! -f "$BACKUP" ]; then
    grep -qF "$FORK_CLI" "$START" && { say "Startskript zeigt schon auf den Fork, keine Sicherung nötig"; return 0; }
    grep -qF "$NPM_CLI" "$START" || die "$START zeigt nicht auf die npm-Version, Sicherung wäre falsch. Bitte prüfen."
    cp -p "$START" "$BACKUP"
    say "Sicherung angelegt: $BACKUP"
  else
    grep -qF "$NPM_CLI" "$BACKUP" || die "$BACKUP enthält nicht den npm-Pfad"
    say "Sicherung vorhanden: $BACKUP"
  fi
}

# Interne Phase (abgekoppelt): Nachweis verbrauchen, warten/zweite Prüfung,
# Startskript umschreiben, Neustart, Prüfung.
if [ "${1:-}" = "--restart" ]; then
  phase_proof_claim
  ERR_LINES="${2:-0}"
  phase_gate
  rewrite_start
  echo "Neustart $(date)"
  $LAUNCHCTL kickstart -k "$SERVICE"
  ok=0; i=0
  while [ $i -lt 60 ]; do
    i=$((i + 1))
    if [ "$($CURL -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:3000/health)" = 200 ]; then ok=1; break; fi
    sleep 1
  done
  if [ $ok = 1 ]; then echo "OK: /health 200 nach ${i}s"; else echo "FEHLER: /health nach 60s nicht erreichbar"; fi
  echo "Root /: HTTP $($CURL -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:3000/)"
  if runs "$FORK_CLI"; then echo "OK: Fork-Prozess läuft"; else echo "FEHLER: Fork-Prozess nicht gefunden"; fi
  echo "--- neue Zeilen in startup.err.log:"
  tail -n +$((ERR_LINES + 1)) "$ERRLOG" 2>/dev/null | cut -c1-200 | tail -40
  echo "--- Ende"
  exit 0
fi
[ $# -eq 0 ] || die "Unbekanntes Argument: $1"

# 1. Release-Worktree prüfen
[ -f "$FORK_CLI" ] || die "$FORK_CLI fehlt"
[ -f "$RELEASE/packages/web/dist/index.html" ] || die "dist fehlt, erst 'bun run build:web' im Release-Worktree"
[ -d "$RELEASE/node_modules" ] || die "node_modules fehlt, erst 'bun install' im Release-Worktree"
HEAD=$(git -C "$RELEASE" rev-parse HEAD)
[ "$HEAD" = "$EXPECTED_COMMIT" ] || die "Release-Worktree steht auf $HEAD, erwartet $EXPECTED_COMMIT (EXPECTED_COMMIT=… setzen, wenn gewollt)"
[ -z "$(git -C "$RELEASE" status --porcelain --untracked-files=no)" ] || die "Release-Worktree hat lokale Änderungen"
[ -f "$START" ] || die "$START fehlt"

# 2. Läuft der Fork schon? Dann nur Sicherung/Startskript angleichen, ohne Prüfung und Neustart.
if runs "$FORK_CLI"; then
  ensure_backup
  rewrite_start
  say "Fork läuft bereits, kein Neustart nötig"
  exit 0
fi

# 3. Aktivität (Sessions, Build-/Simulator-Prozesse): Neustart würde sie abbrechen
if [ "${FORCE:-0}" != "1" ]; then
  activity_check || die "Aktivität erkannt (siehe oben). Neustart würde laufende Züge abbrechen. Später erneut oder FORCE=1."
else
  activity_check || say "FORCE=1: Aktivität ignoriert"
fi

# 4. Sicherung
ensure_backup

# 5. Warten/zweite Prüfung, Umschreiben, Neustart + Prüfung abgekoppelt
#    (überlebt den Abbruch des aufrufenden Zugs). Das Startskript ändert sich erst dort.
LOG="${LOG:-/tmp/openchamber-switch-$(date +%Y%m%d-%H%M%S).log}"
ERR_LINES=$(wc -l < "$ERRLOG" 2>/dev/null | tr -d ' ' || echo 0)
phase_spawn "$LOG" --restart "$ERR_LINES"
say "Neustart läuft abgekoppelt (mit zweiter Aktivitätsprüfung). Prüfung: cat $LOG"
