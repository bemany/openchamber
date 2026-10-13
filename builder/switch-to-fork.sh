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

CLI_SUFFIX="/packages/web/bin/cli.js"

# Ist $1 ein erlaubter Fork-Release-Pfad? $RELEASE_ROOT/openchamber-release<x>/packages/web/bin/cli.js,
# <x> nur aus [-A-Za-z0-9._] (kein /, also kein Ausbruch aus $RELEASE_ROOT).
fork_cli_ok() {
  case "$1" in "$RELEASE_ROOT/openchamber-release"*"$CLI_SUFFIX") ;; *) return 1 ;; esac
  _mid=${1#"$RELEASE_ROOT/openchamber-release"}
  _mid=${_mid%"$CLI_SUFFIX"}
  case "$_mid" in *[!-A-Za-z0-9._]*) return 1 ;; esac
}

# Alle Vorkommen von $2 (Literal) in Datei $1 als eigenes Wort (begrenzt durch
# Anfang/Ende, Leerzeichen, Tab oder Anführungszeichen), eine Zeile pro Treffer.
# $2 = "fork": stattdessen alle erlaubten Fork-Release-Pfade.
cli_tokens() {
  awk -v lit="$2" -v pre="$RELEASE_ROOT/openchamber-release" -v suf="$CLI_SUFFIX" '
    function bound(c) { return c == "" || c == " " || c == "\t" || c == "\"" || c == "\047" }
    {
      line = $0; off = 0
      while (1) {
        key = (lit == "fork") ? pre : lit
        i = index(line, key); if (i == 0) break
        before = (i > 1) ? substr(line, i - 1, 1) : ""
        rest = substr(line, i + length(key))
        if (lit == "fork") {
          j = index(rest, suf)
          if (j > 0) {
            mid = substr(rest, 1, j - 1)
            after = substr(rest, j + length(suf), 1)
            if (mid ~ /^[-A-Za-z0-9._]*$/ && bound(before) && bound(after)) print pre mid suf
          }
        } else if (bound(before) && bound(substr(rest, 1, 1))) print lit
        line = rest
      }
    }' "$1"
}

# Startskript auf $FORK_CLI umschreiben. Erlaubt nur, wenn es genau einen
# cli.js-Pfad enthält und der die npm-Version oder ein erlaubter Fork-Release-Pfad
# ist; alles andere bricht ohne Änderung ab. Vor einem Fork->Fork-Wechsel wird das
# bisherige Startskript als OpenChamber.fork-<alter-sha|zeitstempel>.bak gesichert.
# Atomar per Temp-Datei und mv (0700).
rewrite_start() {
  [ -f "$START" ] || die "$START fehlt"
  fork_cli_ok "$FORK_CLI" || die "$FORK_CLI ist kein erlaubter Fork-Release-Pfad ($RELEASE_ROOT/openchamber-release*$CLI_SUFFIX)"
  _all=$(grep -o 'cli\.js' "$START" | grep -c .) || _all=0
  _npm=$(cli_tokens "$START" "$NPM_CLI" | grep -c .) || _npm=0
  _forks=$(cli_tokens "$START" fork)
  _nf=$(printf '%s' "$_forks" | grep -c .) || _nf=0
  [ "$_all" = 1 ] || die "Startskript enthält $_all cli.js-Pfade statt genau einem; nicht geändert. Bitte prüfen."
  if [ "$_nf" = 1 ] && [ "$_forks" = "$FORK_CLI" ]; then
    say "Startskript zeigt schon auf den Fork ($FORK_CLI)"
    return 0
  fi
  if [ "$_npm" = 1 ] && [ "$_nf" = 0 ]; then
    _old=$NPM_CLI
  elif [ "$_nf" = 1 ] && [ "$_npm" = 0 ]; then
    _old=$_forks
    backup_fork "$_old"
  else
    die "Startskript zeigt weder auf die npm-Version noch auf einen erlaubten Fork-Release-Pfad; nicht geändert. Bitte prüfen."
  fi
  awk -v old="$_old" -v new="$FORK_CLI" '
    !done && (i = index($0, old)) > 0 { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); done = 1 }
    { print }' "$START" > "$TMP"
  [ "$(cli_tokens "$TMP" "$FORK_CLI" | grep -c .)" = 1 ] && [ "$(grep -o 'cli\.js' "$TMP" | grep -c .)" = 1 ] ||
    die "Pfadersetzung fehlgeschlagen"
  chmod 700 "$TMP"
  mv "$TMP" "$START"
  say "Startskript umgestellt: $_old -> $FORK_CLI"
}

# Sicherung des Startskripts vor einem Fork->Fork-Wechsel. Name mit dem Commit des
# alten Release-Worktrees (12 Stellen), sonst Zeitstempel; nie überschreiben.
backup_fork() {
  _rel=${1%"$CLI_SUFFIX"}
  _full=$(git -C "$_rel" rev-parse HEAD 2>/dev/null) || _full=
  case "$_full" in '' | *[!0-9a-f]*) _full=; _sha=$(date +%Y%m%d-%H%M%S) ;; *) _sha=$(printf '%.12s' "$_full") ;; esac
  _fb="$START.fork-$_sha.bak"
  if [ -e "$_fb" ]; then
    if cmp -s "$START" "$_fb"; then
      say "Fork-Sicherung vorhanden: $_fb"
      return 0
    fi
    _fb="$START.fork-$_sha-$(date +%Y%m%d-%H%M%S).bak"
    [ ! -e "$_fb" ] || die "Fork-Sicherung $_fb existiert schon"
  fi
  cp -p "$START" "$_fb" || die "Fork-Sicherung $_fb fehlgeschlagen"
  say "Fork-Sicherung angelegt: $_fb (Rückweg: SWITCH_RELEASE=$_rel EXPECTED_COMMIT=${_full:-<alter Commit>} sh switch-to-fork.sh)"
}

# Sicherung (nur einmal, und nur wenn sie wirklich die npm-Version enthält)
ensure_backup() {
  if [ ! -f "$BACKUP" ]; then
    [ -z "$(cli_tokens "$START" fork)" ] || { say "Startskript zeigt schon auf einen Fork, keine npm-Sicherung nötig"; return 0; }
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
fork_cli_ok "$FORK_CLI" || die "$FORK_CLI ist kein erlaubter Fork-Release-Pfad ($RELEASE_ROOT/openchamber-release*$CLI_SUFFIX)"
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
