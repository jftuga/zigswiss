//! codec.zig converts bytes to and from text encodings: base64, URL-safe
//! base64, hex and URL percent-encoding. Every function is pure (memory in,
//! memory out), which makes this the easiest file to start with when learning
//! how Zig handles allocation and slices.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The supported text encodings.
pub const Format = enum {
    base64,
    base64url,
    hex,
    url,
};

/// Encodes `data`. The caller owns the returned slice.
///
/// Zig has no hidden allocations. Any function that needs heap memory takes an
/// `Allocator` parameter, and by convention the doc comment says who frees the
/// result.
pub fn encode(gpa: Allocator, format: Format, data: []const u8) ![]u8 {
    switch (format) {
        .base64 => return encodeBase64(gpa, std.base64.standard.Encoder, data),
        .base64url => return encodeBase64(gpa, std.base64.url_safe_no_pad.Encoder, data),
        .hex => return std.fmt.allocPrint(gpa, "{x}", .{data}),
        .url => return encodeUrl(gpa, data),
    }
}

/// Decodes `text`. Surrounding whitespace is ignored so that input produced by
/// `echo` (which appends a newline) works. The caller owns the returned slice.
pub fn decode(gpa: Allocator, format: Format, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    switch (format) {
        .base64 => return decodeBase64(gpa, std.base64.standard.Decoder, trimmed),
        .base64url => return decodeBase64(gpa, std.base64.url_safe_no_pad.Decoder, trimmed),
        .hex => return decodeHex(gpa, trimmed),
        .url => return decodeUrl(gpa, trimmed),
    }
}

fn encodeBase64(gpa: Allocator, encoder: std.base64.Base64Encoder, data: []const u8) ![]u8 {
    const result = try gpa.alloc(u8, encoder.calcSize(data.len));
    // `encode` returns the slice it wrote, which is all of `result`. Assigning
    // to `_` tells the compiler we are ignoring a return value on purpose.
    _ = encoder.encode(result, data);
    return result;
}

fn decodeBase64(gpa: Allocator, decoder: std.base64.Base64Decoder, text: []const u8) ![]u8 {
    const result = try gpa.alloc(u8, try decoder.calcSizeForSlice(text));
    // `errdefer` is like `defer` but runs only if the function returns an
    // error. Without it, a decoding failure below would leak `result`.
    errdefer gpa.free(result);
    try decoder.decode(result, text);
    return result;
}

fn decodeHex(gpa: Allocator, text: []const u8) ![]u8 {
    if (text.len % 2 != 0) return error.InvalidHexLength;
    const result = try gpa.alloc(u8, text.len / 2);
    errdefer gpa.free(result);
    _ = try std.fmt.hexToBytes(result, text);
    return result;
}

fn encodeUrl(gpa: Allocator, data: []const u8) ![]u8 {
    // `Io.Writer.Allocating` is a writer that grows a heap buffer as you write
    // to it, the equivalent of Go's bytes.Buffer.
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    // The third argument is a function. Functions are values in Zig, so
    // `isUrlSafe` is passed by name with no special syntax.
    try std.Uri.Component.percentEncode(&buffer.writer, data, isUrlSafe);
    // `toOwnedSlice` hands the buffer's memory to the caller.
    return buffer.toOwnedSlice();
}

fn decodeUrl(gpa: Allocator, text: []const u8) ![]u8 {
    // Decoding never grows the text, so work on a copy and shrink it.
    const copy = try gpa.dupe(u8, text);
    errdefer gpa.free(copy);
    const decoded = std.Uri.percentDecodeInPlace(copy);
    // `decoded` is a shorter view into `copy`. Allocators must be given back
    // the exact slice they handed out, so make a right-sized copy to return.
    const result = try gpa.dupe(u8, decoded);
    gpa.free(copy);
    return result;
}

/// The RFC 3986 "unreserved" characters, which never need percent-encoding.
fn isUrlSafe(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// Test helper: encodes, checks the text, decodes, and checks the round trip.
fn expectRoundTrip(format: Format, data: []const u8, expected_text: []const u8) !void {
    const gpa = std.testing.allocator;
    const text = try encode(gpa, format, data);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(expected_text, text);

    const back = try decode(gpa, format, text);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(data, back);
}

test "round trips" {
    try expectRoundTrip(.base64, "hello world", "aGVsbG8gd29ybGQ=");
    try expectRoundTrip(.base64url, "\xfb\xff", "-_8");
    try expectRoundTrip(.hex, "hello", "68656c6c6f");
    try expectRoundTrip(.url, "foo bar&baz=1", "foo%20bar%26baz%3D1");
}

test "decode ignores a trailing newline" {
    const gpa = std.testing.allocator;
    const data = try decode(gpa, .base64, "aGVsbG8=\n");
    defer gpa.free(data);
    try std.testing.expectEqualStrings("hello", data);
}

test "decode rejects bad input" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidHexLength, decode(gpa, .hex, "abc"));
    try std.testing.expectError(error.InvalidCharacter, decode(gpa, .hex, "zz"));
    try std.testing.expectError(error.InvalidCharacter, decode(gpa, .base64, "!!!!"));
}
