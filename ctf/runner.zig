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

const SharedCtx = struct {
    mutex: std.Thread.Mutex = .{},
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    total: usize,
};

const FileTask = struct {
    clang_tidy: []const u8,
    flag_args: []const []const u8,
    compile_commands: ?[]const u8,
    file: []const u8,
    dry_run: bool,
    ctx: *SharedCtx,
};

fn runFileThread(task: FileTask) void {
    const n = task.ctx.counter.fetchAdd(1, .monotonic) + 1;

    task.ctx.mutex.lock();
    std.debug.print(green ++ "[ctf] [{d}/{d}] {s}" ++ reset ++ "\n", .{ n, task.ctx.total, task.file });
    task.ctx.mutex.unlock();

    if (task.dry_run) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(alloc, task.clang_tidy) catch return;
    argv.appendSlice(alloc, task.flag_args) catch return;
    if (task.compile_commands) |cc| {
        argv.append(alloc, "-p") catch return;
        argv.append(alloc, cc) catch return;
    }
    argv.append(alloc, task.file) catch return;

    var child = std.process.Child.init(argv.items, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch {
        task.ctx.failed.store(true, .monotonic);
        return;
    };

    // Read stdout and stderr in parallel to avoid pipe buffer deadlock.
    const Capture = struct {
        file: std.fs.File,
        result: []const u8 = "",
        fn run(self: *@This()) void {
            var capture_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            self.result = self.file.readToEndAlloc(capture_arena.allocator(), 50 * 1024 * 1024) catch "";
        }
    };
    var cap_out = Capture{ .file = child.stdout.? };
    var cap_err = Capture{ .file = child.stderr.? };
    const t_out = std.Thread.spawn(.{}, Capture.run, .{&cap_out}) catch null;
    const t_err = std.Thread.spawn(.{}, Capture.run, .{&cap_err}) catch null;
    if (t_out) |t| t.join();
    if (t_err) |t| t.join();

    const term = child.wait() catch {
        task.ctx.failed.store(true, .monotonic);
        return;
    };

    task.ctx.mutex.lock();
    defer task.ctx.mutex.unlock();
    if (cap_out.result.len > 0) std.fs.File.stdout().writeAll(cap_out.result) catch {};
    if (cap_err.result.len > 0) std.fs.File.stderr().writeAll(cap_err.result) catch {};

    switch (term) {
        .Exited => |code| if (code != 0) task.ctx.failed.store(true, .monotonic),
        else => task.ctx.failed.store(true, .monotonic),
    }
}

/// Returns true if all files passed clang-tidy (or dry-run).
pub fn run(
    allocator: std.mem.Allocator,
    clang_tidy: []const u8,
    global_flags: []const u8,
    compile_commands: ?[]const u8,
    opts: RunOpts,
    mod: config.Module,
) !bool {
    // Priority: CLI > per-module > global
    const raw_flags = opts.cli_flags orelse
        (if (mod.clang_tidy_flags.len > 0) mod.clang_tidy_flags else global_flags);

    // Collect patterns
    var patterns: std.ArrayList([]const u8) = .empty;
    defer patterns.deinit(allocator);
    var pat_iter = std.mem.splitScalar(u8, mod.files, ',');
    while (pat_iter.next()) |p| {
        const t = std.mem.trim(u8, p, " \t");
        if (t.len > 0) try patterns.append(allocator, t);
    }

    // Collect matching files
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
            for (patterns.items) |pat| {
                if (matchGlob(pat, entry.name)) {
                    const full = try std.fs.path.join(allocator, &.{ path, entry.name });
                    try files.append(allocator, full);
                    break;
                }
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

    // Build shared flag_args (read-only across threads)
    var flag_list: std.ArrayList([]const u8) = .empty;
    defer flag_list.deinit(allocator);
    var flag_iter = std.mem.tokenizeScalar(u8, raw_flags, ' ');
    while (flag_iter.next()) |f| try flag_list.append(allocator, f);
    if (opts.fix) try flag_list.append(allocator, "--fix");

    var ctx = SharedCtx{ .total = files.items.len };

    // Process in batches of `jobs`
    var i: usize = 0;
    while (i < files.items.len) {
        const end = @min(i + opts.jobs, files.items.len);
        const batch = files.items[i..end];

        const handles = try allocator.alloc(std.Thread, batch.len);
        defer allocator.free(handles);

        for (batch, 0..) |f, j| {
            handles[j] = try std.Thread.spawn(.{}, runFileThread, .{FileTask{
                .clang_tidy = clang_tidy,
                .flag_args = flag_list.items,
                .compile_commands = compile_commands,
                .file = f,
                .dry_run = opts.dry_run,
                .ctx = &ctx,
            }});
        }
        for (handles) |h| h.join();

        i = end;
    }

    return !ctx.failed.load(.monotonic);
}

fn matchGlob(pattern: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (pattern[0] == '*') return std.mem.endsWith(u8, name, pattern[1..]);
    if (pattern[pattern.len - 1] == '*') return std.mem.startsWith(u8, name, pattern[0 .. pattern.len - 1]);
    return std.mem.eql(u8, pattern, name);
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
