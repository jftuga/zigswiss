//! hash.zig computes message digests of files or stdin. It streams the input
//! through the hasher in chunks, so memory use stays flat no matter how large
//! the file is. It also shows Zig generics: one function body is reused for
//! every algorithm by passing the hasher *type* as a compile-time parameter.

const std = @import("std");
const Io = std.Io;
const input = @import("input.zig");

/// The supported algorithms. An `enum` is a closed set of named values; a
/// `switch` over one must handle every member or the code will not compile.
pub const Algorithm = enum {
    md5,
    sha1,
    sha256,
    sha512,
    sha3_256,
    blake3,
    crc32,
};

/// Hashes one file (or stdin for "-") and writes "<hex digest>  <path>\n".
pub fn hashFile(io: Io, path: []const u8, algorithm: Algorithm, hmac_key: ?[]const u8, out: *Io.Writer) !void {
    const file = try input.open(io, path);
    defer input.close(io, file);

    var buffer: [8192]u8 = undefined;
    // Streaming mode, because `file` may be stdin (see input.zig).
    var file_reader = file.readerStreaming(io, &buffer);

    try writeDigest(algorithm, &file_reader.interface, hmac_key, out);
    try out.print("  {s}\n", .{path});
}

/// Reads `reader` to the end and writes the digest to `out` as lowercase hex.
///
/// `hmac_key` has the type `?[]const u8`, an "optional": it is either `null`
/// or a byte slice. When it is set, an HMAC is computed instead of a plain hash.
pub fn writeDigest(algorithm: Algorithm, reader: *Io.Reader, hmac_key: ?[]const u8, out: *Io.Writer) !void {
    const hashes = std.crypto.hash;
    switch (algorithm) {
        .md5 => try writeCryptoDigest(hashes.Md5, reader, hmac_key, out),
        .sha1 => try writeCryptoDigest(hashes.Sha1, reader, hmac_key, out),
        .sha256 => try writeCryptoDigest(hashes.sha2.Sha256, reader, hmac_key, out),
        .sha512 => try writeCryptoDigest(hashes.sha2.Sha512, reader, hmac_key, out),
        .sha3_256 => try writeCryptoDigest(hashes.sha3.Sha3_256, reader, hmac_key, out),
        .blake3 => try writeCryptoDigest(hashes.Blake3, reader, hmac_key, out),
        .crc32 => try writeCrc32(reader, hmac_key, out),
    }
}

/// `comptime Hasher: type` makes this a generic function. The compiler creates
/// a separate copy for each hasher type it is called with, the same idea as
/// generics in Go, but the parameter is an ordinary value of type `type`.
fn writeCryptoDigest(comptime Hasher: type, reader: *Io.Reader, hmac_key: ?[]const u8, out: *Io.Writer) !void {
    // `if (optional) |value|` unwraps an optional: the branch runs only when
    // it is not null, and `key` is the unwrapped slice.
    if (hmac_key) |key| {
        const Hmac = std.crypto.auth.hmac.Hmac(Hasher);
        var mac = Hmac.init(key);
        try feed(&mac, reader);
        // Array lengths must be known at compile time. `mac_length` is a
        // constant declared on the Hmac type, so this works.
        var digest: [Hmac.mac_length]u8 = undefined;
        mac.final(&digest);
        try out.print("{x}", .{&digest});
    } else {
        var hasher = Hasher.init(.{});
        try feed(&hasher, reader);
        var digest: [Hasher.digest_length]u8 = undefined;
        hasher.final(&digest);
        // The `{x}` format specifier prints a byte slice as lowercase hex.
        try out.print("{x}", .{&digest});
    }
}

/// CRC-32 is a checksum, not a cryptographic hash, so it lives in `std.hash`
/// and returns a `u32` instead of filling a byte array.
fn writeCrc32(reader: *Io.Reader, hmac_key: ?[]const u8, out: *Io.Writer) !void {
    if (hmac_key != null) return error.HmacNotSupportedForCrc32;
    var crc = std.hash.Crc32.init();
    try feed(&crc, reader);
    // `{x:0>8}` means hex, right-aligned, zero-padded to 8 characters.
    try out.print("{x:0>8}", .{crc.final()});
}

/// Pumps every byte from `reader` into `hasher`.
///
/// `anytype` means "accept any type and check at compile time that the body
/// compiles for it". Here the only requirement is an `update([]const u8)` method,
/// which all the hashers, the Hmac type and Crc32 provide.
fn feed(hasher: anytype, reader: *Io.Reader) !void {
    while (true) {
        // `peekGreedy(1)` returns everything currently buffered, reading more
        // from the source if fewer than 1 byte is available.
        const chunk = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        hasher.update(chunk);
        // Mark the bytes we just hashed as consumed.
        reader.toss(chunk.len);
    }
}

/// Test helper: hashes an in-memory string and returns the hex digest.
fn digestOfString(buffer: []u8, algorithm: Algorithm, text: []const u8, hmac_key: ?[]const u8) ![]const u8 {
    // `Io.Reader.fixed` and `Io.Writer.fixed` wrap plain memory, which makes
    // stream-based code easy to test without touching the file system.
    var reader: Io.Reader = .fixed(text);
    var writer: Io.Writer = .fixed(buffer);
    try writeDigest(algorithm, &reader, hmac_key, &writer);
    return writer.buffered();
}

test "known digests of 'hello\\n'" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "b1946ac92492d2347c6235b4d2611184",
        try digestOfString(&buffer, .md5, "hello\n", null),
    );
    try std.testing.expectEqualStrings(
        "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03",
        try digestOfString(&buffer, .sha256, "hello\n", null),
    );
    try std.testing.expectEqualStrings(
        "363a3020",
        try digestOfString(&buffer, .crc32, "hello\n", null),
    );
}

test "hmac-sha256 matches RFC 4231 test case 2" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        try digestOfString(&buffer, .sha256, "what do ya want for nothing?", "Jefe"),
    );
}

test "hmac is rejected for crc32" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectError(
        error.HmacNotSupportedForCrc32,
        digestOfString(&buffer, .crc32, "hello", "key"),
    );
}
