# liblink

SSH-over-QUIC protocol/runtime library in Zig.

## Overview

`liblink` is focused on the SSH side of QUIC systems.

- SSH key exchange orchestration and session setup
- User authentication workflows
- SSH channels (shell, exec, subsystem)
- SFTP support
- Server runtime and CLI support (`syslink`)

In short: if your product needs SSH semantics over QUIC, this is the package.

## Build and Test

```bash
make build
zig build test --summary all
```

## Quick Start (CLI)

```bash
# Generate server host key
ssh-keygen -t ed25519 -f ~/.ssh/syslink_host_key -N ""

# Start server
syslink server start -k ~/.ssh/syslink_host_key

# Remote shell
syslink shell -i ~/.ssh/id_ed25519 user@host:2222
```

## Docs

- See `docs/` for library and protocol documentation.
- CLI-specific usage is in `bin/README.md`.

## Acknowledgments

- See `ACKNOWLEDGMENTS.md`.

## Version

- Current package version: `0.0.10`
