//! generate.zig produces random passwords, hex tokens and version 4 UUIDs.
//! Every function takes a `std.Random` parameter instead of creating its own
//! random source. The command line passes a cryptographically secure generator;
//! the tests pass a seeded one so their output is repeatable.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// What to generate.
pub const Mode = enum {
    password,
    token,
    uuid,
};

/// The characters a password may be drawn from.
pub const Charset = enum {
    alnum,
    alpha,
    digits,
    full,

    /// Enums (and structs) can have methods. `self` is just a parameter name.
    pub fn characters(self: Charset) []const u8 {
        const lower = "abcdefghijklmnopqrstuvwxyz";
        const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        const digits = "0123456789";
        const symbols = "!@#$%^&*()-_=+[]{}<>?";
        // `++` joins arrays at compile time, so these are constants baked
        // into the binary, not runtime concatenations.
        return switch (self) {
            .alnum => lower ++ upper ++ digits,
            .alpha => lower ++ upper,
            .digits => digits,
            .full => lower ++ upper ++ digits ++ symbols,
        };
    }
};

/// Creates a cryptographically secure generator seeded from the OS.
///
/// The returned value is the concrete ChaCha generator. Call `.random()` on a
/// `var` copy of it to get the `std.Random` interface the functions below take.
pub fn secureGenerator(io: Io) !std.Random.DefaultCsprng {
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randomSecure(&seed);
    return std.Random.DefaultCsprng.init(seed);
}

/// Returns a password of `length` characters. The caller owns the result.
pub fn password(gpa: Allocator, random: std.Random, length: usize, charset: Charset) ![]u8 {
    if (length == 0) return error.InvalidLength;
    const characters = charset.characters();
    const result = try gpa.alloc(u8, length);
    // `for (slice) |*item|` captures a pointer to each element so that it can
    // be assigned to. Without the `*` the capture is a read-only copy.
    for (result) |*c| {
        // `uintLessThan` avoids the modulo bias of `random_value % len`.
        c.* = characters[random.uintLessThan(usize, characters.len)];
    }
    return result;
}

/// Returns `byte_count` random bytes as lowercase hex. The caller owns the result.
pub fn token(gpa: Allocator, random: std.Random, byte_count: usize) ![]u8 {
    if (byte_count == 0) return error.InvalidLength;
    const bytes = try gpa.alloc(u8, byte_count);
    defer gpa.free(bytes);
    random.bytes(bytes);
    return std.fmt.allocPrint(gpa, "{x}", .{bytes});
}

/// The length of a UUID in its usual 8-4-4-4-12 text form.
pub const uuid_text_length = 36;

/// Returns a random (version 4) UUID. The result is a fixed-size array returned
/// by value, so no allocator is needed.
pub fn uuid(random: std.Random) [uuid_text_length]u8 {
    var bytes: [16]u8 = undefined;
    random.bytes(&bytes);
    // RFC 9562: the high 4 bits of byte 6 hold the version (4), and the high
    // 2 bits of byte 8 hold the variant (binary 10).
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    var text: [uuid_text_length]u8 = undefined;
    // `bufPrint` formats into an existing buffer. It can only fail if the
    // buffer is too small, which cannot happen here, hence `catch unreachable`.
    _ = std.fmt.bufPrint(&text, "{x}-{x}-{x}-{x}-{x}", .{
        bytes[0..4], bytes[4..6], bytes[6..8], bytes[8..10], bytes[10..16],
    }) catch unreachable;
    return text;
}

test "password has the requested length and only allowed characters" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const result = try password(gpa, prng.random(), 64, .digits);
    defer gpa.free(result);

    try std.testing.expectEqual(64, result.len);
    for (result) |c| try std.testing.expect(std.ascii.isDigit(c));
}

test "password rejects zero length" {
    var prng = std.Random.DefaultPrng.init(42);
    try std.testing.expectError(error.InvalidLength, password(std.testing.allocator, prng.random(), 0, .alnum));
}

test "token is two hex characters per byte" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const result = try token(gpa, prng.random(), 16);
    defer gpa.free(result);
    try std.testing.expectEqual(32, result.len);
}

test "uuid has version 4 layout" {
    var prng = std.Random.DefaultPrng.init(42);
    const text = uuid(prng.random());
    try std.testing.expectEqual('-', text[8]);
    try std.testing.expectEqual('-', text[13]);
    try std.testing.expectEqual('4', text[14]);
    try std.testing.expectEqual('-', text[18]);
    try std.testing.expectEqual('-', text[23]);
    // The variant nibble must be 8, 9, a or b.
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", text[19]) != null);
}
