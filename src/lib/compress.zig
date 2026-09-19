//! compress.zig compresses and decompresses data held in memory with
//! `std.compress`. As of Zig 0.16 the standard library can write gzip and zlib,
//! and can read gzip, zlib, zstd and xz. Compressors and decompressors are
//! themselves writers and readers, so they chain together like Go's io types.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const zstd = std.compress.zstd;
const xz = std.compress.xz;

/// The supported container formats.
pub const Format = enum {
    gzip,
    zlib,
    zstd,
    xz,
};

/// Compresses `data`. Only gzip and zlib are supported because the standard
/// library has no zstd or xz compressor. The caller owns the returned slice.
pub fn compress(gpa: Allocator, format: Format, data: []const u8) ![]u8 {
    const container: flate.Container = switch (format) {
        .gzip => .gzip,
        .zlib => .zlib,
        .zstd, .xz => return error.CompressionNotSupported,
    };

    // The compressed bytes are collected here. The compressor requires its
    // output writer to already have some buffer space, hence `initCapacity`.
    var output: Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer output.deinit();

    // The compressor keeps a sliding window of recent input to search for
    // repeats. 64 KiB is large for a stack variable, so it goes on the heap.
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    // Data flows: compressor.writer -> (deflate) -> output.writer
    var compressor = try flate.Compress.init(&output.writer, window, container, .default);
    try compressor.writer.writeAll(data);
    // `finish` flushes what is pending and writes the checksum footer.
    try compressor.finish();

    return output.toOwnedSlice();
}

/// Decompresses `data`. The caller owns the returned slice.
pub fn decompress(gpa: Allocator, format: Format, data: []const u8) ![]u8 {
    // Data flows: data -> input reader -> decompressor.reader -> result
    var input: Io.Reader = .fixed(data);
    switch (format) {
        .gzip => return inflate(gpa, &input, .gzip),
        .zlib => return inflate(gpa, &input, .zlib),
        .zstd => {
            const window = try gpa.alloc(u8, zstd.default_window_len + zstd.block_size_max);
            defer gpa.free(window);
            var decompressor = zstd.Decompress.init(&input, window, .{});
            return decompressor.reader.allocRemaining(gpa, .unlimited);
        },
        .xz => {
            // The xz decompressor allocates and owns its own buffer. We start
            // it with an empty one, and `deinit` releases whatever it grew to.
            var decompressor = try xz.Decompress.init(&input, gpa, &.{});
            defer decompressor.deinit();
            return decompressor.reader.allocRemaining(gpa, .unlimited);
        },
    }
}

fn inflate(gpa: Allocator, input: *Io.Reader, container: flate.Container) ![]u8 {
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var decompressor = flate.Decompress.init(input, container, window);
    return decompressor.reader.allocRemaining(gpa, .unlimited);
}

/// Test helper: compresses, checks that it shrank, and decompresses again.
fn expectRoundTrip(format: Format) !void {
    const gpa = std.testing.allocator;
    // `**` repeats an array at compile time: 50 copies of this sentence.
    const original = "the quick brown fox jumps over the lazy dog. " ** 50;

    const compressed = try compress(gpa, format, original);
    defer gpa.free(compressed);
    try std.testing.expect(compressed.len < original.len);

    const restored = try decompress(gpa, format, compressed);
    defer gpa.free(restored);
    try std.testing.expectEqualStrings(original, restored);
}

test "gzip and zlib round trip" {
    try expectRoundTrip(.gzip);
    try expectRoundTrip(.zlib);
}

test "compress rejects formats without a compressor" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.CompressionNotSupported, compress(gpa, .zstd, "data"));
    try std.testing.expectError(error.CompressionNotSupported, compress(gpa, .xz, "data"));
}

test "decompress zstd and xz" {
    const gpa = std.testing.allocator;

    // Generated with: printf 'hello zig\n' | zstd -c | xxd -i
    const zstd_data = [_]u8{
        0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0x51, 0x00, 0x00, 0x68, 0x65, 0x6c,
        0x6c, 0x6f, 0x20, 0x7a, 0x69, 0x67, 0x0a, 0x20, 0x80, 0xb4, 0xef,
    };
    const from_zstd = try decompress(gpa, .zstd, &zstd_data);
    defer gpa.free(from_zstd);
    try std.testing.expectEqualStrings("hello zig\n", from_zstd);

    // Generated with: printf 'hello zig\n' | xz -c | xxd -i
    const xz_data = [_]u8{
        0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 0x00, 0x04, 0xe6, 0xd6, 0xb4, 0x46,
        0x04, 0xc0, 0x0e, 0x0a, 0x21, 0x01, 0x1c, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x83, 0x96, 0xba, 0x32, 0x01, 0x00, 0x09, 0x68,
        0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x7a, 0x69, 0x67, 0x0a, 0x00, 0x00, 0x00,
        0x01, 0xaa, 0x8e, 0xa5, 0xd5, 0x5c, 0xc7, 0xe9, 0x00, 0x01, 0x2a, 0x0a,
        0x1d, 0x90, 0x38, 0xaf, 0x1f, 0xb6, 0xf3, 0x7d, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x04, 0x59, 0x5a,
    };
    const from_xz = try decompress(gpa, .xz, &xz_data);
    defer gpa.free(from_xz);
    try std.testing.expectEqualStrings("hello zig\n", from_xz);
}
