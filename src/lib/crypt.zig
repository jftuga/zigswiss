//! crypt.zig encrypts and decrypts data with a password. The key is derived
//! with PBKDF2-HMAC-SHA256 and the data is sealed with AES-256-GCM, both from
//! `std.crypto`. The output layout is: magic | salt | nonce | tag | ciphertext.
//! The file is a good example of working with fixed-size arrays and slices.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// Identifies the file format and its version.
const magic = "ZGSW1";
const salt_length = 16;
const pbkdf2_iterations = 100_000;

// These constants are computed at compile time from the ones above.
const salt_start = magic.len;
const nonce_start = salt_start + salt_length;
const tag_start = nonce_start + Aes256Gcm.nonce_length;
const header_length = tag_start + Aes256Gcm.tag_length;

/// Encrypts `plaintext` with a key derived from `password`. A fresh random
/// salt and nonce are generated for every call, which is why `io` is needed.
/// The caller owns the returned slice.
pub fn encrypt(gpa: Allocator, io: Io, password: []const u8, plaintext: []const u8) ![]u8 {
    if (password.len == 0) return error.EmptyPassword;

    const result = try gpa.alloc(u8, header_length + plaintext.len);
    errdefer gpa.free(result);

    // Slicing with compile-time-known bounds, `result[a..b]`, produces a
    // pointer to a fixed-size array (`*[16]u8`) rather than a plain slice.
    // That is what lets these pieces be passed to APIs that want exact sizes.
    @memcpy(result[0..magic.len], magic);
    const salt = result[salt_start..nonce_start];
    const nonce = result[nonce_start..tag_start];
    const tag = result[tag_start..header_length];
    const ciphertext = result[header_length..];

    try io.randomSecure(salt);
    try io.randomSecure(nonce);

    const key = try deriveKey(password, salt);
    // `nonce.*` dereferences the array pointer to pass the array by value.
    Aes256Gcm.encrypt(ciphertext, tag, plaintext, magic, nonce.*, key);
    return result;
}

/// Reverses `encrypt`. Fails with `error.AuthenticationFailed` when the
/// password is wrong or the data was modified. The caller owns the result.
pub fn decrypt(gpa: Allocator, password: []const u8, data: []const u8) ![]u8 {
    if (password.len == 0) return error.EmptyPassword;
    if (data.len < header_length) return error.InvalidFormat;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return error.InvalidFormat;

    const salt = data[salt_start..nonce_start];
    const nonce = data[nonce_start..tag_start];
    const tag = data[tag_start..header_length];
    const ciphertext = data[header_length..];

    const plaintext = try gpa.alloc(u8, ciphertext.len);
    errdefer gpa.free(plaintext);

    const key = try deriveKey(password, salt);
    // The magic string is passed as "associated data": it is not encrypted,
    // but it is authenticated, so tampering with it is detected as well.
    try Aes256Gcm.decrypt(plaintext, ciphertext, tag.*, magic, nonce.*, key);
    return plaintext;
}

/// Stretches a password into a 256-bit key. The many iterations make
/// brute-force guessing expensive. Arrays are values in Zig, so the key is
/// simply returned; there is nothing to free.
fn deriveKey(password: []const u8, salt: []const u8) ![Aes256Gcm.key_length]u8 {
    var key: [Aes256Gcm.key_length]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&key, password, salt, pbkdf2_iterations, HmacSha256);
    return key;
}

test "encrypt then decrypt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const sealed = try encrypt(gpa, io, "hunter2", "attack at dawn");
    defer gpa.free(sealed);
    try std.testing.expectEqual(header_length + "attack at dawn".len, sealed.len);
    try std.testing.expectEqualStrings(magic, sealed[0..magic.len]);

    const opened = try decrypt(gpa, "hunter2", sealed);
    defer gpa.free(opened);
    try std.testing.expectEqualStrings("attack at dawn", opened);
}

test "decrypt detects a wrong password and tampering" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const sealed = try encrypt(gpa, io, "hunter2", "attack at dawn");
    defer gpa.free(sealed);

    try std.testing.expectError(error.AuthenticationFailed, decrypt(gpa, "wrong", sealed));

    // Flip one bit of the ciphertext.
    sealed[sealed.len - 1] ^= 0x01;
    try std.testing.expectError(error.AuthenticationFailed, decrypt(gpa, "hunter2", sealed));
}

test "decrypt rejects data that is not ours" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidFormat, decrypt(gpa, "pw", "short"));
    try std.testing.expectError(error.InvalidFormat, decrypt(gpa, "pw", "X" ** 64));
    try std.testing.expectError(error.EmptyPassword, decrypt(gpa, "", "X" ** 64));
}
