//! root.zig is the root source file of the "zigswiss" library module (see
//! build.zig, where `b.addModule("zigswiss", ...)` points here). Code outside
//! this module can only reach declarations that are marked `pub` in this file,
//! so every subcommand's logic is re-exported below. None of the files under
//! src/lib know anything about command line parsing.

const std = @import("std");

// `@import` of a relative path returns that file as a struct type. Its `pub`
// declarations become fields you reach with a dot: `zigswiss.hash.Algorithm`.
pub const input = @import("lib/input.zig");
pub const hash = @import("lib/hash.zig");
pub const codec = @import("lib/codec.zig");
pub const generate = @import("lib/generate.zig");
pub const transform = @import("lib/transform.zig");
pub const json = @import("lib/json.zig");
pub const time = @import("lib/time.zig");
pub const jwt = @import("lib/jwt.zig");
pub const compress = @import("lib/compress.zig");
pub const crypt = @import("lib/crypt.zig");
pub const info = @import("lib/info.zig");
pub const net = @import("lib/net.zig");
pub const fetch = @import("lib/fetch.zig");
pub const archive = @import("lib/archive.zig");
pub const bench = @import("lib/bench.zig");

// Zig is lazy: a file's `test` blocks only run if something references that
// file from the test root. `refAllDecls` touches every declaration above, so
// `zig build test` picks up the tests in all of the imported files.
test {
    std.testing.refAllDecls(@This());
}
