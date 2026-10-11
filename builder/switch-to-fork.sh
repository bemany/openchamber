#!/bin/sh
# Schaltet den LaunchAgent dev.openchamber.web von der npm-Version auf den Fork
# im Release-Worktree um. Idempotent: zweimal ausführen schadet nicht.
#
#   sh switch-to-fork.sh            # prüft, sichert, schaltet um, prüft
#   FORCE=1 sh switch-to-fork.sh    # auch wenn gerade Sessions aktiv sind
#   sh switch-to-fork.sh --check    # nur Aktivität melden (auch CHECK_ONLY=1), ändert nichts
#
# Aktivitätsregel: builder/lib/activity.sh (README.md).
#
# ACHTUNG: Der Neustart beendet auch die von OpenChamber gestartete OpenCode-
# Instanz. Laufende Agent-Züge brechen ab, auch der Zug, der dieses Skript
# eventuell aufruft. Deshalb laufen zweite Aktivitätsprüfung, Umschreiben des
# Startskripts, Neustart und Prüfung abgekoppelt per nohup (interne Phase
# --restart, nur mit Token) und schreiben nach $LOG.
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
# Verzeichnis des Skripts (auch über Symlink aufgerufen), für lib/activity.sh
SELF="$0"
while [ -L "$SELF" ]; do
  LINK=$(readlink "$SELF")
  case "$LINK" in /*) SELF="$LINK" ;; *) SELF="$(dirname "$SELF")/$LINK" ;; esac
done
BUILDER_DIR=$(cd "$(dirname "$SELF")" && pwd)

say() { echo "[switch-to-fork] $*"; }
die() { echo "[switch-to-fork] FEHLER: $*" >&2; exit 1; }
# Läuft "<…>/node <cli> serve …"? (pgrep sieht den LaunchAgent-Prozess nicht zuverlässig)
runs() { ps -axo args= | awk -v p="$1" '$1 ~ /\/node$/ && $2 == p && $3 == "serve" {f=1} END {exit !f}'; }

ACTIVITY_TAG="[switch-to-fork]"
. "$BUILDER_DIR/lib/activity.sh"

# Nur prüfen: vor jedem anderen Zweig, endet immer ohne Seiteneffekte (Exit 1 = aktiv)
for a in "$@"; do case "$a" in --check) CHECK_ONLY=1 ;; esac; done
if [ "${CHECK_ONLY:-0}" = "1" ]; then
  if activity_check; then exit 0; fi
  exit 1
fi

# Startskript auf den Fork umschreiben (nur der cli.js-Pfad), atomar per mv
rewrite_start() {
  if grep -qF "$FORK_CLI" "$START"; then
    say "Startskript zeigt schon auf den Fork"
    return 0
  fi
  TMP="$START.tmp.$$"
  sed "s|$NPM_CLI|$FORK_CLI|" "$START" > "$TMP"
  grep -qF "$FORK_CLI" "$TMP" || { rm -f "$TMP"; die "Pfadersetzung fehlgeschlagen"; }
  chmod 700 "$TMP"
  mv "$TMP" "$START"
  say "Startskript umgestellt"
}

# Interne Phase (abgekoppelt): zweite Prüfung, Umschreiben, Neustart, Prüfung.
# Nur erreichbar mit dem Token, das Phase 1 beim nohup-Aufruf setzt.
if [ "${1:-}" = "--restart" ]; then
  [ -n "${SWITCH_RESTART_TOKEN:-}" ] && [ "${SWITCH_RESTART_TOKEN}" = "${3:-}" ] ||
    die "--restart ist eine interne Phase und nicht direkt aufrufbar"
  ERR_LINES="${2:-0}"
  echo "Zweite Aktivitätsprüfung $(date)"
  if ! activity_check; then
    if [ "${FORCE:-0}" = "1" ]; then
      say "FORCE=1: Aktivität ignoriert"
    else
      die "Aktivität seit der ersten Prüfung: kein Neustart, Startskript unverändert. Später erneut oder FORCE=1."
    fi
  fi
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

# 2. Aktivität (Sessions, Build-/Simulator-Prozesse): Neustart würde sie abbrechen
if [ "${FORCE:-0}" != "1" ]; then
  activity_check || die "Aktivität erkannt (siehe oben). Neustart würde laufende Züge abbrechen. Später erneut oder FORCE=1."
else
  activity_check || say "FORCE=1: Aktivität ignoriert"
fi

# 3. Sicherung (nur einmal, und nur wenn sie wirklich die npm-Version enthält)
if [ ! -f "$BACKUP" ]; then
  grep -qF "$NPM_CLI" "$START" || die "$START zeigt nicht auf die npm-Version, Sicherung wäre falsch. Bitte prüfen."
  cp -p "$START" "$BACKUP"
  say "Sicherung angelegt: $BACKUP"
else
  grep -qF "$NPM_CLI" "$BACKUP" || die "$BACKUP enthält nicht den npm-Pfad"
  say "Sicherung vorhanden: $BACKUP"
fi

# 4. Läuft der Fork schon? Dann nur das Startskript angleichen, kein Neustart.
if runs "$FORK_CLI"; then
  rewrite_start
  say "Fork läuft bereits, kein Neustart nötig"
  exit 0
fi

# 5. Zweite Prüfung, Umschreiben, Neustart + Prüfung abgekoppelt (überlebt den
#    Abbruch des aufrufenden Zugs). Das Startskript ändert sich erst dort.
LOG="${LOG:-/tmp/openchamber-switch-$(date +%Y%m%d-%H%M%S).log}"
ERR_LINES=$(wc -l < "$ERRLOG" 2>/dev/null | tr -d ' ' || echo 0)
TOKEN=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
SWITCH_RESTART_TOKEN="$TOKEN" FORCE="${FORCE:-0}" nohup /bin/sh "$0" --restart "$ERR_LINES" "$TOKEN" > "$LOG" 2>&1 < /dev/null &
say "Neustart läuft abgekoppelt (mit zweiter Aktivitätsprüfung). Prüfung in ca. 20 s: cat $LOG"
