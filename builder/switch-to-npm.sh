#!/bin/sh
# Rückweg: LaunchAgent dev.openchamber.web wieder auf die npm-Installation
# (~/.bun/install/global/node_modules/@openchamber/web). Idempotent.
#
#   sh switch-to-npm.sh            # stellt Startskript wieder her, startet neu, prüft
#   FORCE=1 sh switch-to-npm.sh    # auch wenn gerade Sessions aktiv sind (im Notfall immer)
#   sh switch-to-npm.sh --check    # nur Aktivität melden (auch CHECK_ONLY=1), ändert nichts
#
# Aktivitätsregel: builder/lib/activity.sh (README.md).
#
# Wie beim Umschalten beendet der Neustart die verwaltete OpenCode-Instanz;
# deshalb laufen Neustart und Prüfung abgekoppelt (Phase --restart) nach $LOG.
set -eu

FORK_CLI="$HOME/Projects/openchamber-release/packages/web/bin/cli.js"
NPM_CLI="$HOME/.bun/install/global/node_modules/@openchamber/web/bin/cli.js"
START="$HOME/.config/openchamber/bin/OpenChamber"
BACKUP="$START.npm-2.2.0.bak"
SERVICE="gui/$(id -u)/dev.openchamber.web"
ERRLOG="$HOME/Library/Logs/OpenChamber/startup.err.log"
# Verzeichnis des Skripts (auch über Symlink aufgerufen), für lib/activity.sh
SELF="$0"
while [ -L "$SELF" ]; do
  LINK=$(readlink "$SELF")
  case "$LINK" in /*) SELF="$LINK" ;; *) SELF="$(dirname "$SELF")/$LINK" ;; esac
done
BUILDER_DIR=$(cd "$(dirname "$SELF")" && pwd)

say() { echo "[switch-to-npm] $*"; }
die() { echo "[switch-to-npm] FEHLER: $*" >&2; exit 1; }
runs() { ps -axo args= | awk -v p="$1" '$1 ~ /\/node$/ && $2 == p && $3 == "serve" {f=1} END {exit !f}'; }

if [ "${1:-}" = "--restart" ]; then
  ERR_LINES="${2:-0}"
  echo "Neustart $(date)"
  launchctl kickstart -k "$SERVICE"
  ok=0; i=0
  while [ $i -lt 60 ]; do
    i=$((i + 1))
    if [ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:3000/health)" = 200 ]; then ok=1; break; fi
    sleep 1
  done
  if [ $ok = 1 ]; then echo "OK: /health 200 nach ${i}s"; else echo "FEHLER: /health nach 60s nicht erreichbar"; fi
  if runs "$NPM_CLI"; then echo "OK: npm-Prozess läuft"; else echo "FEHLER: npm-Prozess nicht gefunden"; fi
  echo "--- neue Zeilen in startup.err.log:"
  tail -n +$((ERR_LINES + 1)) "$ERRLOG" 2>/dev/null | cut -c1-200 | tail -40
  echo "--- Ende"
  exit 0
fi

ACTIVITY_TAG="[switch-to-npm]"
. "$BUILDER_DIR/lib/activity.sh"

# Nur prüfen: meldet die Aktivität und endet (Exit 1 = aktiv), ändert nichts
if [ "${1:-}" = "--check" ] || [ "${CHECK_ONLY:-0}" = "1" ]; then
  if activity_check; then exit 0; fi
  exit 1
fi

[ -f "$NPM_CLI" ] || die "npm-Installation fehlt: $NPM_CLI"

if [ "${FORCE:-0}" != "1" ]; then
  activity_check || die "Aktivität erkannt (siehe oben). Später erneut oder FORCE=1."
else
  activity_check || say "FORCE=1: Aktivität ignoriert"
fi

# Startskript wiederherstellen: bevorzugt aus der Sicherung, sonst Pfad zurücktauschen
if grep -qF "$NPM_CLI" "$START" 2>/dev/null; then
  say "Startskript zeigt schon auf npm"
elif [ -f "$BACKUP" ] && grep -qF "$NPM_CLI" "$BACKUP"; then
  cp -p "$BACKUP" "$START.tmp.$$"
  mv "$START.tmp.$$" "$START"
  say "Startskript aus $BACKUP wiederhergestellt"
else
  TMP="$START.tmp.$$"
  sed "s|$FORK_CLI|$NPM_CLI|" "$START" > "$TMP"
  grep -qF "$NPM_CLI" "$TMP" || { rm -f "$TMP"; die "Wiederherstellung fehlgeschlagen, Startskript von Hand prüfen"; }
  chmod 700 "$TMP"
  mv "$TMP" "$START"
  say "Pfad im Startskript zurückgetauscht (keine Sicherung gefunden)"
fi

if runs "$NPM_CLI"; then
  say "npm-Version läuft bereits, kein Neustart nötig"
  exit 0
fi

LOG="${LOG:-/tmp/openchamber-switch-back-$(date +%Y%m%d-%H%M%S).log}"
ERR_LINES=$(wc -l < "$ERRLOG" 2>/dev/null | tr -d ' ' || echo 0)
nohup /bin/sh "$0" --restart "$ERR_LINES" > "$LOG" 2>&1 < /dev/null &
say "Neustart läuft abgekoppelt. Prüfung in ca. 20 s: cat $LOG"
