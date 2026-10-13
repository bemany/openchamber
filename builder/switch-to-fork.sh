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

# Erlaubte Fork-Release-Worktrees: $RELEASE_ROOT/openchamber-release[-A-Za-z0-9._]*
RELEASE_ROOT="${SWITCH_RELEASE_ROOT:-$HOME/Projects}"
RELEASE="${SWITCH_RELEASE:-$RELEASE_ROOT/openchamber-release}"
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
. "$BUILDER_DIR/lib/startscript.sh"
runs() { activity_runs_cli "$1"; }

# Nur prüfen: vor jedem anderen Zweig, endet immer ohne Seiteneffekte (Exit 1 = aktiv)
for a in "$@"; do case "$a" in --check) CHECK_ONLY=1 ;; --dry-run) DRY_RUN=1 ;; esac; done
if [ "${CHECK_ONLY:-0}" = "1" ]; then
  if activity_check; then exit 0; fi
  exit 1
fi

# Temp-Datei für das Startskript; Trap erst nach --check und nicht bei --dry-run,
# damit beide nichts anfassen
TMP="$START.tmp.$$"
[ "${DRY_RUN:-0}" = "1" ] || trap 'rm -f "$TMP"' EXIT

# Startskript auf $FORK_CLI umschreiben. Erlaubt nur in der strengen Form aus
# lib/startscript.sh, deren cli.js-Argument die npm-Version oder ein erlaubter
# Fork-Release-Pfad ist; alles andere bricht ohne Änderung ab. Vor einem
# Fork->Fork-Wechsel wird das bisherige Startskript als
# OpenChamber.fork-<alter-sha12|zeitstempel>.bak gesichert, erst nachdem die
# neue Fassung fertig und geprüft in der Temp-Datei liegt. Atomar per mv (0700).
rewrite_start() {
  fork_cli_ok "$FORK_CLI" || die "$FORK_CLI ist kein erlaubter Fork-Release-Pfad ($RELEASE_ROOT/openchamber-release*$CLI_SUFFIX)"
  _old=$(start_cli "$START") || die "$_old; nicht geändert. Bitte prüfen."
  if [ "$_old" = "$FORK_CLI" ]; then
    say "Startskript zeigt schon auf den Fork ($FORK_CLI)"
    return 0
  fi
  (umask 077 && start_rewrite "$START" "$FORK_CLI" > "$TMP") || die "Pfadersetzung fehlgeschlagen"
  _why=$(start_rewrite_check "$START" "$TMP" "$FORK_CLI") || die "Pfadersetzung nicht verlustfrei ($_why); nicht geändert."
  _new=$(start_cli "$TMP") && [ "$_new" = "$FORK_CLI" ] || die "Pfadersetzung fehlgeschlagen"
  chmod 700 "$TMP"
  [ "$_old" = "$NPM_CLI" ] || backup_fork "$_old"
  mv "$TMP" "$START"
  say "Startskript umgestellt: $_old -> $FORK_CLI"
}

# Vorhandene Sicherung nur wiederverwenden, wenn sie privat ist (reguläre Datei,
# eigene, Gruppe/Welt ohne Rechte); sonst Abbruch, nicht still korrigieren.
backup_reusable() {
  private_file_ok "$1" || die "Sicherung $1 ist kein privates reguläres eigenes File (Symlink, fremd oder Rechte für Gruppe/Welt). Bitte prüfen."
}

# Sicherung des Startskripts vor einem Fork->Fork-Wechsel. Name mit dem Commit des
# alten Release-Worktrees (12 Stellen), sonst Zeitstempel; nie überschreiben.
backup_fork() {
  _rel=${1%"$CLI_SUFFIX"}
  _full=$(git -C "$_rel" rev-parse HEAD 2>/dev/null) || _full=
  case "$_full" in '' | *[!0-9a-f]*) _full=; _sha=$(date +%Y%m%d-%H%M%S) ;; *) _sha=$(printf '%.12s' "$_full") ;; esac
  _fb="$START.fork-$_sha.bak"
  if [ -e "$_fb" ] || [ -L "$_fb" ]; then
    backup_reusable "$_fb"
    if cmp -s "$START" "$_fb"; then
      say "Fork-Sicherung vorhanden: $_fb"
      return 0
    fi
    _fb="$START.fork-$_sha-$(date +%Y%m%d-%H%M%S).bak"
    [ ! -e "$_fb" ] && [ ! -L "$_fb" ] || die "Fork-Sicherung $_fb existiert schon"
  fi
  (umask 077 && cp "$START" "$_fb") || die "Fork-Sicherung $_fb fehlgeschlagen"
  say "Fork-Sicherung angelegt: $_fb (Rückweg: SWITCH_RELEASE=$_rel EXPECTED_COMMIT=${_full:-<alter Commit>} sh switch-to-fork.sh)"
}

# npm-Sicherung (nur einmal, und nur wenn sie wirklich die npm-Version enthält)
ensure_backup() {
  _cur=$(start_cli "$START") || die "$_cur"
  if [ ! -e "$BACKUP" ] && [ ! -L "$BACKUP" ]; then
    if fork_cli_ok "$_cur"; then
      say "Startskript zeigt schon auf einen Fork, keine npm-Sicherung nötig"
      return 0
    fi
    (umask 077 && cp "$START" "$BACKUP") || die "Sicherung $BACKUP fehlgeschlagen"
    say "Sicherung angelegt: $BACKUP"
  else
    backup_reusable "$BACKUP"
    _b=$(start_cli "$BACKUP") && [ "$_b" = "$NPM_CLI" ] || die "$BACKUP enthält nicht die npm-Version"
    say "Sicherung vorhanden: $BACKUP"
  fi
}

# Release-Worktree: erlaubter Pfad, gebaut, auf EXPECTED_COMMIT, sauber (Phase 1 und 2)
check_release() {
  fork_cli_ok "$FORK_CLI" || die "$FORK_CLI ist kein erlaubter Fork-Release-Pfad ($RELEASE_ROOT/openchamber-release*$CLI_SUFFIX)"
  [ -f "$FORK_CLI" ] || die "$FORK_CLI fehlt"
  [ -f "$RELEASE/packages/web/dist/index.html" ] || die "dist fehlt, erst 'bun run build:web' im Release-Worktree"
  [ -d "$RELEASE/node_modules" ] || die "node_modules fehlt, erst 'bun install' im Release-Worktree"
  HEAD=$(git -C "$RELEASE" rev-parse HEAD) || die "Release-Worktree $RELEASE ist kein Git-Worktree"
  [ "$HEAD" = "$EXPECTED_COMMIT" ] || die "Release-Worktree steht auf $HEAD, erwartet $EXPECTED_COMMIT (EXPECTED_COMMIT=… setzen, wenn gewollt)"
  # --no-optional-locks: status schreibt den Index nicht (Phase 1 und --dry-run bleiben lesend)
  _st=$(git --no-optional-locks -C "$RELEASE" status --porcelain --untracked-files=no) || die "git status im Release-Worktree fehlgeschlagen"
  [ -z "$_st" ] || die "Release-Worktree hat lokale Änderungen"
}

# --dry-run: Phase 1 komplett lesend, meldet was passieren würde. Schreibt nichts,
# startet keine Phase 2. Exit 0 = würde umschalten (oder nichts zu tun), 1 = blockiert/Fehler.
dry() { echo "[switch-to-fork] [dry-run] $*"; }
dry_run() {
  dry "Ziel: $FORK_CLI (EXPECTED_COMMIT=$EXPECTED_COMMIT)"
  check_release
  dry "OK  Release-Worktree: erlaubter Pfad, dist und node_modules vorhanden, HEAD = EXPECTED_COMMIT, sauber"
  _cur=$(start_cli "$START") || die "$_cur"
  dry "OK  Startskript in strenger Form, cli.js = $_cur"
  if [ "$_cur" != "$FORK_CLI" ]; then
    _why=$(start_rewrite "$START" "$FORK_CLI" | start_rewrite_check "$START" - "$FORK_CLI") ||
      die "Umschreiben wäre nicht verlustfrei ($_why)"
    dry "OK  Umschreiben verlustfrei: $_cur -> $FORK_CLI"
  else
    dry "OK  Startskript zeigt schon auf das Ziel, würde nicht umgeschrieben"
  fi
  # npm-Sicherung
  if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
    private_file_ok "$BACKUP" || die "Sicherung $BACKUP ist kein privates reguläres eigenes File (Symlink, fremd oder Rechte für Gruppe/Welt)"
    _b=$(start_cli "$BACKUP") && [ "$_b" = "$NPM_CLI" ] || die "$BACKUP enthält nicht die npm-Version"
    dry "OK  npm-Sicherung vorhanden und privat: $BACKUP"
  elif fork_cli_ok "$_cur"; then
    dry "--  keine npm-Sicherung, Startskript zeigt schon auf einen Fork (würde keine anlegen)"
  else
    dry "würde npm-Sicherung anlegen: $BACKUP"
  fi
  # Fork-Sicherung bei Fork->Fork
  if [ "$_cur" != "$FORK_CLI" ] && [ "$_cur" != "$NPM_CLI" ]; then
    _rel=${_cur%"$CLI_SUFFIX"}
    _full=$(git -C "$_rel" rev-parse HEAD 2>/dev/null) || _full=
    case "$_full" in '' | *[!0123456789abcdef]*) _fb="$START.fork-<zeitstempel>.bak" ;; *) _fb="$START.fork-$(printf '%.12s' "$_full").bak" ;; esac
    if [ -e "$_fb" ] || [ -L "$_fb" ]; then
      private_file_ok "$_fb" || die "Fork-Sicherung $_fb ist kein privates reguläres eigenes File"
      if cmp -s "$START" "$_fb"; then dry "OK  Fork-Sicherung vorhanden: $_fb"; else dry "würde Fork-Sicherung daneben anlegen: $_fb-<zeitstempel> (vorhandene unterscheidet sich)"; fi
    else
      dry "würde Fork-Sicherung anlegen: $_fb (Rückweg: SWITCH_RELEASE=$_rel EXPECTED_COMMIT=${_full:-<alter Commit>})"
    fi
  fi
  if runs "$FORK_CLI"; then
    dry "Ziel läuft bereits: würde nur das Startskript angleichen, kein Neustart"
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
  dry "Ergebnis: würde umschalten ($_cur -> $FORK_CLI) und OpenChamber neu starten. Nichts geändert."
  exit 0
}
if [ "${DRY_RUN:-0}" = "1" ]; then
  dry_run
fi

# Interne Phase (abgekoppelt): Nachweis verbrauchen, warten/zweite Prüfung,
# Startskript umschreiben, Neustart, Prüfung.
if [ "${1:-}" = "--restart" ]; then
  phase_proof_claim
  ERR_LINES="${2:-0}"
  check_release
  _cur=$(start_cli "$START") || die "$_cur; kein Neustart."
  phase_gate
  check_release
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

# 1. Release-Worktree und Startskript (strenge Form, nur lesend) prüfen
check_release
_cur=$(start_cli "$START") || die "$_cur; nichts geändert."

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
