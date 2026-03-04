# nod-exec: TCP command server for Nix-on-Droid.
#
# Runs inside NOD (under proot) and accepts TCP connections from
# external apps (Tasker, KWGT, custom APKs) on localhost.
# Executes commands in the full NOD/Nix environment and returns output.
#
# Protocol:
#   1. Client connects via TCP, sends one line: the shell command
#   2. Server prints sentinel: __NOD_EXEC_READY__
#   3. Server execs the command; all subsequent output is from the command
#   4. Connection closes when command exits
#
# Ports:
#   - Base port (default 18357): pipe mode for one-shot commands
#   - Base port + 1 (default 18358): PTY mode for interactive shells
{
  pkgs,
  port ? "18357",
  host ? "127.0.0.1",
  ...
}:

let
  defaultPort = port;
  defaultHost = host;

  # Shared environment setup sourced by both handlers
  envSetup = ''
    # Reset environment to match a fresh NOD login shell.
    # supervisord passes a minimal PATH; we need the full user env.
    export HOME="''${HOME:-/home/nix-on-droid}"
    export USER="''${USER:-nix-on-droid}"
    cd "$HOME" 2>/dev/null || true

    # Clear supervisor's PATH and session-init guard so we get a fresh setup
    unset PATH
    unset __NOD_SESS_INIT_SOURCED
    unset __ETC_PROFILE_SOURCED
    unset __NIXOS_SET_ENVIRONMENT_DONE

    # Source session init to rebuild PATH with all nix profile bins
    if [ -f "$HOME/.nix-profile/etc/profile.d/nix-on-droid-session-init.sh" ]; then
      . "$HOME/.nix-profile/etc/profile.d/nix-on-droid-session-init.sh"
    elif [ -f /etc/profile ]; then
      . /etc/profile
    fi
  '';

  nod-exec-handler = pkgs.writeScript "nod-exec-handler" ''
    #!${pkgs.bash}/bin/bash
    IFS= read -r CMD_LINE 2>/dev/null || exit 1
    [ -z "$CMD_LINE" ] && exit 1
    ${envSetup}
    printf '%s\n' "__NOD_EXEC_READY__"
    exec ${pkgs.bash}/bin/bash -c "$CMD_LINE"
  '';

  nod-exec-handler-pty = pkgs.writeScript "nod-exec-handler-pty" ''
    #!${pkgs.bash}/bin/bash
    IFS= read -r CMD_LINE 2>/dev/null || exit 1
    [ -z "$CMD_LINE" ] && exit 1
    ${envSetup}
    stty sane 2>/dev/null || true
    printf '%s\n' "__NOD_EXEC_READY__"
    exec ${pkgs.bash}/bin/bash -c "$CMD_LINE"
  '';

  nod-exec-server = pkgs.writeScriptBin "nod-exec-server" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    PORT="''${NOD_EXEC_PORT:-${defaultPort}}"
    PTY_PORT=$((PORT + 1))
    HOST="''${NOD_EXEC_HOST:-${defaultHost}}"
    PIDFILE="''${NOD_EXEC_PIDFILE:-/tmp/run/nod-exec-server.pid}"

    cleanup() {
      kill "$PTY_PID" 2>/dev/null || true
      rm -f "$PIDFILE"
    }
    trap cleanup EXIT

    mkdir -p "$(dirname "$PIDFILE")"
    echo $$ > "$PIDFILE"

    echo "nod-exec-server: pipe on $HOST:$PORT, pty on $HOST:$PTY_PORT" >&2

    # PTY listener for interactive sessions (shells, TUIs)
    ${pkgs.socat}/bin/socat \
      TCP-LISTEN:"$PTY_PORT",bind="$HOST",reuseaddr,fork \
      EXEC:"${nod-exec-handler-pty}",pty,setsid,ctty,stderr,echo=0 &
    PTY_PID=$!

    # Pipe listener for one-shot commands (Tasker, KWGT)
    exec ${pkgs.socat}/bin/socat \
      TCP-LISTEN:"$PORT",bind="$HOST",reuseaddr,fork \
      EXEC:"${nod-exec-handler}",stderr
  '';

  nod-exec-client = pkgs.writeScriptBin "nod-exec" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    PORT="''${NOD_EXEC_PORT:-${defaultPort}}"
    HOST="''${NOD_EXEC_HOST:-${defaultHost}}"
    SENTINEL="__NOD_EXEC_READY__"

    if [ $# -eq 0 ]; then
      echo "Usage: nod-exec <command> [args...]" >&2
      echo "" >&2
      echo "Run a command in Nix-on-Droid via the nod-exec-server." >&2
      echo "Server must be running (managed by supervisord)." >&2
      exit 1
    fi

    # Check connectivity
    if ! (echo >/dev/tcp/"$HOST"/"$PORT") 2>/dev/null; then
      echo "nod-exec: cannot connect to server at $HOST:$PORT" >&2
      exit 1
    fi

    CMD="$(printf '%q ' "$@")"

    if [ -t 0 ] && [ -t 1 ]; then
      # Interactive mode
      ORIG_STTY="$(stty -g)"
      stty raw -echo icrnl
      cleanup() { stty "$ORIG_STTY" 2>/dev/null || true; }
      trap cleanup EXIT

      exec 4<>/dev/tcp/"$HOST"/"$PORT"
      printf '%s\n' "$CMD" >&4

      BUF=""
      NL="$(printf '\n')" CR="$(printf '\r')"
      while IFS= read -r -n1 -d "" CH <&4 || [ -n "$CH" ]; do
        if [ "$CH" = "$NL" ] || [ "$CH" = "$CR" ]; then
          BUF="''${BUF%"$CR"}"
          if [ "$BUF" = "$SENTINEL" ]; then break; fi
          BUF=""
        else
          BUF="$BUF$CH"
        fi
      done

      cat <&0 >&4 &
      BG=$!
      trap "kill $BG 2>/dev/null || true; exec 4>&-; stty '$ORIG_STTY' 2>/dev/null || true" EXIT
      cat <&4
    else
      # Piped mode
      exec 4<>/dev/tcp/"$HOST"/"$PORT"
      printf '%s\n' "$CMD" >&4

      CR="$(printf '\r')"
      while IFS= read -r LINE <&4; do
        LINE="''${LINE%"$CR"}"
        if [ "$LINE" = "$SENTINEL" ]; then break; fi
      done

      cat <&0 >&4 &
      BG=$!
      trap "kill $BG 2>/dev/null || true; exec 4>&-" EXIT
      cat <&4
    fi
  '';

  nod-exec-nc = pkgs.writeScriptBin "nod-exec-nc" ''
    #!${pkgs.bash}/bin/bash
    PORT="''${NOD_EXEC_PORT:-${defaultPort}}"
    HOST="''${NOD_EXEC_HOST:-${defaultHost}}"

    if [ $# -eq 0 ]; then
      echo "Usage: nod-exec-nc <command> [args...]" >&2
      exit 1
    fi

    CMD="$(printf '%q ' "$@")"
    printf '%s\n' "$CMD" | ${pkgs.netcat-gnu}/bin/nc -q5 "$HOST" "$PORT" 2>/dev/null \
      | sed -n '/__NOD_EXEC_READY__/,$p' | tail -n +2
  '';

  nod-exec-android = pkgs.writeText "nod-exec-android.sh" ''
    #!/system/bin/sh
    PORT="''${NOD_EXEC_PORT:-${defaultPort}}"
    HOST="''${NOD_EXEC_HOST:-${defaultHost}}"

    CMD="$*"
    if [ -z "$CMD" ]; then
      echo "Usage: nod-exec-android <command>" >&2
      exit 1
    fi

    if command -v nc >/dev/null 2>&1; then
      NC="nc"
    elif command -v netcat >/dev/null 2>&1; then
      NC="netcat"
    elif [ -x /data/data/com.termux/files/usr/bin/nc ]; then
      NC="/data/data/com.termux/files/usr/bin/nc"
    else
      echo "nod-exec-android: nc/netcat not found" >&2
      exit 1
    fi

    printf '%s\n' "$CMD" | $NC -w5 "$HOST" "$PORT" 2>/dev/null | {
      READY=0
      while IFS= read -r LINE; do
        case "$LINE" in
          *__NOD_EXEC_READY__*) READY=1; continue ;;
        esac
        if [ "$READY" -eq 1 ]; then
          printf '%s\n' "$LINE"
        fi
      done
    }
  '';

in {
  inherit nod-exec-server nod-exec-client nod-exec-nc nod-exec-handler nod-exec-handler-pty nod-exec-android;
  server = nod-exec-server;
  client = nod-exec-client;
  nc = nod-exec-nc;
  android = nod-exec-android;
}
