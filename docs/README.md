# liblink Documentation

## What this package does

`liblink` implements SSH-over-QUIC behavior.

It provides the SSH protocol/runtime layer for secure remote access workflows over QUIC, including:

- key exchange orchestration
- user authentication
- session channels (shell/exec/subsystem)
- file transfer flows, including SFTP and the higher-throughput copy subsystem
- server runtime support

## Protocol shape

Connection lifecycle is organized in phases:

1. UDP key exchange bootstrap
2. QUIC encrypted transport startup
3. SSH user authentication over control stream
4. session/channel operations on QUIC streams

Each SSH channel maps to a QUIC stream, avoiding classic TCP head-of-line channel coupling.

## Main library areas

- `lib/connection.zig`
  - high-level client/server connection entry points
- `lib/kex/`
  - key exchange state and handshake orchestration
- `lib/auth/`
  - auth workflows and key handling
- `lib/channels/`
  - shell/exec/subsystem channel logic
- `lib/sftp.zig` and `lib/sftp_*.zig`
  - integrated SFTP client/server utilities
- `lib/copy.zig` and `lib/copy_*.zig`
  - integrated higher-throughput copy utilities used by `macsync`
- `lib/protocol/`
  - wire format encoding/decoding and message structures
- `lib/server/`
  - daemon/session runtime handling

## Typical usage flow

Client side:

1. Connect (optionally with trusted-host policy).
2. Authenticate with user identity key.
3. Open a session, SFTP channel, or copy client.
4. Exchange channel data over mapped QUIC streams.

Server side:

1. Start listener with server host key.
2. Accept connection.
3. Validate public key against policy/authorized key source.
4. Serve session and subsystem requests.

## Build and test

```bash
make build
zig build test --summary all
```

## CLI note

The `syslink` and `macsync` CLIs sit in `bin/` and demonstrate thin-client usage of the shared library surfaces for shell/exec, SFTP, and copy operations.

## Version

- `0.0.10`
