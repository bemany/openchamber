# Strenger Parser für das OpenChamber-Startskript (~/.config/openchamber/bin/OpenChamber).
# POSIX sh, per `. lib/startscript.sh` geladen. Erwartet RELEASE_ROOT und NPM_CLI.
#
# Erlaubt ist genau diese Form (zwei Zeilen, nichts sonst):
#   #!/bin/sh
#   exec '<node-pfad>' '<cli.js-pfad>' 'serve' …
# Alle Argumente einfach gequotet, ohne eingebettetes ', durch genau ein Leerzeichen
# getrennt, nichts nach dem letzten Quote. Das zweite Argument muss exakt NPM_CLI
# oder ein erlaubter Fork-Release-Pfad sein (fork_cli_ok).
#
#   start_cli <datei>              # gibt das cli.js-Argument aus; sonst Grund, Exit 1
#   start_rewrite <datei> <neu>    # gibt das Startskript mit ersetztem cli.js-Argument aus
#   fork_cli_ok <pfad>             # erlaubter Fork-Release-Pfad?
#   private_file_ok <pfad>         # reguläre Datei, eigene, Gruppe/Welt ohne Rechte?

CLI_SUFFIX="/packages/web/bin/cli.js"

# $RELEASE_ROOT/openchamber-release<x>/packages/web/bin/cli.js, <x> nur aus
# [-A-Za-z0-9._] (kein /, also kein Ausbruch aus $RELEASE_ROOT).
fork_cli_ok() {
  case "$1" in "$RELEASE_ROOT/openchamber-release"*"$CLI_SUFFIX") ;; *) return 1 ;; esac
  _mid=${1#"$RELEASE_ROOT/openchamber-release"}
  _mid=${_mid%"$CLI_SUFFIX"}
  case "$_mid" in *[!-A-Za-z0-9._]*) return 1 ;; esac
}

# Argumente der exec-Zeile, eines pro Zeile; Exit 1 bei falscher Form
start_args() {
  [ -f "$1" ] && [ ! -L "$1" ] || { echo "$1 fehlt oder ist keine reguläre Datei"; return 1; }
  awk '
    NR == 1 { if ($0 != "#!/bin/sh") { bad = "Zeile 1 ist nicht #!/bin/sh"; exit } next }
    NR == 2 { line = $0; next }
    { bad = "mehr als zwei Zeilen"; exit }
    END {
      if (bad == "" && NR < 2) bad = "keine exec-Zeile"
      if (bad == "" && line !~ /^exec( \047[^\047]*\047)+$/) bad = "exec-Zeile hat nicht die Form exec \047…\047 \047…\047 …"
      if (bad != "") { print bad; exit 1 }
      rest = substr(line, 7, length(line) - 7)
      n = split(rest, a, "\047 \047")
      for (i = 1; i <= n; i++) print a[i]
    }' "$1"
}

start_cli() {
  _args=$(start_args "$1") || { echo "Startskript $1: $_args"; return 1; }
  _n=$(printf '%s\n' "$_args" | grep -c '')
  _node=$(printf '%s\n' "$_args" | sed -n 1p)
  _cli=$(printf '%s\n' "$_args" | sed -n 2p)
  _cmd=$(printf '%s\n' "$_args" | sed -n 3p)
  [ "$_n" -ge 3 ] && [ "$_cmd" = serve ] || { echo "Startskript $1: erwartet exec '<node>' '<cli.js>' 'serve' …"; return 1; }
  case "$_node" in /*) ;; *) echo "Startskript $1: Node-Pfad nicht absolut"; return 1 ;; esac
  if [ "$_cli" = "$NPM_CLI" ] || fork_cli_ok "$_cli"; then
    printf '%s\n' "$_cli"
    return 0
  fi
  echo "Startskript $1: cli.js-Pfad ist weder die npm-Version noch ein erlaubter Fork-Release-Pfad"
  return 1
}

# Nur das zweite Argument ersetzen; $2 darf kein ' enthalten
start_rewrite() {
  case "$2" in *\'*) return 1 ;; esac
  _args=$(start_args "$1") || return 1
  printf '#!/bin/sh\n'
  printf '%s\n' "$_args" | awk -v new="$2" '
    { printf "%s\047%s\047", (NR == 1 ? "exec " : " "), (NR == 2 ? new : $0) }
    END { printf "\n" }'
}

private_file_ok() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && [ "$(ls -l "$1" | cut -c5-10)" = "------" ]
}
