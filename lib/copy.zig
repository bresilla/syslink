const std = @import("std");

pub const protocol = @import("copy_protocol.zig");
pub const manifest = @import("copy_manifest.zig");
pub const fs = @import("copy_fs.zig");
pub const client = @import("copy_client.zig");
pub const server = @import("copy_server.zig");
pub const workflow = @import("copy_workflow.zig");

pub const Client = client.Client;
pub const PushOptions = client.PushOptions;
pub const Server = server.Server;
pub const TransferStats = client.TransferStats;
pub const Entry = manifest.Entry;
pub const EntryKind = manifest.EntryKind;
pub const Manifest = manifest.Manifest;
pub const ResumeState = manifest.ResumeState;
pub const SourceRoot = fs.SourceRoot;
pub const WalkOptions = fs.WalkOptions;
pub const buildManifestFromPaths = fs.buildManifestFromPaths;
pub const buildManifestFromSources = fs.buildManifestFromSources;
pub const calculateResumeState = fs.calculateResumeState;
pub const deriveArchivePath = fs.deriveArchivePath;
pub const joinPath = fs.joinPath;
pub const openCopy = workflow.openCopy;
pub const connect = workflow.connect;

test {
    std.testing.refAllDecls(@This());
}
