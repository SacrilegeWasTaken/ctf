const std = @import("std");

pub const Module = struct {
    name: []const u8,
    paths: []const []const u8,
    files: []const u8,
    clang_tidy_flags: []const u8, // "" = inherit global
};

pub const Config = struct {
    clang_tidy: []const u8,
    clang_tidy_flags: []const u8,
    compile_commands: ?[]const u8,
    fix: bool,
    dry_run: bool,
    filter: ?[]const u8,
    jobs: usize,
    modules: []const Module,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    pub fn findModule(self: Config, name: []const u8) ?Module {
        for (self.modules) |mod|
            if (std.mem.eql(u8, mod.name, name)) return mod;
        return null;
    }
};

pub fn parseFile(backing: std.mem.Allocator, path: []const u8) !Config {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    return parse(allocator, content, arena);
}

const Section = enum { none, config, modules, module };

fn parse(allocator: std.mem.Allocator, content: []const u8, arena: std.heap.ArenaAllocator) !Config {
    var modules: std.ArrayList(Module) = .empty;
    var clang_tidy: []const u8 = "clang-tidy";
    var clang_tidy_flags: []const u8 = "";
    var compile_commands: ?[]const u8 = null;
    var fix = false;
    var dry_run = false;
    var filter: ?[]const u8 = null;
    var jobs: usize = 1;

    var section: Section = .none;
    var cur_name: ?[]const u8 = null;
    var cur_paths: std.ArrayList([]const u8) = .empty;
    var cur_files: []const u8 = "";
    var cur_flags: []const u8 = "";
    var in_path_array = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (in_path_array) {
            const close_idx = std.mem.indexOfScalar(u8, line, ']');
            const content_part = line[0 .. close_idx orelse line.len];
            var parts = std.mem.splitScalar(u8, content_part, ',');
            while (parts.next()) |part| {
                const p = std.mem.trim(u8, part, " \t\"");
                if (p.len > 0) try cur_paths.append(allocator, p);
            }
            if (close_idx != null) in_path_array = false;
            continue;
        }

        if (std.mem.startsWith(u8, line, "[[")) {
            if (cur_name) |name| {
                try modules.append(allocator, .{
                    .name = name,
                    .paths = try cur_paths.toOwnedSlice(allocator),
                    .files = cur_files,
                    .clang_tidy_flags = cur_flags,
                });
            }
            const end = std.mem.indexOf(u8, line, "]]") orelse return error.InvalidToml;
            cur_name = line[2..end];
            cur_paths = .empty;
            cur_files = "";
            cur_flags = "";
            section = .module;
        } else if (line[0] == '[') {
            if (cur_name) |name| {
                try modules.append(allocator, .{
                    .name = name,
                    .paths = try cur_paths.toOwnedSlice(allocator),
                    .files = cur_files,
                    .clang_tidy_flags = cur_flags,
                });
                cur_name = null;
            }
            const end = std.mem.indexOfScalar(u8, line, ']') orelse return error.InvalidToml;
            const sec = line[1..end];
            section = if (std.mem.eql(u8, sec, "config")) .config else if (std.mem.eql(u8, sec, "modules")) .modules else .none;
        } else {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

            switch (section) {
                .config => {
                    if (std.mem.eql(u8, key, "clang-tidy"))
                        clang_tidy = std.mem.trim(u8, val, "\"")
                    else if (std.mem.eql(u8, key, "clang-tidy-flags"))
                        clang_tidy_flags = std.mem.trim(u8, val, "\"")
                    else if (std.mem.eql(u8, key, "compile-commands"))
                        compile_commands = std.mem.trim(u8, val, "\"")
                    else if (std.mem.eql(u8, key, "fix"))
                        fix = std.mem.eql(u8, val, "true")
                    else if (std.mem.eql(u8, key, "dry-run"))
                        dry_run = std.mem.eql(u8, val, "true")
                    else if (std.mem.eql(u8, key, "filter")) {
                        const f = std.mem.trim(u8, val, "\"");
                        if (f.len > 0) filter = f;
                    } else if (std.mem.eql(u8, key, "jobs")) {
                        jobs = std.fmt.parseInt(usize, val, 10) catch 1;
                        if (jobs == 0) jobs = 1;
                    }
                },
                .module => {
                    if (std.mem.eql(u8, key, "path")) {
                        const open = std.mem.indexOfScalar(u8, val, '[') orelse return error.InvalidToml;
                        const close_idx = std.mem.indexOfScalar(u8, val, ']');
                        const content_part = val[open + 1 .. close_idx orelse val.len];
                        var parts = std.mem.splitScalar(u8, content_part, ',');
                        while (parts.next()) |part| {
                            const p = std.mem.trim(u8, part, " \t\"");
                            if (p.len > 0) try cur_paths.append(allocator, p);
                        }
                        if (close_idx == null) in_path_array = true;
                    } else if (std.mem.eql(u8, key, "files"))
                        cur_files = std.mem.trim(u8, val, "\"")
                    else if (std.mem.eql(u8, key, "clang-tidy-flags"))
                        cur_flags = std.mem.trim(u8, val, "\"");
                },
                else => {},
            }
        }
    }

    if (cur_name) |name| {
        try modules.append(allocator, .{
            .name = name,
            .paths = try cur_paths.toOwnedSlice(allocator),
            .files = cur_files,
            .clang_tidy_flags = cur_flags,
        });
    }

    return .{
        .clang_tidy = clang_tidy,
        .clang_tidy_flags = clang_tidy_flags,
        .compile_commands = compile_commands,
        .fix = fix,
        .dry_run = dry_run,
        .filter = filter,
        .jobs = jobs,

        .modules = try modules.toOwnedSlice(allocator),
        .arena = arena,
    };
}

// --- tests ---

test "config: defaults when empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const cfg = try parse(arena.allocator(), "", arena);
    defer {
        var a = cfg.arena;
        a.deinit();
    }
    try std.testing.expectEqualStrings("clang-tidy", cfg.clang_tidy);
    try std.testing.expectEqualStrings("", cfg.clang_tidy_flags);
    try std.testing.expect(cfg.compile_commands == null);
    try std.testing.expectEqual(@as(usize, 0), cfg.modules.len);
}

test "config: parses [config] section" {
    const toml =
        \\[config]
        \\clang-tidy = "/usr/bin/clang-tidy"
        \\clang-tidy-flags = "--checks=*"
        \\compile-commands = "build/compile_commands.json"
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const cfg = try parse(arena.allocator(), toml, arena);
    defer {
        var a = cfg.arena;
        a.deinit();
    }
    try std.testing.expectEqualStrings("/usr/bin/clang-tidy", cfg.clang_tidy);
    try std.testing.expectEqualStrings("--checks=*", cfg.clang_tidy_flags);
    try std.testing.expectEqualStrings("build/compile_commands.json", cfg.compile_commands.?);
}

test "config: parses modules" {
    const toml =
        \\[modules]
        \\
        \\[[ACd]]
        \\path = ["src/ACd", "src/ACd/include"]
        \\files = "*.cpp,*.hpp"
        \\
        \\[[ACore]]
        \\path = ["src/ACore"]
        \\files = "*.c,*.h"
        \\clang-tidy-flags = "--checks=clang-analyzer-*"
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const cfg = try parse(arena.allocator(), toml, arena);
    defer {
        var a = cfg.arena;
        a.deinit();
    }
    try std.testing.expectEqual(@as(usize, 2), cfg.modules.len);
    try std.testing.expectEqualStrings("ACd", cfg.modules[0].name);
    try std.testing.expectEqual(@as(usize, 2), cfg.modules[0].paths.len);
    try std.testing.expectEqualStrings("src/ACd", cfg.modules[0].paths[0]);
    try std.testing.expectEqualStrings("src/ACd/include", cfg.modules[0].paths[1]);
    try std.testing.expectEqualStrings("*.cpp,*.hpp", cfg.modules[0].files);
    try std.testing.expectEqualStrings("", cfg.modules[0].clang_tidy_flags);
    try std.testing.expectEqualStrings("ACore", cfg.modules[1].name);
    try std.testing.expectEqualStrings("--checks=clang-analyzer-*", cfg.modules[1].clang_tidy_flags);
}

test "config: findModule found and not found" {
    const toml =
        \\[[Foo]]
        \\path = ["src/Foo"]
        \\files = "*.cpp"
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const cfg = try parse(arena.allocator(), toml, arena);
    defer {
        var a = cfg.arena;
        a.deinit();
    }
    try std.testing.expect(cfg.findModule("Foo") != null);
    try std.testing.expect(cfg.findModule("Bar") == null);
    try std.testing.expect(cfg.findModule("") == null);
}

test "config: ignores comments and blank lines" {
    const toml =
        \\# this is a comment
        \\
        \\[config]
        \\# another comment
        \\clang-tidy = "mytidy"
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const cfg = try parse(arena.allocator(), toml, arena);
    defer {
        var a = cfg.arena;
        a.deinit();
    }
    try std.testing.expectEqualStrings("mytidy", cfg.clang_tidy);
}

test "config: invalid toml - missing ]] in module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    try std.testing.expectError(error.InvalidToml, parse(arena.allocator(), "[[BadModule\n", arena));
}

test "config: invalid toml - path missing [" {
    const toml =
        \\[[Mod]]
        \\path = "src/Mod", "src/Mod/include"]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    try std.testing.expectError(error.InvalidToml, parse(arena.allocator(), toml, arena));
}

test "config: module with single path" {
    const toml =
        \\[[Solo]]
        \\path = ["src/Solo"]
        \\files = "*.cpp"
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const cfg = try parse(arena.allocator(), toml, arena);
    defer {
        var a = cfg.arena;
        a.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), cfg.modules[0].paths.len);
}
