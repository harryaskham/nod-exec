# nod-exec

TCP command server for [Nix-on-Droid](https://github.com/nix-community/nix-on-droid). Run Nix commands from Termux, Tasker, KWGT, or any app that can open a TCP socket.

## How it works

```
┌─────────────────────┐     TCP :18357     ┌──────────────────────┐
│  Termux / Tasker /   │ ◄────────────────► │  nod-exec-server     │
│  KWGT / custom app   │   send command     │  (inside NOD proot)  │
└─────────────────────┘   get output        └──────────────────────┘
```

**Protocol:**
1. Client connects to `127.0.0.1:18357`
2. Sends one line: the shell command to run
3. Server prints `__NOD_EXEC_READY__` sentinel
4. All subsequent output is from the command
5. Connection closes when command exits

## Install

```bash
# Run the server
nix run github:harryaskham/nod-exec

# Run a command via the client
nix run github:harryaskham/nod-exec#client -- echo hello

# Or add to your flake
{
  inputs.nod-exec.url = "github:harryaskham/nod-exec";
}
```

## Packages

| Package | Binary | Description |
|---------|--------|-------------|
| `server` | `nod-exec-server` | Socat-based TCP listener, runs inside NOD |
| `client` | `nod-exec` | Bash client with interactive + piped modes |
| `nc` | `nod-exec-nc` | Minimal netcat client for scripts |
| `android` | `nod-exec-android.sh` | Portable shell script for Tasker/KWGT |

## Usage from Termux

```bash
# Define a function (or add to .bashrc)
nod-exec() {
  echo "$(printf '%q ' "$@")" | nc -q5 127.0.0.1 18357 | \
    sed -n '/__NOD_EXEC_READY__/,$p' | tail -n +2
}

# Run commands in the full Nix environment
nod-exec echo hello
nod-exec which nix
nod-exec supervisorctl status
```

## Usage from KWGT

```
$sh("echo 'uptime' | nc -q5 127.0.0.1 18357 | sed -n '/__NOD_EXEC_READY__/,$p' | tail -n +2")$
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NOD_EXEC_PORT` | `18357` | TCP port |
| `NOD_EXEC_HOST` | `127.0.0.1` | Bind address |

## License

MIT
