const std = @import("std");
const config = @import("config.zig");

const green = "\x1b[32m";
const reset = "\x1b[0m";

pub const RunOpts = struct {
    fix: bool = false,
    dry_run: bool = false,
    filter: ?[]const u8 = null,
    cli_flags: ?[]const u8 = null,
    jobs: usize = 1,
};

/// Returns true if all files passed clang-tidy (or dry-run).
pub fn run(
    allocator: std.mem.Allocator,
    clang_tidy: []const u8,
    global_flags: []const u8,
    compile_commands: ?[]const u8,
    opts: RunOpts,
    mod: config.Module,
) !bool {
    // Priority: CLI overrides all; otherwise global + module are concatenated.
    const raw_flags = if (opts.cli_flags) |f| f else blk: {
        if (global_flags.len == 0) break :blk mod.clang_tidy_flags;
        if (mod.clang_tidy_flags.len == 0) break :blk global_flags;
        break :blk try std.mem.concat(allocator, u8, &.{ global_flags, " ", mod.clang_tidy_flags });
    };
    defer if (opts.cli_flags == null and global_flags.len > 0 and mod.clang_tidy_flags.len > 0)
        allocator.free(raw_flags);

    // Collect files matching patterns
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    for (mod.paths) |path| {
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
            std.debug.print("warning: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
            continue;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (opts.filter) |f| if (!matchGlob(f, entry.name)) continue;
            if (matchesPatterns(entry.name, mod.files)) {
                const full = try std.fs.path.join(allocator, &.{ path, entry.name });
                try files.append(allocator, full);
            }
        }
    }

    if (files.items.len == 0) {
        std.debug.print(green ++ "[ctf] module '{s}': no files found" ++ reset ++ "\n", .{mod.name});
        return true;
    }

    std.debug.print(green ++ "[ctf] module '{s}': {d} file(s)" ++ reset ++ "{s}\n\n", .{
        mod.name,
        files.items.len,
        if (opts.dry_run) " (dry run)" else "",
    });

    if (opts.dry_run) return true;

    // Build base argv: clang_tidy [flags] [--fix] [-p compile_commands]
    var base: std.ArrayList([]const u8) = .empty;
    defer base.deinit(allocator);
    try base.append(allocator, clang_tidy);
    var flag_iter = std.mem.tokenizeScalar(u8, raw_flags, ' ');
    while (flag_iter.next()) |f| try base.append(allocator, f);
    if (opts.fix) try base.append(allocator, "--fix");
    if (compile_commands) |cc| {
        try base.append(allocator, "-p");
        try base.append(allocator, cc);
    }

    var all_passed = true;

    if (opts.jobs <= 1 or opts.fix) {
        // Sequential: one clang-tidy invocation with all files.
        // fix mode is always sequential — parallel clang-tidy --fix causes race
        // conditions when multiple processes write to the same header file.
        var argv = try base.clone(allocator);
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, files.items);

        var child = std.process.Child.init(argv.items, allocator);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        const term = try child.wait();
        if (term != .Exited or term.Exited != 0) all_passed = false;
    } else {
        // Parallel: batches of `jobs` files, each file gets its own process
        var children = try allocator.alloc(std.process.Child, opts.jobs);
        defer allocator.free(children);
        var argvs = try allocator.alloc(std.ArrayList([]const u8), opts.jobs);
        defer allocator.free(argvs);

        var i: usize = 0;
        while (i < files.items.len) {
            const batch_end = @min(i + opts.jobs, files.items.len);
            const batch = files.items[i..batch_end];

            for (batch, 0..) |f, bi| {
                argvs[bi] = try base.clone(allocator);
                try argvs[bi].append(allocator, "--use-color");
                try argvs[bi].append(allocator, f);
                children[bi] = std.process.Child.init(argvs[bi].items, allocator);
                children[bi].stdout_behavior = .Pipe;
                children[bi].stderr_behavior = .Pipe;
                try children[bi].spawn();
            }

            for (batch, 0..) |f, bi| {
                defer argvs[bi].deinit(allocator);
                // Read stdout first (blocks until process exits + closes pipe).
                // stderr is tiny for clang-tidy (just the suppressed-warnings summary),
                // so it never fills the pipe buffer while we drain stdout.
                const out = try readPipe(allocator, children[bi].stdout.?);
                defer allocator.free(out);
                const err = try readPipe(allocator, children[bi].stderr.?);
                defer allocator.free(err);
                const term = try children[bi].wait();

                std.debug.print(green ++ "[ctf] [{d}/{d}] {s}" ++ reset ++ "\n", .{ i + bi + 1, files.items.len, f });
                if (out.len > 0) std.debug.print("{s}", .{out});
                if (err.len > 0) std.debug.print("{s}", .{err});

                switch (term) {
                    .Exited => |code| if (code != 0) { all_passed = false; },
                    else => all_passed = false,
                }
            }

            i = batch_end;
        }
    }

    return all_passed;
}

fn matchesPatterns(name: []const u8, patterns: []const u8) bool {
    var iter = std.mem.splitScalar(u8, patterns, ',');
    while (iter.next()) |p| {
        const pat = std.mem.trim(u8, p, " \t");
        if (pat.len > 0 and matchGlob(pat, name)) return true;
    }
    return false;
}

fn matchGlob(pattern: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (pattern[0] == '*') return std.mem.endsWith(u8, name, pattern[1..]);
    if (pattern[pattern.len - 1] == '*') return std.mem.startsWith(u8, name, pattern[0 .. pattern.len - 1]);
    return std.mem.eql(u8, pattern, name);
}

fn readPipe(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return list.toOwnedSlice(allocator);
}

// --- tests ---

test "matchGlob: wildcard" {
    try std.testing.expect(matchGlob("*", "anything.cpp"));
    try std.testing.expect(matchGlob("*", ""));
}

test "matchGlob: suffix (*.ext)" {
    try std.testing.expect(matchGlob("*.cpp", "foo.cpp"));
    try std.testing.expect(matchGlob("*.cpp", "a.b.cpp"));
    try std.testing.expect(!matchGlob("*.cpp", "foo.h"));
    try std.testing.expect(!matchGlob("*.h", "foo.hpp"));
    try std.testing.expect(matchGlob("*.hpp", "foo.hpp"));
}

test "matchGlob: prefix (foo*)" {
    try std.testing.expect(matchGlob("foo*", "foobar.cpp"));
    try std.testing.expect(matchGlob("foo*", "foo"));
    try std.testing.expect(!matchGlob("foo*", "barfoo"));
}

test "matchGlob: exact" {
    try std.testing.expect(matchGlob("main.cpp", "main.cpp"));
    try std.testing.expect(!matchGlob("main.cpp", "main.h"));
    try std.testing.expect(!matchGlob("main.cpp", "xmain.cpp"));
}

test "matchesPatterns: multi-pattern" {
    try std.testing.expect(matchesPatterns("foo.cpp", "*.cpp,*.hpp"));
    try std.testing.expect(matchesPatterns("foo.hpp", "*.cpp,*.hpp"));
    try std.testing.expect(!matchesPatterns("foo.h", "*.cpp,*.hpp"));
}
