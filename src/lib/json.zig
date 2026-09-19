//! json.zig pretty-prints, compacts, validates and queries JSON documents
//! using `std.json`. Documents are parsed into `std.json.Value`, a tagged union
//! that can represent any JSON shape, and queried with a dot-separated path
//! such as "servers.0.name".

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// What the json command should do.
pub const Mode = enum {
    pretty,
    compact,
    validate,
    query,
};

/// Processes the JSON document in `text`. `path` is only used by `.query`.
/// The caller owns the returned slice.
pub fn run(gpa: Allocator, text: []const u8, mode: Mode, path: ?[]const u8) ![]u8 {
    if (mode == .validate) {
        const is_valid = try std.json.validate(gpa, text);
        return gpa.dupe(u8, if (is_valid) "valid\n" else "invalid\n");
    }

    // `parseFromSlice` returns a `Parsed` wrapper that owns an arena holding
    // every node of the document. One `deinit` call frees the whole tree.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();

    switch (mode) {
        .pretty => return stringify(gpa, parsed.value, .{ .whitespace = .indent_2 }),
        .compact => return stringify(gpa, parsed.value, .{}),
        .query => {
            const query_path = path orelse return error.MissingQueryPath;
            const found = query(parsed.value, query_path) orelse return error.PathNotFound;
            return stringify(gpa, found, .{ .whitespace = .indent_2 });
        },
        // `validate` returned above. `unreachable` documents that, and in
        // Debug builds it panics if the claim ever turns out to be wrong.
        .validate => unreachable,
    }
}

/// Serializes a value and appends a newline. The caller owns the result.
pub fn stringify(gpa: Allocator, value: std.json.Value, options: std.json.Stringify.Options) ![]u8 {
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try std.json.Stringify.value(value, options, &output.writer);
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

/// Walks `root` along a dot-separated path. Object members are matched by key
/// and array elements by index. Returns null when the path does not exist,
/// because a missing key is an expected outcome rather than a failure.
pub fn query(root: std.json.Value, path: []const u8) ?std.json.Value {
    var current = root;
    var segments = std.mem.splitScalar(u8, path, '.');
    while (segments.next()) |segment| {
        if (segment.len == 0) continue;
        // `std.json.Value` is a tagged union: it holds exactly one of several
        // types, and the tag says which. A `switch` inspects the tag, and the
        // `|payload|` capture gives access to the value stored inside.
        switch (current) {
            .object => |object| {
                current = object.get(segment) orelse return null;
            },
            .array => |array| {
                // `catch return null`: if parseInt fails, leave with null.
                const index = std.fmt.parseInt(usize, segment, 10) catch return null;
                if (index >= array.items.len) return null;
                current = array.items[index];
            },
            // Scalars have no children, so any remaining path cannot match.
            else => return null,
        }
    }
    return current;
}

const sample =
    \\{"name":"zigswiss","tags":["a","b"],"nested":{"port":4222,"ok":true}}
;

test "compact and pretty" {
    const gpa = std.testing.allocator;

    const compact = try run(gpa, "{ \"a\" : [ 1, 2 ] }", .compact, null);
    defer gpa.free(compact);
    try std.testing.expectEqualStrings("{\"a\":[1,2]}\n", compact);

    const pretty = try run(gpa, "{\"a\":1}", .pretty, null);
    defer gpa.free(pretty);
    try std.testing.expectEqualStrings("{\n  \"a\": 1\n}\n", pretty);
}

test "validate" {
    const gpa = std.testing.allocator;

    const good = try run(gpa, sample, .validate, null);
    defer gpa.free(good);
    try std.testing.expectEqualStrings("valid\n", good);

    const bad = try run(gpa, "{\"a\":", .validate, null);
    defer gpa.free(bad);
    try std.testing.expectEqualStrings("invalid\n", bad);
}

test "query" {
    const gpa = std.testing.allocator;

    const port = try run(gpa, sample, .query, "nested.port");
    defer gpa.free(port);
    try std.testing.expectEqualStrings("4222\n", port);

    const tag = try run(gpa, sample, .query, "tags.1");
    defer gpa.free(tag);
    try std.testing.expectEqualStrings("\"b\"\n", tag);

    try std.testing.expectError(error.PathNotFound, run(gpa, sample, .query, "nested.missing"));
    try std.testing.expectError(error.PathNotFound, run(gpa, sample, .query, "tags.9"));
    try std.testing.expectError(error.PathNotFound, run(gpa, sample, .query, "name.deeper"));
    try std.testing.expectError(error.MissingQueryPath, run(gpa, sample, .query, null));
}
