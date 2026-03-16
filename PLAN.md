# macsync Plan

## Goal

Build a new binary, `macsync`, as a liblink-native high-throughput file transfer tool for authenticated machine-to-machine copy over the existing SSH/QUIC connection model.

The target is not to clone Thruflux's full product shape. The target is to bring the useful transfer ideas into liblink's existing transport, authentication, and subsystem model.

## Scope

`macsync` v1 should:

- run entirely inside liblink
- reuse liblink authentication and host-key trust flow
- transfer files and directories between two machines
- preserve relative paths
- support resumable transfers
- expose a reusable liblink API, not just a CLI
- be materially faster than the current SFTP workflow on large transfers

## Non-Goals

`macsync` v1 should not include:

- join-code based ad hoc sharing
- signaling servers
- ICE, STUN, or TURN
- random-peer NAT traversal
- multi-receiver fanout
- GUI work
- rsync-style block delta sync
- platform-specific copy offload features

Those can be revisited later, but they should not shape the initial design.

## Current State

liblink already has the right extension point for a custom subsystem:

- client can request arbitrary subsystems over a session channel
- server session runtime dispatches subsystem modes
- server session runtime now recognizes both `sftp` and `macsync`

The current transfer path is SFTP-oriented and not a good base for a "fast copy" API:

- request/response per read and write
- small 32 KiB default transfer size
- per-message encode/decode and allocation overhead

This means `macsync` should be a new subsystem and an integrated copy API in the main library surface, not a thin wrapper around SFTP.

## Proposed Architecture

Add integrated top-level transfer files, following the same flat library layout used by the rest of liblink:

- `lib/copy_protocol.zig`
- `lib/copy_manifest.zig`
- `lib/copy_fs.zig`
- `lib/copy_client.zig`
- `lib/copy_server.zig`
- `lib/copy_workflow.zig`
- `lib/copy.zig`

Expose it from `lib/liblink.zig` as:

```zig
pub const copy = @import("copy.zig");
```

Add a new subsystem name:

- `"macsync"`

Add a new binary:

- `bin/macsync.zig`

## API Direction

The library API should be usable without the CLI.

Likely public surface:

```zig
pub const Options = struct { ... };
pub const Manifest = struct { ... };
pub const TransferStats = struct { ... };

pub const Client = struct {
    pub fn init(...) !Client;
    pub fn pushPaths(...) !TransferStats;
    pub fn pullPaths(...) !TransferStats;
};

pub fn openCopy(connection: *liblink.connection.ClientConnection) !CopyClient;
```

CLI code should stay thin and call the library workflow layer.

## Protocol Direction

Use a custom framed protocol over a `macsync` subsystem channel.

Recommended v1 message types:

- `hello`
- `manifest`
- `resume_state`
- `file_chunk`
- `file_done`
- `checkpoint`
- `error`
- `complete`

Protocol principles:

- stable file ordering by normalized relative path
- explicit file ids
- explicit offsets for resume
- large payload frames
- versioned wire format
- no JSON on the data path

## Manifest Design

Borrow the useful ideas from Thruflux, but adapt them to liblink:

- walk all requested paths up front
- assign stable file ids after sorting relative paths
- store size and normalized relative path
- optionally include mode and mtime in v1 if preservation is cheap

Keep manifest format simple and binary.

Deferred until later unless clearly needed:

- content hashes for every file
- sparse file support
- symlink replication
- xattrs and ACLs

## Resume Strategy

Resume is worth doing in v1.

Receiver-side resume approach:

- parse manifest
- inspect destination tree
- compute the first incomplete file id and offset
- send that resume state back to sender

Sender-side resume approach:

- skip fully completed files
- reopen current file at the returned offset
- continue streaming

This is simpler than full chunk maps and should cover the main interrupted-transfer case well.

## Performance Plan

`macsync` should not inherit the current SFTP bottlenecks.

Planned performance work:

- use larger application frames, starting around 256 KiB to 1 MiB
- avoid request/response for every chunk
- reduce allocator churn in the hot path
- add buffer reuse for encode/decode
- add channel helpers that support sustained streaming better than the current generic path

If profiling shows the single subsystem channel is the bottleneck, phase 2 can add:

- pipelined acknowledgements
- parallel data channels
- larger transport windows if libfast supports tuning cleanly

## CLI Shape

Keep the first CLI narrow.

Recommended v1 commands:

- `macsync push <src...> [user@]host[:port]:<dest>`
- `macsync pull [user@]host[:port]:<src> <dest>`

Optional flags:

- `-i, --identity`
- `-P, --port`
- `--strict-host-key`
- `--accept-new-host-key`
- `--overwrite`
- `--no-resume`
- `--preserve-mode`
- `--preserve-time`
- `--frame-size`

Do not add broad sync semantics in v1. "Copy" is enough. A true bidirectional sync model can come later.

## Server Integration

Server-side work should be minimal and explicit:

- extend session runtime to recognize subsystem `"macsync"`
- dispatch to a dedicated `macsync` server handler
- keep SFTP and `macsync` independent

Avoid mixing `macsync` behavior into the shell or exec paths.

## Implementation Phases

### Phase 0: Baseline and Constraints

- capture current SFTP throughput baseline
- decide v1 metadata scope
- decide initial frame size and checkpoint interval
- define what "faster than SFTP" means for acceptance

### Phase 1: Subsystem Plumbing

- [x] add integrated copy module files at the top-level library surface
- [x] export `copy` from `lib/liblink.zig`
- [x] add client helper to open a `macsync` subsystem through `openCopy`
- [x] extend server runtime to accept and dispatch `"macsync"`

Exit criteria:

- [x] a no-op `macsync` subsystem handshake works end to end
  Verified by the new phase-1 hello/ready handshake implementation and the gated integration test `network_macsync_e2e_test.zig`.

### Phase 2: Protocol and Manifest

- [x] implement wire types
- [x] implement manifest encoding and decoding
- [x] implement filesystem walking and stable ordering
- [x] implement resume-state calculation

Exit criteria:

- [x] manifest round-trip tests pass
- [x] sender and receiver agree on resume start point

### Phase 3: Transfer Engine

- [x] implement sender file streaming
- [x] implement receiver file creation and writes
- [x] implement periodic checkpoints
- [x] implement final completion handshake

Exit criteria:

- [x] single-file and directory transfers work locally
- [x] interrupted transfer can resume correctly

### Phase 4: CLI

- [x] add `bin/macsync.zig`
- parse source and destination specs
- reuse liblink auth and trust policy helpers
- print useful progress and completion summaries

Exit criteria:

- `push` and `pull` are usable without touching internal APIs directly

### Phase 5: Performance Pass

- profile hot spots
- reduce copies and allocations
- tune frame sizes
- add throughput-focused channel helpers if required

Exit criteria:

- benchmark improvement over SFTP on large files

### Phase 6: Testing and Docs

- [x] unit tests for protocol and manifest
- [x] integration tests for end-to-end copy
- [x] resume tests
- overwrite and collision tests
- docs for API and CLI usage

Exit criteria:

- stable repeatable local integration coverage exists

## Testing Matrix

Minimum test coverage:

- single file push
- directory tree push
- pull from remote tree
- interrupted transfer resume
- overwrite disabled and enabled behavior
- zero-byte files
- many small files
- large file
- invalid destination paths
- unsupported metadata cases

## Main Risks

- current channel API may copy too much for sustained high-throughput transfer
- framing choices may be too conservative if left close to SFTP defaults
- resume logic can become fragile if path normalization is inconsistent
- metadata preservation can expand scope quickly if not constrained early

## Open Questions

- Should v1 preserve mode and mtime, or leave metadata for v2?
- Should v1 support symlinks, or reject them explicitly?
- Should pull be included in the first cut, or should v1 ship with push only?
- Do we want final integrity verification by size only, or by optional file hash?
- Is one data channel enough for the first benchmark target?

## Recommended First Cut

The safest first cut is:

- single subsystem channel
- binary manifest
- push and pull
- resume by file id plus offset
- directory preservation
- size-based completion checks
- no symlink support
- no advanced metadata beyond directories and regular files

That is enough to validate whether liblink can support a genuinely better copy API before taking on more complexity.
