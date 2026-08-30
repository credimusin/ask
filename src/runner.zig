const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = std.Io.File;
const Dir = std.Io.Dir;
const ui_mod = @import("ui.zig");
const Colors = ui_mod.Colors;

pub const AVAILABLE_KEYS = "abcdefghijklmnoprstuvwxz"; // 'q' is strictly reserved for quit, 'y' for copy/yank

pub const CodeSnippet = struct {
    key: u8,
    lang: []const u8,
    code: []const u8,
    is_multiline: bool,
};

pub const ScriptConfig = struct {
    interpreter: []const u8,
    ext: []const u8,
};

pub fn getScriptConfig(lang: []const u8) ScriptConfig {
    if (std.ascii.eqlIgnoreCase(lang, "python") or std.ascii.eqlIgnoreCase(lang, "python3") or std.ascii.eqlIgnoreCase(lang, "py")) {
        return .{ .interpreter = "python3", .ext = ".py" };
    } else if (std.ascii.eqlIgnoreCase(lang, "javascript") or std.ascii.eqlIgnoreCase(lang, "js") or std.ascii.eqlIgnoreCase(lang, "node") or std.ascii.eqlIgnoreCase(lang, "nodejs")) {
        return .{ .interpreter = "node", .ext = ".js" };
    } else if (std.ascii.eqlIgnoreCase(lang, "typescript") or std.ascii.eqlIgnoreCase(lang, "ts")) {
        return .{ .interpreter = "bun", .ext = ".ts" };
    } else if (std.ascii.eqlIgnoreCase(lang, "ruby") or std.ascii.eqlIgnoreCase(lang, "rb")) {
        return .{ .interpreter = "ruby", .ext = ".rb" };
    } else if (std.ascii.eqlIgnoreCase(lang, "perl") or std.ascii.eqlIgnoreCase(lang, "pl")) {
        return .{ .interpreter = "perl", .ext = ".pl" };
    } else if (std.ascii.eqlIgnoreCase(lang, "php")) {
        return .{ .interpreter = "php", .ext = ".php" };
    } else if (std.ascii.eqlIgnoreCase(lang, "lua")) {
        return .{ .interpreter = "lua", .ext = ".lua" };
    } else if (std.ascii.eqlIgnoreCase(lang, "r")) {
        return .{ .interpreter = "Rscript", .ext = ".R" };
    } else if (std.ascii.eqlIgnoreCase(lang, "zig")) {
        return .{ .interpreter = "zig run", .ext = ".zig" };
    } else if (std.ascii.eqlIgnoreCase(lang, "zsh")) {
        return .{ .interpreter = "zsh", .ext = ".zsh" };
    } else if (std.ascii.eqlIgnoreCase(lang, "fish")) {
        return .{ .interpreter = "fish", .ext = ".fish" };
    } else {
        return .{ .interpreter = "bash", .ext = ".sh" };
    }
}

pub fn isNonShellLanguage(lang: []const u8) bool {
    if (lang.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(lang, "bash") or
        std.ascii.eqlIgnoreCase(lang, "sh") or
        std.ascii.eqlIgnoreCase(lang, "shell") or
        std.ascii.eqlIgnoreCase(lang, "zsh") or
        std.ascii.eqlIgnoreCase(lang, "fish") or
        std.ascii.eqlIgnoreCase(lang, "console") or
        std.ascii.eqlIgnoreCase(lang, "terminal"))
    {
        return false;
    }
    return true;
}

pub fn extractCodeSnippets(allocator: Allocator, text: []const u8) []const CodeSnippet {
    var snippets: std.ArrayList(CodeSnippet) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_code_block = false;
    var current_lang: []const u8 = "";
    var current_code: std.ArrayList(u8) = .empty;
    defer current_code.deinit(allocator);
    var block_idx: usize = 0;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (!in_code_block) {
                in_code_block = true;
                current_lang = std.mem.trim(u8, trimmed[3..], " \t`");
                current_code.clearRetainingCapacity();
            } else {
                in_code_block = false;
                const trimmed_code = std.mem.trim(u8, current_code.items, " \t\r\n");
                if (trimmed_code.len > 0) {
                    const key_char = if (block_idx < AVAILABLE_KEYS.len) AVAILABLE_KEYS[block_idx] else 'a';
                    const is_multi = std.mem.indexOfScalar(u8, trimmed_code, '\n') != null;
                    const code_copy = allocator.dupe(u8, trimmed_code) catch continue;
                    const lang_copy = allocator.dupe(u8, current_lang) catch "";

                    snippets.append(allocator, .{
                        .key = key_char,
                        .lang = lang_copy,
                        .code = code_copy,
                        .is_multiline = is_multi,
                    }) catch continue;
                    block_idx += 1;
                }
            }
            continue;
        }

        if (in_code_block) {
            if (current_code.items.len > 0) {
                current_code.append(allocator, '\n') catch continue;
            }
            current_code.appendSlice(allocator, line) catch continue;
        }
    }

    if (in_code_block) {
        const trimmed_code = std.mem.trim(u8, current_code.items, " \t\r\n");
        if (trimmed_code.len > 0) {
            const key_char = if (block_idx < AVAILABLE_KEYS.len) AVAILABLE_KEYS[block_idx] else 'a';
            const is_multi = std.mem.indexOfScalar(u8, trimmed_code, '\n') != null;
            const code_copy = allocator.dupe(u8, trimmed_code) catch null;
            const lang_copy = allocator.dupe(u8, current_lang) catch "";

            if (code_copy) |cc| {
                snippets.append(allocator, .{
                    .key = key_char,
                    .lang = lang_copy,
                    .code = cc,
                    .is_multiline = is_multi,
                }) catch {};
            }
        }
    }

    return snippets.toOwnedSlice(allocator) catch &[_]CodeSnippet{};
}

pub fn copyToClipboard(io: Io, stdout: File, allocator: Allocator, text: []const u8) void {
    // 1. Universal OSC 52 escape sequence
    const encoded_len = std.base64.standard.Encoder.calcSize(text.len);
    const b64_buf = allocator.alloc(u8, encoded_len) catch return;
    defer allocator.free(b64_buf);
    _ = std.base64.standard.Encoder.encode(b64_buf, text);

    const osc52 = std.fmt.allocPrint(allocator, "\x1b]52;c;{s}\x07", .{b64_buf}) catch return;
    defer allocator.free(osc52);
    stdout.writeStreamingAll(io, osc52) catch {};

    // 2. Also try wl-copy or xclip in the background
    var wl_child = std.process.spawn(io, .{
        .argv = &.{ "wl-copy", text },
    }) catch null;
    if (wl_child) |*c| {
        _ = c.wait(io) catch {};
    } else {
        var xclip_child = std.process.spawn(io, .{
            .argv = &.{ "xclip", "-selection", "clipboard" },
        }) catch null;
        if (xclip_child) |*c| {
            _ = c.wait(io) catch {};
        }
    }
}

pub const PreparedCommand = struct {
    display_cmd: []const u8,
    temp_file: ?[]const u8 = null,
};

pub fn prepareSnippetCommand(
    allocator: Allocator,
    io: Io,
    snippet: CodeSnippet,
) !PreparedCommand {
    const pid = std.os.linux.getpid();
    const is_lang = isNonShellLanguage(snippet.lang);

    if (snippet.is_multiline or is_lang) {
        const cfg = getScriptConfig(snippet.lang);
        const temp_path = try std.fmt.allocPrint(
            allocator,
            "/tmp/ask_run_{c}_{d}{s}",
            .{ snippet.key, pid, cfg.ext },
        );

        const file = try Dir.createFileAbsolute(io, temp_path, .{});
        defer file.close(io);
        file.setPermissions(io, File.Permissions.fromMode(0o700)) catch {};
        try file.writeStreamingAll(io, snippet.code);
        try file.writeStreamingAll(io, "\n");

        const display_cmd = try std.fmt.allocPrint(
            allocator,
            "{s} {s}",
            .{ cfg.interpreter, temp_path },
        );

        return PreparedCommand{
            .display_cmd = display_cmd,
            .temp_file = temp_path,
        };
    } else {
        return PreparedCommand{
            .display_cmd = try allocator.dupe(u8, snippet.code),
            .temp_file = null,
        };
    }
}

fn findSnippetByKey(snippets: []const CodeSnippet, key: u8) ?*const CodeSnippet {
    for (snippets) |*s| {
        if (s.key == key) return s;
    }
    return null;
}

pub fn promptAndExecute(
    allocator: Allocator,
    io: Io,
    stdout: File,
    stdin: File,
    environ_map: *std.process.Environ.Map,
    snippets: []const CodeSnippet,
) void {
    var tty_in: ?File = null;
    defer if (tty_in) |tf| tf.close(io);

    const is_stdin_tty = stdin.isTty(io) catch false;
    const input_file = if (is_stdin_tty)
        stdin
    else blk: {
        const opened = Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_only }) catch null;
        if (opened) |f| {
            tty_in = f;
            break :blk f;
        }
        return;
    };

    // Terminal raw mode
    const input_fd: std.posix.fd_t = input_file.handle;
    const orig_termios = std.posix.tcgetattr(input_fd) catch null;
    if (orig_termios) |orig| {
        var raw = orig;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = true;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(input_fd, .FLUSH, raw) catch {};
    }
    defer {
        if (orig_termios) |orig| {
            std.posix.tcsetattr(input_fd, .FLUSH, orig) catch {};
        }
    }

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(allocator);

    var active_temp_file: ?[]const u8 = null;
    defer {
        if (active_temp_file) |tf| {
            Dir.deleteFileAbsolute(io, tf) catch {};
        }
    }

    var selected_snippet_key: ?u8 = null;

    const renderPrompt = struct {
        fn draw(
            s_io: Io,
            s_stdout: File,
            s_allocator: Allocator,
            buf: []const u8,
            snips: []const CodeSnippet,
        ) void {
            const P = Colors.primary ++ Colors.bold;
            const S = Colors.secondary ++ Colors.bold;
            const D = Colors.text_dim;
            const R = Colors.reset;

            if (buf.len == 0) {
                var keys_buf: [32]u8 = undefined;
                var pos: usize = 0;
                for (snips, 0..) |s, idx| {
                    if (idx > 0) {
                        keys_buf[pos] = '/';
                        pos += 1;
                    }
                    keys_buf[pos] = s.key;
                    pos += 1;
                }
                const keys_slice = keys_buf[0..pos];

                const msg = std.fmt.allocPrint(
                    s_allocator,
                    "\r\x1b[2K{s}Press {s}{s}{s} to run, {s}y{s} to copy, {s}q{s} to quit{s}",
                    .{
                        D,
                        Colors.primary ++ Colors.bold,
                        keys_slice,
                        D,
                        Colors.highlight ++ Colors.bold,
                        D,
                        Colors.error_color ++ Colors.bold,
                        D,
                        R,
                    },
                ) catch return;
                defer s_allocator.free(msg);
                s_stdout.writeStreamingAll(s_io, msg) catch {};
            } else {
                const msg = std.fmt.allocPrint(
                    s_allocator,
                    "\r\x1b[2K{s}Run{s} {s}❯{s} {s}{s}{s}",
                    .{ P, R, S, R, Colors.text, buf, R },
                ) catch return;
                defer s_allocator.free(msg);
                s_stdout.writeStreamingAll(s_io, msg) catch {};
            }
        }
    }.draw;

    renderPrompt(io, stdout, allocator, line_buf.items, snippets);

    var char_buf: [1]u8 = undefined;
    var iov = [_][]u8{&char_buf};

    while (true) {
        const amt = input_file.readStreaming(io, &iov) catch break;
        if (amt == 0) break;
        const b = char_buf[0];

        // 1. Ctrl+C, Ctrl+D, Escape
        if (b == 0x03 or b == 0x04 or b == 0x1B) {
            stdout.writeStreamingAll(io, "\r\x1b[2K\n") catch {};
            return;
        }

        // 2. 'q' / 'Q' quit when buffer is empty
        if ((b == 'q' or b == 'Q') and line_buf.items.len == 0) {
            stdout.writeStreamingAll(io, "\r\x1b[2K\n") catch {};
            return;
        }

        // 3. 'y' / 'Y' copy when buffer is empty -> copy and exit immediately
        if ((b == 'y' or b == 'Y') and line_buf.items.len == 0) {
            const target_snip = if (selected_snippet_key) |sk|
                findSnippetByKey(snippets, sk) orelse &snippets[0]
            else
                &snippets[0];

            copyToClipboard(io, stdout, allocator, target_snip.code);

            const copy_msg = if (snippets.len > 1)
                std.fmt.allocPrint(
                    allocator,
                    "\r\x1b[2K{s}✓ Copied [{c}] to clipboard!{s}\n",
                    .{ Colors.success ++ Colors.bold, target_snip.key, Colors.reset },
                ) catch return
            else
                std.fmt.allocPrint(
                    allocator,
                    "\r\x1b[2K{s}✓ Copied to clipboard!{s}\n",
                    .{ Colors.success ++ Colors.bold, Colors.reset },
                ) catch return;
            defer allocator.free(copy_msg);
            stdout.writeStreamingAll(io, copy_msg) catch {};
            return;
        }

        // 4. Backspace / Delete
        if (b == 0x7F or b == 0x08) {
            if (line_buf.items.len > 0) {
                _ = line_buf.pop();
                renderPrompt(io, stdout, allocator, line_buf.items, snippets);
            }
            continue;
        }

        // 5. Enter key (execute!)
        if (b == '\r' or b == '\n') {
            if (line_buf.items.len == 0) {
                if (snippets.len == 1) {
                    const prep = prepareSnippetCommand(allocator, io, snippets[0]) catch break;
                    active_temp_file = prep.temp_file;
                    line_buf.clearRetainingCapacity();
                    line_buf.appendSlice(allocator, prep.display_cmd) catch break;
                } else {
                    stdout.writeStreamingAll(io, "\r\x1b[2K\n") catch {};
                    return;
                }
            }
            break;
        }

        // 7. Check if char matches snippet key (letters 'a'..'z' or digits '1'..'9')
        if (line_buf.items.len == 0) {
            var matched_snip: ?*const CodeSnippet = null;

            for (snippets) |*s| {
                if (s.key == b or (std.ascii.toLower(b) == s.key)) {
                    matched_snip = s;
                    break;
                }
            }

            if (matched_snip == null and std.ascii.isDigit(b) and b >= '1') {
                const idx: usize = b - '1';
                if (idx < snippets.len) {
                    matched_snip = &snippets[idx];
                }
            }

            if (matched_snip) |snip| {
                selected_snippet_key = snip.key;
                if (active_temp_file) |tf| {
                    Dir.deleteFileAbsolute(io, tf) catch {};
                    active_temp_file = null;
                }

                const prep = prepareSnippetCommand(allocator, io, snip.*) catch continue;
                active_temp_file = prep.temp_file;
                line_buf.clearRetainingCapacity();
                line_buf.appendSlice(allocator, prep.display_cmd) catch continue;

                renderPrompt(io, stdout, allocator, line_buf.items, snippets);
                continue;
            }
        }

        // 8. Normal character typing (editing / manual command)
        if (b >= 0x20 and b < 0x7F) {
            line_buf.append(allocator, b) catch continue;
            renderPrompt(io, stdout, allocator, line_buf.items, snippets);
        }
    }

    if (line_buf.items.len == 0) {
        stdout.writeStreamingAll(io, "\r\x1b[2K\n") catch {};
        return;
    }

    const command_to_run = std.mem.trim(u8, line_buf.items, " \t\r\n");
    if (command_to_run.len == 0) {
        stdout.writeStreamingAll(io, "\r\x1b[2K\n") catch {};
        return;
    }

    // Restore terminal settings before execution
    if (orig_termios) |orig| {
        std.posix.tcsetattr(input_fd, .FLUSH, orig) catch {};
    }

    const finalize_line = std.fmt.allocPrint(
        allocator,
        "\r\x1b[2K{s}Run{s} {s}❯{s} {s}{s}{s}\n\n",
        .{ Colors.primary ++ Colors.bold, Colors.reset, Colors.secondary ++ Colors.bold, Colors.reset, Colors.code_line, command_to_run, Colors.reset },
    ) catch return;
    defer allocator.free(finalize_line);
    stdout.writeStreamingAll(io, finalize_line) catch {};

    const shell = environ_map.get("SHELL") orelse "/bin/sh";
    var child = std.process.spawn(io, .{
        .argv = &.{ shell, "-c", command_to_run },
        .environ_map = environ_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        const err_msg = std.fmt.allocPrint(allocator, "{s}Error running command: {}{s}\n", .{ Colors.error_color, err, Colors.reset }) catch return;
        defer allocator.free(err_msg);
        stdout.writeStreamingAll(io, err_msg) catch {};
        return;
    };

    const term = child.wait(io) catch return;

    if (active_temp_file) |tf| {
        Dir.deleteFileAbsolute(io, tf) catch {};
        active_temp_file = null;
    }

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.process.exit(code);
            }
        },
        else => std.process.exit(1),
    }
}

test "AVAILABLE_KEYS does not contain q or y" {
    try std.testing.expect(AVAILABLE_KEYS.len == 24);
    try std.testing.expect(std.mem.indexOfScalar(u8, AVAILABLE_KEYS, 'q') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, AVAILABLE_KEYS, 'y') == null);
}

test "getScriptConfig mappings" {
    try std.testing.expectEqualStrings("python3", getScriptConfig("python").interpreter);
    try std.testing.expectEqualStrings(".py", getScriptConfig("python").ext);

    try std.testing.expectEqualStrings("node", getScriptConfig("javascript").interpreter);
    try std.testing.expectEqualStrings(".js", getScriptConfig("js").ext);

    try std.testing.expectEqualStrings("ruby", getScriptConfig("ruby").interpreter);
    try std.testing.expectEqualStrings(".rb", getScriptConfig("rb").ext);

    try std.testing.expectEqualStrings("bash", getScriptConfig("bash").interpreter);
    try std.testing.expectEqualStrings(".sh", getScriptConfig("sh").ext);

    try std.testing.expectEqualStrings("zig run", getScriptConfig("zig").interpreter);
    try std.testing.expectEqualStrings(".zig", getScriptConfig("zig").ext);
}

test "extractCodeSnippets extraction" {
    const allocator = std.testing.allocator;
    const text =
        \\Here is the command to check files:
        \\```bash
        \\ls -la /tmp
        \\```
        \\And here is a python script:
        \\```python
        \\import sys
        \\print(sys.version)
        \\```
    ;

    const snippets = extractCodeSnippets(allocator, text);
    defer {
        for (snippets) |s| {
            allocator.free(s.code);
            allocator.free(s.lang);
        }
        allocator.free(snippets);
    }

    try std.testing.expectEqual(@as(usize, 2), snippets.len);

    try std.testing.expectEqual('a', snippets[0].key);
    try std.testing.expectEqualStrings("bash", snippets[0].lang);
    try std.testing.expectEqualStrings("ls -la /tmp", snippets[0].code);
    try std.testing.expect(!snippets[0].is_multiline);

    try std.testing.expectEqual('b', snippets[1].key);
    try std.testing.expectEqualStrings("python", snippets[1].lang);
    try std.testing.expect(snippets[1].is_multiline);
}

test "prepareSnippetCommand single line vs multiline" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const single_snippet = CodeSnippet{
        .key = 'a',
        .lang = "bash",
        .code = "git status",
        .is_multiline = false,
    };

    const prep_single = try prepareSnippetCommand(allocator, io, single_snippet);
    defer allocator.free(prep_single.display_cmd);
    try std.testing.expectEqualStrings("git status", prep_single.display_cmd);
    try std.testing.expect(prep_single.temp_file == null);

    const multi_snippet = CodeSnippet{
        .key = 'b',
        .lang = "python",
        .code = "import os\nprint(os.getcwd())",
        .is_multiline = true,
    };

    const prep_multi = try prepareSnippetCommand(allocator, io, multi_snippet);
    defer {
        allocator.free(prep_multi.display_cmd);
        if (prep_multi.temp_file) |tf| {
            Dir.deleteFileAbsolute(io, tf) catch {};
            allocator.free(tf);
        }
    }

    try std.testing.expect(prep_multi.temp_file != null);
    try std.testing.expect(std.mem.startsWith(u8, prep_multi.display_cmd, "python3 /tmp/ask_run_b_"));
}
