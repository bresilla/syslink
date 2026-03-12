# syslink - SSH/QUIC CLI

`syslink` is the command-line interface for liblink. It provides remote shell access, command execution, and file transfer over the SSH/QUIC protocol.

## Installation

```bash
zig build
# binary at zig-out/bin/syslink
```

## Server

### Start

```bash
# Generate a persistent host key (one-time)
ssh-keygen -t ed25519 -f ~/.ssh/syslink_host_key -N ""

# Start server
syslink server start -k ~/.ssh/syslink_host_key

# Listen on specific address/port
syslink server start -k ~/.ssh/syslink_host_key --host 0.0.0.0 --port 2222

# Run as daemon
syslink server start -k ~/.ssh/syslink_host_key --daemon
```

If `-k` is not specified, the server generates an ephemeral host key on each start. This means clients will see a fingerprint mismatch after every restart. Use a persistent key file for production.

### Stop / Status

```bash
syslink server stop
syslink server status
```

### Authentication

The server authenticates clients using system users, identical to OpenSSH:

- Validates username against `/etc/passwd`
- Checks the client's public key against `~/.ssh/authorized_keys`
- Requires the server to run as root (to access user accounts and spawn shells)

To authorize a client:
```bash
# On the client machine
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 2222 user@server

# Or manually on the server
cat client_key.pub >> /home/user/.ssh/authorized_keys
```

## Client

### Remote Shell

```bash
syslink shell user@host:2222
syslink shell -i ~/.ssh/id_ed25519 user@host:2222
```

### Remote Command Execution

```bash
syslink exec user@host "ls -la"
syslink exec -i ~/.ssh/id_ed25519 user@host:2222 "uname -a"
```

### SFTP File Transfer

```bash
syslink sftp user@host:2222
```

Interactive SFTP commands:

| Command | Description |
|---------|-------------|
| `ls [path]` | List directory contents |
| `cd <path>` | Change remote directory |
| `pwd` | Print remote working directory |
| `get <remote> [local]` | Download file |
| `put <local> [remote]` | Upload file |
| `mkdir <path>` | Create remote directory |
| `rm <path>` | Remove remote file |
| `help` | Show available commands |
| `exit` | Close session |

## Options

### Server Options

| Flag | Description | Default |
|------|-------------|---------|
| `-k, --host-key <file>` | Server host key file | ephemeral |
| `-h, --host <addr>` | Listen address | `0.0.0.0` |
| `-p, --port <port>` | Listen port | `2222` |
| `-d, --daemon` | Run in background | foreground |

### Client Options

| Flag | Description | Default |
|------|-------------|---------|
| `-i, --identity <file>` | Private key for authentication | none |
| `-P, --port <port>` | Server port | `2222` |
| `--accept-new-host-key` | Trust unknown hosts on first use | enabled |
| `--replace-trusted-host` | Replace the stored host key for this host | disabled |
| `--strict-host-key` | Reject unknown hosts | disabled |

## Host Key Verification

On first connection, the client saves the server's fingerprint to `~/.ssh/known_hosts`. Subsequent connections verify the fingerprint matches. If the server's host key changes (e.g., reinstall), delete the old entry, use `--replace-trusted-host`, or use a persistent host key on the server.

## Connection String Format

```
[user@]host[:port]
```

- Default user: `root`
- Default port: `2222`

Examples:
```bash
syslink shell host                  # root@host:2222
syslink shell user@host             # user@host:2222
syslink shell user@host:3333        # user@host:3333
syslink shell 192.168.1.10          # root@192.168.1.10:2222
```
