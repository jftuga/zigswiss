//! jwt.zig decodes a JSON Web Token and prints its header, payload and time
//! claims. It does NOT verify the signature, so it is a debugging aid and not a
//! security check. The file shows how library files reuse each other: it is
//! built from codec.zig, json.zig and time.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const codec = @import("codec.zig");
const json = @import("json.zig");
const time = @import("time.zig");

/// The registered claims that hold Unix timestamps.
const time_claims = [_][]const u8{ "iat", "nbf", "exp" };

/// One decoded JWT segment. `init` and `deinit` are the conventional names
/// for a constructor and destructor; Zig has no special syntax for either, so
/// the caller pairs them up with `defer`.
const Segment = struct {
    text: []u8,
    parsed: std.json.Parsed(std.json.Value),

    fn init(gpa: Allocator, encoded: []const u8) !Segment {
        const text = try codec.decode(gpa, .base64url, encoded);
        errdefer gpa.free(text);
        // Strings inside the parsed tree may point into `text` instead of
        // being copied, so `text` has to stay alive as long as `parsed` does.
        // That is why both are kept together in this struct.
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
        return .{ .text = text, .parsed = parsed };
    }

    fn deinit(self: *Segment, gpa: Allocator) void {
        self.parsed.deinit();
        gpa.free(self.text);
    }

    fn writePretty(self: Segment, gpa: Allocator, out: *Io.Writer) !void {
        const pretty = try json.stringify(gpa, self.parsed.value, .{ .whitespace = .indent_2 });
        defer gpa.free(pretty);
        try out.writeAll(pretty);
    }
};

/// Decodes `token` and writes a human readable report to `out`. `now_seconds`
/// is the current Unix time; passing it in keeps this function testable.
pub fn decode(gpa: Allocator, token: []const u8, now_seconds: i64, out: *Io.Writer) !void {
    // A JWT is three base64url segments joined by dots: header.payload.signature
    var segments = std.mem.splitScalar(u8, std.mem.trim(u8, token, " \t\r\n"), '.');
    const header_segment = segments.next() orelse return error.InvalidToken;
    const payload_segment = segments.next() orelse return error.InvalidToken;
    const signature_segment = segments.next() orelse return error.InvalidToken;
    if (segments.next() != null) return error.InvalidToken;

    var header: Segment = try .init(gpa, header_segment);
    defer header.deinit(gpa);
    try out.writeAll("Header:\n");
    try header.writePretty(gpa, out);

    var payload: Segment = try .init(gpa, payload_segment);
    defer payload.deinit(gpa);
    try out.writeAll("Payload:\n");
    try payload.writePretty(gpa, out);

    const signature = try codec.decode(gpa, .base64url, signature_segment);
    defer gpa.free(signature);
    try out.print("Signature: {d} bytes (not verified)\n", .{signature.len});

    try writeTimeClaims(payload.parsed.value, now_seconds, out);
}

fn writeTimeClaims(payload: std.json.Value, now_seconds: i64, out: *Io.Writer) !void {
    // A payload that is not a JSON object has no claims to report.
    if (payload != .object) return;

    for (time_claims) |claim| {
        // Two `orelse`/`switch` steps: the claim may be absent, and if present
        // it may not be an integer. Either way, skip it with `continue`.
        const value = payload.object.get(claim) orelse continue;
        const seconds = switch (value) {
            .integer => |integer| integer,
            else => continue,
        };

        try out.print("{s}: ", .{claim});
        try time.formatIso(seconds, out);
        if (std.mem.eql(u8, claim, "exp")) {
            if (seconds <= now_seconds) {
                try out.writeAll(" (EXPIRED)");
            } else {
                try out.print(" (expires in {d}s)", .{seconds - now_seconds});
            }
        }
        try out.writeByte('\n');
    }
}

// {"alg":"HS256","typ":"JWT"} . {"sub":"1234","iat":1000000000,"exp":2000000000} . "sig"
const sample_token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0IiwiaWF0IjoxMDAwMDAwMDAwLCJleHAiOjIwMDAwMDAwMDB9.c2ln";

test "decode reports header, payload and claims" {
    const gpa = std.testing.allocator;
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    try decode(gpa, sample_token, 1_500_000_000, &output.writer);
    const report = output.written();

    // `indexOf` returns an optional position, so `!= null` means "contains".
    try std.testing.expect(std.mem.indexOf(u8, report, "\"alg\": \"HS256\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"sub\": \"1234\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Signature: 3 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "iat: 2001-09-09T01:46:40Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "exp: 2033-05-18T03:33:20Z (expires in 500000000s)") != null);
}

test "decode marks an expired token" {
    const gpa = std.testing.allocator;
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    try decode(gpa, sample_token, 2_000_000_001, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(EXPIRED)") != null);
}

test "decode rejects a token without three segments" {
    const gpa = std.testing.allocator;
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    try std.testing.expectError(error.InvalidToken, decode(gpa, "only.two", 0, &output.writer));
    try std.testing.expectError(error.InvalidToken, decode(gpa, "a.b.c.d", 0, &output.writer));
}
