//! transform.zig implements line and text transformations: changing case,
//! reversing, sorting, de-duplicating, counting, replacing and word frequency.
//! It is a tour of the everyday containers and string helpers in the standard
//! library: slices, `std.ArrayList`, `std.StringHashMap`, `std.mem` and `std.sort`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The available transformations.
pub const Mode = enum {
    upper,
    lower,
    reverse,
    sort,
    uniq,
    count,
    replace,
    freq,
};

/// Settings for `run`. Struct fields can have default values, so a caller only
/// names the fields it wants to change: `.{ .mode = .upper }`. This is the Zig
/// replacement for Go's functional options pattern.
pub const Options = struct {
    mode: Mode,
    /// Text to search for. Required by `.replace`.
    find: ?[]const u8 = null,
    /// Replacement text for `.replace`.
    replacement: []const u8 = "",
};

/// Applies the transformation to `text`. The caller owns the returned slice.
pub fn run(gpa: Allocator, text: []const u8, options: Options) ![]u8 {
    switch (options.mode) {
        .upper => return std.ascii.allocUpperString(gpa, text),
        .lower => return std.ascii.allocLowerString(gpa, text),
        .reverse => return reverseLines(gpa, text),
        .sort => return sortLines(gpa, text),
        .uniq => return uniqueLines(gpa, text),
        .count => return countText(gpa, text),
        .replace => {
            // `orelse` supplies a fallback for a null optional. Here the
            // fallback is to leave the function with an error.
            const find = options.find orelse return error.MissingFindText;
            if (find.len == 0) return error.MissingFindText;
            return std.mem.replaceOwned(u8, gpa, text, find, options.replacement);
        },
        .freq => return wordFrequency(gpa, text),
    }
}

/// Splits `text` into lines. A final newline does not produce an empty last
/// line. The returned list holds slices that point into `text`; no line is
/// copied. The caller must call `deinit(gpa)` on the list.
fn splitLines(gpa: Allocator, text: []const u8) !std.ArrayList([]const u8) {
    // `std.ArrayList` is a growable array, like a Go slice with append. It
    // does not store an allocator; you pass one to each call that may allocate.
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(gpa);

    const body = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    if (body.len == 0) return lines;

    var iterator = std.mem.splitScalar(u8, body, '\n');
    // `while (optional) |value|` loops until the expression returns null.
    while (iterator.next()) |line| {
        try lines.append(gpa, line);
    }
    return lines;
}

/// Joins lines with newlines. The caller owns the returned slice.
fn joinLines(gpa: Allocator, lines: []const []const u8) ![]u8 {
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    for (lines) |line| {
        try output.writer.print("{s}\n", .{line});
    }
    return output.toOwnedSlice();
}

/// Reverses the characters of each line. Works on Unicode code points rather
/// than bytes so multi-byte UTF-8 characters are not corrupted.
fn reverseLines(gpa: Allocator, text: []const u8) ![]u8 {
    var lines = try splitLines(gpa, text);
    defer lines.deinit(gpa);

    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    var code_points: std.ArrayList([]const u8) = .empty;
    defer code_points.deinit(gpa);

    for (lines.items) |line| {
        // `clearRetainingCapacity` empties the list but keeps its memory, so
        // the same buffer is reused for every line.
        code_points.clearRetainingCapacity();
        const view = try std.unicode.Utf8View.init(line);
        var iterator = view.iterator();
        while (iterator.nextCodepointSlice()) |slice| {
            try code_points.append(gpa, slice);
        }
        std.mem.reverse([]const u8, code_points.items);
        for (code_points.items) |slice| try output.writer.writeAll(slice);
        try output.writer.writeByte('\n');
    }
    return output.toOwnedSlice();
}

fn sortLines(gpa: Allocator, text: []const u8) ![]u8 {
    var lines = try splitLines(gpa, text);
    defer lines.deinit(gpa);
    // `std.mem.sort` takes a context value and a comparison function. We need
    // no context, so we pass `{}`, which is the one value of type `void`.
    std.mem.sort([]const u8, lines.items, {}, lineLessThan);
    return joinLines(gpa, lines.items);
}

fn lineLessThan(context: void, a: []const u8, b: []const u8) bool {
    _ = context;
    return std.mem.lessThan(u8, a, b);
}

/// Removes duplicate lines, keeping the first occurrence of each.
fn uniqueLines(gpa: Allocator, text: []const u8) ![]u8 {
    var lines = try splitLines(gpa, text);
    defer lines.deinit(gpa);

    // A set is a map whose value type is `void`, which takes no space.
    var seen: std.StringHashMap(void) = .init(gpa);
    defer seen.deinit();

    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(gpa);

    for (lines.items) |line| {
        // `getOrPut` does one lookup and tells us if the key already existed.
        const entry = try seen.getOrPut(line);
        if (!entry.found_existing) try kept.append(gpa, line);
    }
    return joinLines(gpa, kept.items);
}

fn countText(gpa: Allocator, text: []const u8) ![]u8 {
    const line_count = std.mem.countScalar(u8, text, '\n');

    var word_count: usize = 0;
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    // The payload capture is `_` because only the number of words matters.
    while (words.next()) |_| word_count += 1;

    const char_count = try std.unicode.utf8CountCodepoints(text);

    return std.fmt.allocPrint(gpa, "lines: {d}\nwords: {d}\nchars: {d}\nbytes: {d}\n", .{
        line_count, word_count, char_count, text.len,
    });
}

/// One row of the word frequency table.
const WordCount = struct {
    word: []const u8,
    count: usize,
};

/// Counts how often each whitespace-separated word occurs, most frequent first.
fn wordFrequency(gpa: Allocator, text: []const u8) ![]u8 {
    var counts: std.StringHashMap(usize) = .init(gpa);
    defer counts.deinit();

    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |word| {
        const entry = try counts.getOrPut(word);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    // Hash maps have no order, so copy the entries into a list and sort it.
    var rows: std.ArrayList(WordCount) = .empty;
    defer rows.deinit(gpa);
    var iterator = counts.iterator();
    while (iterator.next()) |entry| {
        try rows.append(gpa, .{ .word = entry.key_ptr.*, .count = entry.value_ptr.* });
    }
    std.mem.sort(WordCount, rows.items, {}, wordCountLessThan);

    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    for (rows.items) |row| {
        try output.writer.print("{d:>7} {s}\n", .{ row.count, row.word });
    }
    return output.toOwnedSlice();
}

/// Orders by count (highest first), then alphabetically so ties are stable.
fn wordCountLessThan(context: void, a: WordCount, b: WordCount) bool {
    _ = context;
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.word, b.word);
}

/// Test helper: runs a transformation and compares the result.
fn expectTransform(options: Options, text: []const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    const result = try run(gpa, text, options);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "case" {
    try expectTransform(.{ .mode = .upper }, "Hello\n", "HELLO\n");
    try expectTransform(.{ .mode = .lower }, "Hello\n", "hello\n");
}

test "reverse keeps multi-byte characters intact" {
    try expectTransform(.{ .mode = .reverse }, "abc\nh\xc3\xa9llo\n", "cba\noll\xc3\xa9h\n");
}

test "sort and uniq" {
    try expectTransform(.{ .mode = .sort }, "pear\napple\nfig\n", "apple\nfig\npear\n");
    try expectTransform(.{ .mode = .uniq }, "a\nb\na\nc\nb\n", "a\nb\nc\n");
    try expectTransform(.{ .mode = .sort }, "", "");
}

test "count" {
    try expectTransform(.{ .mode = .count }, "one two\nthree\n", "lines: 2\nwords: 3\nchars: 14\nbytes: 14\n");
}

test "replace" {
    try expectTransform(.{ .mode = .replace, .find = "cat", .replacement = "dog" }, "cat catalog\n", "dog dogalog\n");
    try std.testing.expectError(error.MissingFindText, run(std.testing.allocator, "x", .{ .mode = .replace }));
}

test "freq sorts by count then word" {
    try expectTransform(.{ .mode = .freq }, "b a b c a b\n", "      3 b\n      2 a\n      1 c\n");
}
