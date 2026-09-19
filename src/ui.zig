const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = std.Io.File;

pub const Colors = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const italic = "\x1b[3m";
    pub const underline = "\x1b[4m";

    // Catppuccin Macchiato truecolors
    pub const primary = "\x1b[38;2;138;173;244m"; // Sapphire #8aadf4
    pub const secondary = "\x1b[38;2;139;213;202m"; // Teal #8bd5ca
    pub const highlight = "\x1b[38;2;245;189;230m"; // Mauve #f5bde6
    pub const flamingo = "\x1b[38;2;244;219;214m"; // Flamingo #f4dbd6
    pub const warn = "\x1b[38;2;238;212;159m"; // Peach #eed49f
    pub const error_color = "\x1b[38;2;237;135;150m"; // Red #ed8796
    pub const success = "\x1b[38;2;166;218;149m"; // Green #a6da95
    pub const text = "\x1b[38;2;202;211;245m"; // Text #cad3f5
    pub const text_dim = "\x1b[38;2;110;115;141m"; // Gray #6e738d
    pub const border = "\x1b[38;2;73;77;100m"; // Surface #494d64
    pub const border_bright = "\x1b[38;2;91;96;120m"; // Surface1 #5b6078
    pub const code_line = "\x1b[38;2;184;192;224m"; // Subtext0 #b8c0e0
};

pub fn getBoxWidth() usize {
    var ws: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0 and ws.col > 0) {
        const c: usize = ws.col;
        if (c < 48) return 44;
        if (c > 110) return 100;
        return c - 4;
    }
    return 68;
}

pub fn visualWidth(str: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        if (str[i] == 0x1B) {
            i += 1;
            if (i < str.len and str[i] == '[') {
                i += 1;
                while (i < str.len) : (i += 1) {
                    const c = str[i];
                    if (c >= 0x40 and c <= 0x7E) {
                        i += 1;
                        break;
                    }
                }
            } else if (i < str.len and str[i] == ']') {
                i += 1;
                while (i < str.len) : (i += 1) {
                    if (str[i] == 0x07 or (str[i] == 0x1B and i + 1 < str.len and str[i + 1] == '\\')) {
                        if (str[i] == 0x1B) i += 1;
                        i += 1;
                        break;
                    }
                }
            }
            continue;
        }

        const b = str[i];
        if ((b & 0xC0) != 0x80) {
            width += 1;
        }
        i += 1;
    }
    return width;
}

pub fn formatModelShort(allocator: Allocator, model: []const u8, is_fallback: bool) ![]const u8 {
    var base: []const u8 = model;
    var allocated_base: ?[]const u8 = null;
    defer if (allocated_base) |b| allocator.free(b);

    if (std.mem.startsWith(u8, model, "gemini-")) {
        const rest = model["gemini-".len..];
        if (std.mem.indexOfScalar(u8, rest, '-')) |dash_idx| {
            const ver = rest[0..dash_idx];
            const suffix = rest[dash_idx + 1 ..];
            if (std.mem.eql(u8, suffix, "flash-lite")) {
                allocated_base = try std.fmt.allocPrint(allocator, "Gemini-{s}FL", .{ver});
            } else if (std.mem.eql(u8, suffix, "flash")) {
                allocated_base = try std.fmt.allocPrint(allocator, "Gemini-{s}F", .{ver});
            } else if (std.mem.eql(u8, suffix, "pro")) {
                allocated_base = try std.fmt.allocPrint(allocator, "Gemini-{s}P", .{ver});
            } else if (std.mem.eql(u8, suffix, "thinking")) {
                allocated_base = try std.fmt.allocPrint(allocator, "Gemini-{s}T", .{ver});
            } else if (std.mem.startsWith(u8, suffix, "flash-")) {
                allocated_base = try std.fmt.allocPrint(allocator, "Gemini-{s}F-{s}", .{ ver, suffix["flash-".len..] });
            } else {
                allocated_base = try std.fmt.allocPrint(allocator, "Gemini-{s}-{s}", .{ ver, suffix });
            }
            base = allocated_base.?;
        } else {
            allocated_base = try std.fmt.allocPrint(allocator, "Gemini-{s}", .{rest});
            base = allocated_base.?;
        }
    } else if (std.mem.startsWith(u8, model, "gemma-")) {
        const rest = model["gemma-".len..];
        if (std.mem.endsWith(u8, rest, "-it")) {
            const without_it = rest[0 .. rest.len - 3];
            var upper_buf = try allocator.alloc(u8, without_it.len);
            for (without_it, 0..) |c, idx| {
                upper_buf[idx] = std.ascii.toUpper(c);
            }
            allocated_base = try std.fmt.allocPrint(allocator, "Gemma-{s}", .{upper_buf});
            allocator.free(upper_buf);
            base = allocated_base.?;
        } else {
            allocated_base = try std.fmt.allocPrint(allocator, "Gemma-{s}", .{rest});
            base = allocated_base.?;
        }
    }

    if (is_fallback) {
        return try std.fmt.allocPrint(allocator, "{s} (F)", .{base});
    } else {
        return try allocator.dupe(u8, base);
    }
}

pub fn calculateCostUsd(model: []const u8, prompt_tokens: i64, cand_tokens: i64) f64 {
    var p_rate: f64 = 0.075 / 1_000_000.0;
    var c_rate: f64 = 0.30 / 1_000_000.0;

    if (std.mem.indexOf(u8, model, "pro") != null) {
        p_rate = 1.25 / 1_000_000.0;
        c_rate = 5.00 / 1_000_000.0;
    } else if (std.mem.indexOf(u8, model, "flash-lite") != null) {
        p_rate = 0.075 / 1_000_000.0;
        c_rate = 0.30 / 1_000_000.0;
    } else if (std.mem.indexOf(u8, model, "flash") != null) {
        p_rate = 0.10 / 1_000_000.0;
        c_rate = 0.40 / 1_000_000.0;
    } else if (std.mem.indexOf(u8, model, "gemma") != null) {
        p_rate = 0.0;
        c_rate = 0.0;
    }

    const p_f: f64 = @floatFromInt(@max(0, prompt_tokens));
    const c_f: f64 = @floatFromInt(@max(0, cand_tokens));
    return (p_f * p_rate) + (c_f * c_rate);
}

fn writeDashes(allocator: Allocator, count: usize) ![]const u8 {
    var buf = try allocator.alloc(u8, count * 3); // UTF-8 "─" is 3 bytes (0xE2 0x94 0x80)
    var i: usize = 0;
    while (i < count) : (i += 1) {
        buf[i * 3 + 0] = 0xE2;
        buf[i * 3 + 1] = 0x94;
        buf[i * 3 + 2] = 0x80;
    }
    return buf;
}

pub const Spinner = struct {
    running: *std.atomic.Value(bool),
    thread: ?std.Thread,

    pub fn start(allocator: Allocator, msg: []const u8) !Spinner {
        const running_ptr = try allocator.create(std.atomic.Value(bool));
        running_ptr.* = std.atomic.Value(bool).init(true);

        const thread = try std.Thread.spawn(.{}, runSpinner, .{ running_ptr, msg });
        return Spinner{
            .running = running_ptr,
            .thread = thread,
        };
    }

    pub fn stop(self: *Spinner, allocator: Allocator) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        allocator.destroy(self.running);
        std.debug.print("\r\x1b[2K", .{});
    }
};

pub fn sleepMs(ms: u64) void {
    const sec: i64 = @intCast(ms / 1000);
    const nsec: i64 = @intCast((ms % 1000) * 1000 * 1000);
    const ts = std.os.linux.timespec{ .sec = sec, .nsec = nsec };
    _ = std.os.linux.nanosleep(&ts, null);
}

fn runSpinner(running: *std.atomic.Value(bool), msg: []const u8) void {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var i: usize = 0;
    while (running.load(.acquire)) {
        std.debug.print("\r\x1b[2K  {s}{s}{s} {s}{s}{s}", .{
            Colors.secondary ++ Colors.bold,
            frames[i % frames.len],
            Colors.reset,
            Colors.code_line,
            msg,
            Colors.reset,
        });
        i += 1;
        sleepMs(80);
    }
    std.debug.print("\r\x1b[2K", .{});
}

pub fn printBanner(io: Io, stdout: File, allocator: Allocator, model: []const u8, is_fallback: bool) void {
    const short_model = formatModelShort(allocator, model, is_fallback) catch model;
    defer if (!std.mem.eql(u8, short_model, model)) allocator.free(short_model);

    const box_w = getBoxWidth();
    // "╭── " (4) + "✦ Ask (" (7) + visualWidth(short_model) + ") " (2)
    const prefix_len = 4 + 7 + visualWidth(short_model) + 2;
    const dashes_count = if (box_w > prefix_len) box_w - prefix_len else 4;
    const dashes = writeDashes(allocator, dashes_count) catch return;
    defer allocator.free(dashes);

    const banner = if (is_fallback)
        std.fmt.allocPrint(
            allocator,
            "\n{s}╭──{s} {s}✦ Ask{s} {s}({s}{s}{s}){s} {s}{s}{s}\n\n",
            .{
                Colors.border,
                Colors.reset,
                Colors.primary ++ Colors.bold,
                Colors.reset,
                Colors.text_dim,
                Colors.warn,
                short_model,
                Colors.text_dim,
                Colors.reset,
                Colors.border,
                dashes,
                Colors.reset,
            },
        ) catch return
    else
        std.fmt.allocPrint(
            allocator,
            "\n{s}╭──{s} {s}✦ Ask{s} {s}({s}){s} {s}{s}{s}\n\n",
            .{
                Colors.border,
                Colors.reset,
                Colors.primary ++ Colors.bold,
                Colors.reset,
                Colors.text_dim,
                short_model,
                Colors.reset,
                Colors.border,
                dashes,
                Colors.reset,
            },
        ) catch return;
    defer allocator.free(banner);
    stdout.writeStreamingAll(io, banner) catch {};
}

pub fn printTuiResponseHeader(io: Io, stdout: File, allocator: Allocator, model: []const u8, is_fallback: bool) void {
    const box_w = getBoxWidth();
    if (is_fallback) {
        const short_model = formatModelShort(allocator, model, true) catch model;
        defer if (!std.mem.eql(u8, short_model, model)) allocator.free(short_model);

        const prefix_len = 4 + 2 + visualWidth(short_model) + 1; // "╭── ✦ " (6) + name + " " (1)
        const dashes_count = if (box_w > prefix_len) box_w - prefix_len else 4;
        const dashes = writeDashes(allocator, dashes_count) catch return;
        defer allocator.free(dashes);

        const banner = std.fmt.allocPrint(
            allocator,
            "\n{s}╭──{s} {s}✦ {s}{s} {s}{s}{s}\n\n",
            .{
                Colors.border,
                Colors.reset,
                Colors.warn ++ Colors.bold,
                short_model,
                Colors.reset,
                Colors.border,
                dashes,
                Colors.reset,
            },
        ) catch return;
        defer allocator.free(banner);
        stdout.writeStreamingAll(io, banner) catch {};
    } else {
        const dashes_count = if (box_w > 1) box_w - 1 else 10;
        const dashes = writeDashes(allocator, dashes_count) catch return;
        defer allocator.free(dashes);

        const banner = std.fmt.allocPrint(
            allocator,
            "\n{s}╭{s}{s}\n\n",
            .{ Colors.border, dashes, Colors.reset },
        ) catch return;
        defer allocator.free(banner);
        stdout.writeStreamingAll(io, banner) catch {};
    }
}

pub fn printFooter(
    io: Io,
    stdout: File,
    allocator: Allocator,
    elapsed_ms: u64,
    prompt_tokens: ?i64,
    cand_tokens: ?i64,
    model: ?[]const u8,
) void {
    var stats_buf: [96]u8 = undefined;
    var stats_str: []const u8 = "";

    const sec: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    if (prompt_tokens != null and cand_tokens != null) {
        const total_tokens = prompt_tokens.? + cand_tokens.?;
        const cost = calculateCostUsd(model orelse "", prompt_tokens.?, cand_tokens.?);
        if (cost < 0.00001 and cost > 0.0) {
            stats_str = std.fmt.bufPrint(
                &stats_buf,
                "{d:.2}s • {d} tokens • <$0.00001",
                .{ sec, total_tokens },
            ) catch "";
        } else if (cost == 0.0) {
            stats_str = std.fmt.bufPrint(
                &stats_buf,
                "{d:.2}s • {d} tokens",
                .{ sec, total_tokens },
            ) catch "";
        } else if (cost < 0.01) {
            stats_str = std.fmt.bufPrint(
                &stats_buf,
                "{d:.2}s • {d} tokens • ${d:.5}",
                .{ sec, total_tokens, cost },
            ) catch "";
        } else {
            stats_str = std.fmt.bufPrint(
                &stats_buf,
                "{d:.2}s • {d} tokens • ${d:.3}",
                .{ sec, total_tokens, cost },
            ) catch "";
        }
    } else {
        stats_str = std.fmt.bufPrint(
            &stats_buf,
            "{d:.2}s",
            .{sec},
        ) catch "";
    }

    const box_w = getBoxWidth();
    // Visual length: "╰── [ " (6) + visualWidth(stats_str) + " ] " (3)
    const prefix_len = 6 + visualWidth(stats_str) + 3;
    const dashes_count = if (box_w > prefix_len) box_w - prefix_len else 4;
    const dashes = writeDashes(allocator, dashes_count) catch return;
    defer allocator.free(dashes);

    const footer = std.fmt.allocPrint(
        allocator,
        "\n{s}╰── [{s} {s}{s}{s} {s}]{s} {s}{s}{s}\n\n",
        .{
            Colors.border,
            Colors.reset,
            Colors.text_dim,
            stats_str,
            Colors.reset,
            Colors.border,
            Colors.reset,
            Colors.border,
            dashes,
            Colors.reset,
        },
    ) catch return;
    defer allocator.free(footer);
    stdout.writeStreamingAll(io, footer) catch {};
}

pub fn formatInline(allocator: Allocator, input: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;

    while (i < input.len) {
        // 1. Inline code: `code`
        if (input[i] == '`') {
            const rest = input[i + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '`')) |close_idx| {
                const code_content = rest[0..close_idx];
                out.appendSlice(allocator, Colors.highlight ++ Colors.bold) catch break;
                out.appendSlice(allocator, code_content) catch break;
                out.appendSlice(allocator, Colors.reset ++ Colors.text) catch break;
                i = i + 1 + close_idx + 1;
                continue;
            }
        }

        // 2. Bold text: **bold** or __bold__
        if (i + 1 < input.len and ((input[i] == '*' and input[i + 1] == '*') or (input[i] == '_' and input[i + 1] == '_'))) {
            const delim = input[i .. i + 2];
            const rest = input[i + 2 ..];
            if (std.mem.indexOf(u8, rest, delim)) |close_idx| {
                const bold_content = rest[0..close_idx];
                out.appendSlice(allocator, Colors.bold ++ Colors.flamingo) catch break;
                const formatted_inner = formatInline(allocator, bold_content);
                defer allocator.free(formatted_inner);
                out.appendSlice(allocator, formatted_inner) catch break;
                out.appendSlice(allocator, Colors.reset ++ Colors.text) catch break;
                i = i + 2 + close_idx + 2;
                continue;
            }
        }

        // 3. Markdown links: [text](url)
        if (input[i] == '[') {
            const rest = input[i + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, ']')) |close_bracket| {
                const after_bracket = rest[close_bracket + 1 ..];
                if (after_bracket.len > 1 and after_bracket[0] == '(') {
                    const in_paren = after_bracket[1..];
                    if (std.mem.indexOfScalar(u8, in_paren, ')')) |close_paren| {
                        const link_text = rest[0..close_bracket];
                        const link_url = in_paren[0..close_paren];

                        out.appendSlice(allocator, Colors.underline ++ Colors.primary) catch break;
                        out.appendSlice(allocator, link_text) catch break;
                        out.appendSlice(allocator, Colors.reset ++ Colors.text_dim ++ " (") catch break;
                        out.appendSlice(allocator, link_url) catch break;
                        out.appendSlice(allocator, ")" ++ Colors.reset ++ Colors.text) catch break;

                        i = i + 1 + close_bracket + 1 + 1 + close_paren + 1;
                        continue;
                    }
                }
            }
        }

        // 4. Italic text: *italic* or _italic_
        if ((input[i] == '*' or input[i] == '_') and (i + 1 < input.len and input[i + 1] != ' ')) {
            const delim = input[i];
            const rest = input[i + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, delim)) |close_idx| {
                const italic_content = rest[0..close_idx];
                out.appendSlice(allocator, Colors.italic ++ Colors.secondary) catch break;
                out.appendSlice(allocator, italic_content) catch break;
                out.appendSlice(allocator, Colors.reset ++ Colors.text) catch break;
                i = i + 1 + close_idx + 1;
                continue;
            }
        }

        // 5. Strikethrough: ~~text~~
        if (i + 1 < input.len and input[i] == '~' and input[i + 1] == '~') {
            const rest = input[i + 2 ..];
            if (std.mem.indexOf(u8, rest, "~~")) |close_idx| {
                const strike_content = rest[0..close_idx];
                out.appendSlice(allocator, "\x1b[9m" ++ Colors.text_dim) catch break;
                out.appendSlice(allocator, strike_content) catch break;
                out.appendSlice(allocator, Colors.reset ++ Colors.text) catch break;
                i = i + 2 + close_idx + 2;
                continue;
            }
        }

        out.append(allocator, input[i]) catch break;
        i += 1;
    }

    return out.toOwnedSlice(allocator) catch input;
}

pub fn printWrappedText(
    io: Io,
    stdout: File,
    allocator: Allocator,
    first_prefix: []const u8,
    first_prefix_w: usize,
    subsequent_prefix: []const u8,
    subsequent_prefix_w: usize,
    raw_text: []const u8,
    max_line_width: usize,
) void {
    const formatted = formatInline(allocator, raw_text);
    defer if (!std.mem.eql(u8, formatted, raw_text)) allocator.free(formatted);

    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(allocator);

    var i: usize = 0;
    while (i < formatted.len) {
        while (i < formatted.len and (formatted[i] == ' ' or formatted[i] == '\t')) : (i += 1) {}
        if (i >= formatted.len) break;

        const start = i;
        while (i < formatted.len and formatted[i] != ' ' and formatted[i] != '\t') {
            if (formatted[i] == 0x1B) {
                i += 1;
                if (i < formatted.len and formatted[i] == '[') {
                    i += 1;
                    while (i < formatted.len) : (i += 1) {
                        const c = formatted[i];
                        if (c >= 0x40 and c <= 0x7E) {
                            i += 1;
                            break;
                        }
                    }
                }
                continue;
            }
            i += 1;
        }
        words.append(allocator, formatted[start..i]) catch break;
    }

    if (words.items.len == 0) return;

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(allocator);

    var current_w: usize = 0;
    var is_first_line = true;
    var active_style: std.ArrayList(u8) = .empty;
    defer active_style.deinit(allocator);

    for (words.items) |w| {
        const w_w = visualWidth(w);

        if (line_buf.items.len == 0) {
            if (is_first_line) {
                line_buf.appendSlice(allocator, first_prefix) catch return;
                current_w = first_prefix_w;
            } else {
                line_buf.appendSlice(allocator, subsequent_prefix) catch return;
                current_w = subsequent_prefix_w;
                if (active_style.items.len > 0) {
                    line_buf.appendSlice(allocator, active_style.items) catch return;
                }
            }
            line_buf.appendSlice(allocator, w) catch return;
            current_w += w_w;
        } else if (current_w + 1 + w_w <= max_line_width) {
            line_buf.append(allocator, ' ') catch return;
            line_buf.appendSlice(allocator, w) catch return;
            current_w += 1 + w_w;
        } else {
            line_buf.appendSlice(allocator, Colors.reset ++ "\n") catch return;
            stdout.writeStreamingAll(io, line_buf.items) catch return;
            line_buf.clearRetainingCapacity();
            is_first_line = false;

            line_buf.appendSlice(allocator, subsequent_prefix) catch return;
            current_w = subsequent_prefix_w;
            if (active_style.items.len > 0) {
                line_buf.appendSlice(allocator, active_style.items) catch return;
            }
            line_buf.appendSlice(allocator, w) catch return;
            current_w += w_w;
        }

        var k: usize = 0;
        while (k < w.len) {
            if (w[k] == 0x1B) {
                const ansi_start = k;
                k += 1;
                if (k < w.len and w[k] == '[') {
                    k += 1;
                    while (k < w.len) : (k += 1) {
                        const c = w[k];
                        if (c >= 0x40 and c <= 0x7E) {
                            k += 1;
                            break;
                        }
                    }
                    const ansi_seq = w[ansi_start..k];
                    if (std.mem.eql(u8, ansi_seq, "\x1b[0m")) {
                        active_style.clearRetainingCapacity();
                    } else if (std.mem.endsWith(u8, ansi_seq, "m")) {
                        active_style.appendSlice(allocator, ansi_seq) catch {};
                    }
                    continue;
                }
            }
            k += 1;
        }
    }

    if (line_buf.items.len > 0) {
        line_buf.appendSlice(allocator, Colors.reset ++ "\n") catch return;
        stdout.writeStreamingAll(io, line_buf.items) catch return;
    }
}

pub fn renderMarkdown(io: Io, stdout: File, allocator: Allocator, text: []const u8) void {
    const AVAILABLE_KEYS = "abcdefghijklmnoprstuvwxz";
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_code_block = false;
    var block_idx: usize = 0;
    var last_was_empty = false;
    const box_w = getBoxWidth();

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed_line = std.mem.trim(u8, line, " \t");

        // Code block delimiter
        if (std.mem.startsWith(u8, trimmed_line, "```")) {
            if (!in_code_block) {
                in_code_block = true;
                last_was_empty = false;
                const lang = std.mem.trim(u8, trimmed_line[3..], " \t`");
                const key_char = if (block_idx < AVAILABLE_KEYS.len) AVAILABLE_KEYS[block_idx] else 'a';
                block_idx += 1;

                if (lang.len > 0) {
                    const prefix_len = 6 + 6 + visualWidth(lang) + 1;
                    const dashes_count = if (box_w > prefix_len) box_w - prefix_len else 4;
                    const dashes = writeDashes(allocator, dashes_count) catch continue;
                    defer allocator.free(dashes);

                    const h = std.fmt.allocPrint(
                        allocator,
                        "  {s}╭──{s} {s}[ {c} ]{s} {s}{s}{s} {s}{s}{s}\n",
                        .{
                            Colors.border,
                            Colors.reset,
                            Colors.primary ++ Colors.bold,
                            key_char,
                            Colors.reset,
                            Colors.warn ++ Colors.bold,
                            lang,
                            Colors.reset,
                            Colors.border,
                            dashes,
                            Colors.reset,
                        },
                    ) catch continue;
                    defer allocator.free(h);
                    stdout.writeStreamingAll(io, h) catch {};
                } else {
                    const prefix_len = 6 + 6;
                    const dashes_count = if (box_w > prefix_len) box_w - prefix_len else 4;
                    const dashes = writeDashes(allocator, dashes_count) catch continue;
                    defer allocator.free(dashes);

                    const h = std.fmt.allocPrint(
                        allocator,
                        "  {s}╭──{s} {s}[ {c} ]{s} {s}{s}{s}\n",
                        .{
                            Colors.border,
                            Colors.reset,
                            Colors.primary ++ Colors.bold,
                            key_char,
                            Colors.reset,
                            Colors.border,
                            dashes,
                            Colors.reset,
                        },
                    ) catch continue;
                    defer allocator.free(h);
                    stdout.writeStreamingAll(io, h) catch {};
                }
            } else {
                in_code_block = false;
                last_was_empty = false;
                const dashes_count = if (box_w > 3) box_w - 3 else 10;
                const dashes = writeDashes(allocator, dashes_count) catch continue;
                defer allocator.free(dashes);

                const f = std.fmt.allocPrint(
                    allocator,
                    "  {s}╰{s}{s}\n",
                    .{ Colors.border, dashes, Colors.reset },
                ) catch continue;
                defer allocator.free(f);
                stdout.writeStreamingAll(io, f) catch {};
            }
            continue;
        }

        // Inside Code Block: Clean 4-space indent with code_line color (NO '│' border!)
        if (in_code_block) {
            const cl = std.fmt.allocPrint(
                allocator,
                "    {s}{s}{s}\n",
                .{ Colors.code_line, line, Colors.reset },
            ) catch continue;
            defer allocator.free(cl);
            stdout.writeStreamingAll(io, cl) catch {};
            continue;
        }

        // Empty line handling (collapse multiple blank lines)
        if (trimmed_line.len == 0) {
            if (!last_was_empty) {
                stdout.writeStreamingAll(io, "\n") catch {};
                last_was_empty = true;
            }
            continue;
        }
        last_was_empty = false;

        // Horizontal Rules
        if (std.mem.eql(u8, trimmed_line, "---") or std.mem.eql(u8, trimmed_line, "***") or std.mem.eql(u8, trimmed_line, "___")) {
            const dashes_count = if (box_w > 2) box_w - 2 else 10;
            const dashes = writeDashes(allocator, dashes_count) catch continue;
            defer allocator.free(dashes);

            const hr = std.fmt.allocPrint(
                allocator,
                "\n  {s}{s}{s}\n\n",
                .{ Colors.border, dashes, Colors.reset },
            ) catch continue;
            defer allocator.free(hr);
            stdout.writeStreamingAll(io, hr) catch {};
            continue;
        }

        // Headers
        if (std.mem.startsWith(u8, trimmed_line, "#### ")) {
            const content = std.mem.trim(u8, trimmed_line[5..], " ");
            const first_p = "\n  " ++ Colors.warn ++ Colors.bold ++ "▹ " ++ Colors.reset ++ Colors.warn ++ Colors.bold;
            const sub_p = "    " ++ Colors.warn ++ Colors.bold;
            printWrappedText(io, stdout, allocator, first_p, 4, sub_p, 4, content, box_w);
            continue;
        }

        if (std.mem.startsWith(u8, trimmed_line, "### ")) {
            const content = std.mem.trim(u8, trimmed_line[4..], " ");
            const first_p = "\n  " ++ Colors.secondary ++ Colors.bold ++ "▸ " ++ Colors.reset ++ Colors.secondary ++ Colors.bold;
            const sub_p = "    " ++ Colors.secondary ++ Colors.bold;
            printWrappedText(io, stdout, allocator, first_p, 4, sub_p, 4, content, box_w);
            continue;
        }

        if (std.mem.startsWith(u8, trimmed_line, "## ")) {
            const content = std.mem.trim(u8, trimmed_line[3..], " ");
            const first_p = "\n  " ++ Colors.primary ++ Colors.bold ++ "✦ " ++ Colors.reset ++ Colors.primary ++ Colors.bold;
            const sub_p = "    " ++ Colors.primary ++ Colors.bold;
            printWrappedText(io, stdout, allocator, first_p, 4, sub_p, 4, content, box_w);
            continue;
        }

        if (std.mem.startsWith(u8, trimmed_line, "# ")) {
            const content = std.mem.trim(u8, trimmed_line[2..], " ");
            const first_p = "\n  " ++ Colors.highlight ++ Colors.bold ++ Colors.underline ++ "◈ " ++ Colors.reset ++ Colors.highlight ++ Colors.bold;
            const sub_p = "    " ++ Colors.highlight ++ Colors.bold;
            printWrappedText(io, stdout, allocator, first_p, 4, sub_p, 4, content, box_w);
            continue;
        }

        // Bullet lists
        if (std.mem.startsWith(u8, trimmed_line, "- ") or std.mem.startsWith(u8, trimmed_line, "* ") or std.mem.startsWith(u8, trimmed_line, "+ ")) {
            const indent_level = line.len - std.mem.trimStart(u8, line, " \t").len;
            const indent_slice = line[0..indent_level];
            const content = std.mem.trim(u8, trimmed_line[2..], " ");
            const bullet = if (indent_level == 0) "•" else "◦";

            const first_p = std.fmt.allocPrint(
                allocator,
                "{s}  {s}{s}{s} {s}",
                .{ indent_slice, Colors.primary ++ Colors.bold, bullet, Colors.reset, Colors.text },
            ) catch continue;
            defer allocator.free(first_p);

            const sub_p = std.fmt.allocPrint(
                allocator,
                "{s}    {s}",
                .{ indent_slice, Colors.text },
            ) catch continue;
            defer allocator.free(sub_p);

            const prefix_w = indent_level + 4;
            printWrappedText(io, stdout, allocator, first_p, prefix_w, sub_p, prefix_w, content, box_w);
            continue;
        }

        // Numbered lists (e.g. 1. 2. 3.)
        if (trimmed_line.len >= 3 and std.ascii.isDigit(trimmed_line[0])) {
            var dot_idx: usize = 1;
            while (dot_idx < trimmed_line.len and std.ascii.isDigit(trimmed_line[dot_idx])) {
                dot_idx += 1;
            }
            if (dot_idx < trimmed_line.len and trimmed_line[dot_idx] == '.' and (dot_idx + 1 < trimmed_line.len and trimmed_line[dot_idx + 1] == ' ')) {
                const indent_level = line.len - std.mem.trimStart(u8, line, " \t").len;
                const indent_slice = line[0..indent_level];
                const num = trimmed_line[0 .. dot_idx + 1];
                const content = std.mem.trim(u8, trimmed_line[dot_idx + 2 ..], " ");

                const first_p = std.fmt.allocPrint(
                    allocator,
                    "{s}  {s}{s}{s} {s}",
                    .{ indent_slice, Colors.secondary ++ Colors.bold, num, Colors.reset, Colors.text },
                ) catch continue;
                defer allocator.free(first_p);

                const prefix_w = indent_level + 2 + num.len + 1;
                const sub_spaces = allocator.alloc(u8, prefix_w) catch continue;
                defer allocator.free(sub_spaces);
                @memset(sub_spaces, ' ');

                const sub_p = std.fmt.allocPrint(
                    allocator,
                    "{s}{s}",
                    .{ sub_spaces, Colors.text },
                ) catch continue;
                defer allocator.free(sub_p);

                printWrappedText(io, stdout, allocator, first_p, prefix_w, sub_p, prefix_w, content, box_w);
                continue;
            }
        }

        // Blockquotes
        if (std.mem.startsWith(u8, trimmed_line, "> ")) {
            const content = std.mem.trim(u8, trimmed_line[2..], " ");
            const first_p = "  " ++ Colors.highlight ++ "▎" ++ Colors.reset ++ " " ++ Colors.italic ++ Colors.text_dim;
            const sub_p = "  " ++ Colors.highlight ++ "▎" ++ Colors.reset ++ " " ++ Colors.italic ++ Colors.text_dim;
            const prefix_w = 4;
            printWrappedText(io, stdout, allocator, first_p, prefix_w, sub_p, prefix_w, content, box_w);
            continue;
        }

        // Table Rows (GFM tables)
        if (std.mem.startsWith(u8, trimmed_line, "|") and std.mem.endsWith(u8, trimmed_line, "|")) {
            var is_sep = true;
            for (trimmed_line) |c| {
                if (c != '|' and c != '-' and c != ':' and c != ' ' and c != '\t') {
                    is_sep = false;
                    break;
                }
            }
            if (is_sep) {
                const dashes_count = if (box_w > 4) box_w - 4 else 10;
                const dashes = writeDashes(allocator, dashes_count) catch continue;
                defer allocator.free(dashes);
                const tbl_div = std.fmt.allocPrint(
                    allocator,
                    "  {s}{s}{s}\n",
                    .{ Colors.border, dashes, Colors.reset },
                ) catch continue;
                defer allocator.free(tbl_div);
                stdout.writeStreamingAll(io, tbl_div) catch {};
                continue;
            } else {
                const formatted = formatInline(allocator, trimmed_line);
                defer allocator.free(formatted);
                const row = std.fmt.allocPrint(
                    allocator,
                    "  {s}{s}{s}\n",
                    .{ Colors.text, formatted, Colors.reset },
                ) catch continue;
                defer allocator.free(row);
                stdout.writeStreamingAll(io, row) catch {};
                continue;
            }
        }

        // Normal paragraph lines
        const first_p = "  " ++ Colors.text;
        const sub_p = "  " ++ Colors.text;
        const prefix_w = 2;
        printWrappedText(io, stdout, allocator, first_p, prefix_w, sub_p, prefix_w, line, box_w);
    }

    // Auto-close unclosed code block if response was truncated
    if (in_code_block) {
        const dashes_count = if (box_w > 3) box_w - 3 else 4;
        if (writeDashes(allocator, dashes_count)) |dashes| {
            defer allocator.free(dashes);
            const f = std.fmt.allocPrint(
                allocator,
                "  {s}╰{s}{s}\n",
                .{ Colors.border, dashes, Colors.reset },
            ) catch return;
            defer allocator.free(f);
            stdout.writeStreamingAll(io, f) catch {};
        } else |_| {}
    }
}

pub fn printKeySavedSuccess(io: Io, stdout: File, allocator: Allocator, path: []const u8) void {
    const B = Colors.border;
    const R = Colors.reset;
    const G = Colors.success ++ Colors.bold;
    const W = Colors.warn;
    const D = Colors.text_dim;

    const box_w = getBoxWidth();
    const dashes_top_count = if (box_w > 32) box_w - 32 else 4;
    const dashes_top = writeDashes(allocator, dashes_top_count) catch return;
    defer allocator.free(dashes_top);

    const dashes_bot_count = if (box_w > 1) box_w - 1 else 10;
    const dashes_bot = writeDashes(allocator, dashes_bot_count) catch return;
    defer allocator.free(dashes_bot);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const top = std.fmt.allocPrint(
        allocator,
        "\n{s}╭─{s} {s}✦ API Key Saved Successfully{s} {s}{s}{s}\n",
        .{ B, R, G, R, B, dashes_top, R },
    ) catch return;
    defer allocator.free(top);
    out.appendSlice(allocator, top) catch return;

    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;

    const line1 = std.fmt.allocPrint(
        allocator,
        "{s}│{s}  Stored securely at: {s}{s}{s}\n{s}│{s}  File permissions:   {s}0600 (read/write by owner only){s}\n",
        .{ B, R, W, path, R, B, R, D, R },
    ) catch return;
    defer allocator.free(line1);
    out.appendSlice(allocator, line1) catch return;

    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "  You can now run " ++ Colors.primary ++ Colors.bold ++ "ask \"your question\"" ++ R ++ " anytime!\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;

    const bot = std.fmt.allocPrint(
        allocator,
        "{s}╰{s}{s}\n\n",
        .{ B, dashes_bot, R },
    ) catch return;
    defer allocator.free(bot);
    out.appendSlice(allocator, bot) catch return;

    stdout.writeStreamingAll(io, out.items) catch {};
}

pub fn printClearedSuccess(io: Io, stdout: File, allocator: Allocator) void {
    const B = Colors.border;
    const R = Colors.reset;
    const G = Colors.success ++ Colors.bold;

    const box_w = getBoxWidth();
    const dashes_top_count = if (box_w > 35) box_w - 35 else 4;
    const dashes_top = writeDashes(allocator, dashes_top_count) catch return;
    defer allocator.free(dashes_top);

    const dashes_bot_count = if (box_w > 1) box_w - 1 else 10;
    const dashes_bot = writeDashes(allocator, dashes_bot_count) catch return;
    defer allocator.free(dashes_bot);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const top = std.fmt.allocPrint(
        allocator,
        "\n{s}╭─{s} {s}✦ Credentials & Config Cleared{s} {s}{s}{s}\n",
        .{ B, R, G, R, B, dashes_top, R },
    ) catch return;
    defer allocator.free(top);
    out.appendSlice(allocator, top) catch return;

    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "  Stored API key credentials and config have been removed.\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;

    const bot = std.fmt.allocPrint(
        allocator,
        "{s}╰{s}{s}\n\n",
        .{ B, dashes_bot, R },
    ) catch return;
    defer allocator.free(bot);
    out.appendSlice(allocator, bot) catch return;

    stdout.writeStreamingAll(io, out.items) catch {};
}

pub fn printMissingKeyHelp(io: Io, stdout: File, allocator: Allocator) void {
    const B = Colors.border;
    const R = Colors.reset;
    const W = Colors.warn ++ Colors.bold;
    const P = Colors.primary ++ Colors.bold;
    const S = Colors.secondary ++ Colors.bold;
    const D = Colors.text_dim;

    const box_w = getBoxWidth();
    const dashes_top_count = if (box_w > 29) box_w - 29 else 4;
    const dashes_top = writeDashes(allocator, dashes_top_count) catch return;
    defer allocator.free(dashes_top);

    const dashes_bot_count = if (box_w > 1) box_w - 1 else 10;
    const dashes_bot = writeDashes(allocator, dashes_bot_count) catch return;
    defer allocator.free(dashes_bot);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const top = std.fmt.allocPrint(
        allocator,
        "\n{s}╭─{s} {s}✦ Gemini API Key Required{s} {s}{s}{s}\n",
        .{ B, R, W, R, B, dashes_top, R },
    ) catch return;
    defer allocator.free(top);
    out.appendSlice(allocator, top) catch return;

    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "  To use ask, provide your Gemini API Key:\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;

    // 1. ask --key
    out.appendSlice(allocator, B ++ "│" ++ R ++ "  " ++ P ++ "1. Save key directly (Recommended):" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "     " ++ Colors.warn ++ "ask --key \"AIzaSy...\"" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "     " ++ D ++ "(Saves securely with 0600 permissions to ~/.local/share/ask/credentials)" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;

    // 2. Env var
    out.appendSlice(allocator, B ++ "│" ++ R ++ "  " ++ S ++ "2. Or use Environment Variable:" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "     " ++ Colors.warn ++ "export GEMINI_API_KEY=\"AIzaSy...\"" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "     " ++ D ++ "(add to ~/.config/fish/config.fish or ~/.bashrc)" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;

    // Link
    out.appendSlice(allocator, B ++ "│" ++ R ++ "  Get a free key at: " ++ Colors.underline ++ Colors.primary ++ "https://aistudio.google.com/app/apikey" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;

    const bot = std.fmt.allocPrint(
        allocator,
        "{s}╰{s}{s}\n\n",
        .{ B, dashes_bot, R },
    ) catch return;
    defer allocator.free(bot);
    out.appendSlice(allocator, bot) catch return;

    stdout.writeStreamingAll(io, out.items) catch {};
}

fn appendWrappedLines(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    border_prefix: []const u8,
    text_style: []const u8,
    text: []const u8,
    max_width: usize,
) !void {
    const B = Colors.border;
    const R = Colors.reset;

    var words = std.mem.splitScalar(u8, text, ' ');
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(allocator);

    var current_width: usize = 0;

    while (words.next()) |word| {
        if (word.len == 0) continue;
        const w_width = visualWidth(word);

        if (current_width == 0) {
            try line_buf.appendSlice(allocator, word);
            current_width = w_width;
        } else if (current_width + 1 + w_width <= max_width) {
            try line_buf.append(allocator, ' ');
            try line_buf.appendSlice(allocator, word);
            current_width += 1 + w_width;
        } else {
            // Flush current line
            const formatted_line = try std.fmt.allocPrint(
                allocator,
                "{s}{s}{s}{s}{s}{s}\n",
                .{ B, border_prefix, R, text_style, line_buf.items, R },
            );
            defer allocator.free(formatted_line);
            try out.appendSlice(allocator, formatted_line);

            line_buf.clearRetainingCapacity();
            try line_buf.appendSlice(allocator, word);
            current_width = w_width;
        }
    }

    if (line_buf.items.len > 0) {
        const formatted_line = try std.fmt.allocPrint(
            allocator,
            "{s}{s}{s}{s}{s}{s}\n",
            .{ B, border_prefix, R, text_style, line_buf.items, R },
        );
        defer allocator.free(formatted_line);
        try out.appendSlice(allocator, formatted_line);
    }
}

pub fn printErrorBox(
    io: Io,
    stdout: File,
    allocator: Allocator,
    title: []const u8,
    message: []const u8,
    suggestion: ?[]const u8,
) void {
    const B = Colors.border;
    const R = Colors.reset;
    const E = Colors.error_color ++ Colors.bold;
    const W = Colors.warn;
    const P = Colors.primary ++ Colors.bold;
    const T = Colors.text;

    const box_w = getBoxWidth();
    const prefix_len = 6 + visualWidth(title);
    const dashes_top_count = if (box_w > prefix_len) box_w - prefix_len else 4;
    const dashes_top = writeDashes(allocator, dashes_top_count) catch return;
    defer allocator.free(dashes_top);

    const dashes_bot_count = if (box_w > 1) box_w - 1 else 10;
    const dashes_bot = writeDashes(allocator, dashes_bot_count) catch return;
    defer allocator.free(dashes_bot);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const top = std.fmt.allocPrint(
        allocator,
        "\n{s}╭─{s} {s}✦ {s}{s} {s}{s}{s}\n",
        .{ B, R, E, title, R, B, dashes_top, R },
    ) catch return;
    defer allocator.free(top);
    out.appendSlice(allocator, top) catch return;

    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;

    const max_w = if (box_w > 10) box_w - 10 else 40;

    // Output wrapped message line by line
    var msg_lines = std.mem.splitScalar(u8, message, '\n');
    while (msg_lines.next()) |mline| {
        const trimmed = std.mem.trim(u8, mline, " \r\t");
        if (trimmed.len == 0) continue;
        appendWrappedLines(allocator, &out, "│  ", T, trimmed, max_w) catch continue;
    }

    if (suggestion) |sug| {
        out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;
        out.appendSlice(allocator, B ++ "│" ++ R ++ "  " ++ P ++ "💡 Suggestion:" ++ R ++ "\n") catch return;

        const sug_w = if (max_w > 4) max_w - 4 else 36;
        var sug_lines = std.mem.splitScalar(u8, sug, '\n');
        while (sug_lines.next()) |sline| {
            const trimmed = std.mem.trim(u8, sline, " \r\t");
            if (trimmed.len == 0) continue;
            appendWrappedLines(allocator, &out, "│     ", W, trimmed, sug_w) catch continue;
        }
    }

    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;

    const bot = std.fmt.allocPrint(
        allocator,
        "{s}╰{s}{s}\n\n",
        .{ B, dashes_bot, R },
    ) catch return;
    defer allocator.free(bot);
    out.appendSlice(allocator, bot) catch return;

    stdout.writeStreamingAll(io, out.items) catch {};
}

pub fn printTuiWelcome(io: Io, stdout: File, allocator: Allocator, model: []const u8, stream_mode: bool) void {
    const B = Colors.border;
    const R = Colors.reset;
    const P = Colors.primary ++ Colors.bold;
    const D = Colors.text_dim;
    const W = Colors.warn ++ Colors.bold;
    const S = Colors.secondary ++ Colors.bold;

    const short_model = formatModelShort(allocator, model, false) catch model;
    defer if (!std.mem.eql(u8, short_model, model)) allocator.free(short_model);

    const box_w = getBoxWidth();
    // "╭── " (4) + "✦ Ask (" (7) + visualWidth(short_model) + ") " (2)
    const prefix_len = 4 + 7 + visualWidth(short_model) + 2;
    const dashes_top_count = if (box_w > prefix_len) box_w - prefix_len else 4;
    const dashes_top = writeDashes(allocator, dashes_top_count) catch return;
    defer allocator.free(dashes_top);

    const dashes_bot_count = if (box_w > 1) box_w - 1 else 10;
    const dashes_bot = writeDashes(allocator, dashes_bot_count) catch return;
    defer allocator.free(dashes_bot);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const top = std.fmt.allocPrint(
        allocator,
        "\n{s}╭──{s} {s}✦ Ask{s} {s}({s}){s} {s}{s}{s}\n",
        .{ B, R, P, R, D, short_model, R, B, dashes_top, R },
    ) catch return;
    defer allocator.free(top);
    out.appendSlice(allocator, top) catch return;

    const mid1 = std.fmt.allocPrint(
        allocator,
        "{s}│{s}   Type a prompt or command (" ++ W ++ "/help" ++ R ++ ", " ++ W ++ "/model" ++ R ++ ", " ++ W ++ "/copy" ++ R ++ ", " ++ W ++ "/clear" ++ R ++ ", " ++ W ++ "/stream" ++ R ++ ")\n",
        .{ B, R },
    ) catch return;
    defer allocator.free(mid1);
    out.appendSlice(allocator, mid1) catch return;

    const mid2 = std.fmt.allocPrint(
        allocator,
        "{s}│{s}   " ++ S ++ "Esc" ++ R ++ " or " ++ S ++ "Ctrl+D" ++ R ++ " to exit  •  " ++ S ++ "Up/Down" ++ R ++ " history  •  Stream: {s}\n",
        .{ B, R, if (stream_mode) Colors.success ++ "on" ++ Colors.reset else Colors.warn ++ "off" ++ Colors.reset },
    ) catch return;
    defer allocator.free(mid2);
    out.appendSlice(allocator, mid2) catch return;

    const bot = std.fmt.allocPrint(
        allocator,
        "{s}╰{s}{s}\n\n",
        .{ B, dashes_bot, R },
    ) catch return;
    defer allocator.free(bot);
    out.appendSlice(allocator, bot) catch return;

    stdout.writeStreamingAll(io, out.items) catch {};
}

pub fn printTuiHelp(io: Io, stdout: File, allocator: Allocator) void {
    const B = Colors.border;
    const R = Colors.reset;
    const P = Colors.primary ++ Colors.bold;
    const S = Colors.secondary ++ Colors.bold;
    const W = Colors.warn;
    const H = Colors.highlight ++ Colors.bold;

    const box_w = getBoxWidth();
    const dashes_top_count = if (box_w > 26) box_w - 26 else 4;
    const dashes_top = writeDashes(allocator, dashes_top_count) catch return;
    defer allocator.free(dashes_top);

    const dashes_bot_count = if (box_w > 1) box_w - 1 else 10;
    const dashes_bot = writeDashes(allocator, dashes_bot_count) catch return;
    defer allocator.free(dashes_bot);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const top = std.fmt.allocPrint(
        allocator,
        "\n{s}╭──{s} {s}✦ ask TUI Quick Reference{s} {s}{s}{s}\n",
        .{ B, R, P, R, B, dashes_top, R },
    ) catch return;
    defer allocator.free(top);
    out.appendSlice(allocator, top) catch return;

    out.appendSlice(allocator, B ++ "│" ++ R ++ "  " ++ S ++ "SLASH COMMANDS:" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    " ++ H ++ "/help" ++ R ++ ", " ++ H ++ "/?" ++ R ++ "         Show this quick help card\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    " ++ H ++ "/model <name>" ++ R ++ "  Switch active Gemini model on the fly\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    " ++ H ++ "/models" ++ R ++ "        List recommended available models\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    " ++ H ++ "/stream" ++ R ++ "        Toggle real-time streaming\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    " ++ H ++ "/copy" ++ R ++ ", " ++ H ++ "/y" ++ R ++ "        Copy last response to clipboard\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    " ++ H ++ "/copy <key>" ++ R ++ "    Copy snippet to clipboard (" ++ W ++ "/copy a" ++ R ++ ")\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    " ++ H ++ "/run <key>" ++ R ++ "     Execute snippet in terminal (" ++ W ++ "/run a" ++ R ++ ")\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    " ++ H ++ "/clear" ++ R ++ ", " ++ H ++ "/cls" ++ R ++ "    Clear screen and redisplay header (" ++ W ++ "Ctrl+L" ++ R ++ ")\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    " ++ H ++ "/history" ++ R ++ "      List past queries in this session\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    " ++ H ++ "/exit" ++ R ++ ", " ++ H ++ "/quit" ++ R ++ "     Close popup window (" ++ W ++ "Esc" ++ R ++ ", " ++ W ++ "Ctrl+D" ++ R ++ ", " ++ W ++ "q" ++ R ++ ")\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "  " ++ S ++ "KEYBOARD SHORTCUTS:" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    • " ++ W ++ "Enter" ++ R ++ "           Send question to LLM\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    • " ++ W ++ "Esc / Ctrl+D" ++ R ++ "    Exit popup immediately\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    • " ++ W ++ "Up / Down" ++ R ++ "       Cycle query history\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    • " ++ W ++ "Left / Right" ++ R ++ "    Move cursor within line\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "    • " ++ W ++ "Ctrl+U / Ctrl+W" ++ R ++ " Delete line / previous word\n") catch return;

    const bot = std.fmt.allocPrint(
        allocator,
        "{s}╰{s}{s}\n\n",
        .{ B, dashes_bot, R },
    ) catch return;
    defer allocator.free(bot);
    out.appendSlice(allocator, bot) catch return;

    stdout.writeStreamingAll(io, out.items) catch {};
}

pub fn printModelList(io: Io, stdout: File, allocator: Allocator, current_model: []const u8) void {
    const models = [_]struct { id: []const u8, desc: []const u8 }{
        .{ .id = "gemini-3.5-flash-lite", .desc = "Ultra fast, lightweight, default" },
        .{ .id = "gemini-3.5-flash", .desc = "Fast, high intelligence, general queries" },
        .{ .id = "gemini-2.5-pro", .desc = "Deep reasoning, architecture & coding" },
        .{ .id = "gemini-2.5-flash", .desc = "Previous generation stable fast" },
        .{ .id = "gemini-2.5-flash-lite", .desc = "Previous generation lite" },
        .{ .id = "gemma-4-31b-it", .desc = "Open weights Gemma 4 instruction-tuned" },
    };

    const B = Colors.border;
    const R = Colors.reset;
    const P = Colors.primary ++ Colors.bold;
    const G = Colors.success ++ Colors.bold;
    const D = Colors.text_dim;
    const W = Colors.warn;

    const box_w = getBoxWidth();
    const dashes_top_count = if (box_w > 20) box_w - 20 else 4;
    const dashes_top = writeDashes(allocator, dashes_top_count) catch return;
    defer allocator.free(dashes_top);

    const dashes_bot_count = if (box_w > 1) box_w - 1 else 10;
    const dashes_bot = writeDashes(allocator, dashes_bot_count) catch return;
    defer allocator.free(dashes_bot);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const top = std.fmt.allocPrint(
        allocator,
        "\n{s}╭──{s} {s}✦ Available Models{s} {s}{s}{s}\n",
        .{ B, R, P, R, B, dashes_top, R },
    ) catch return;
    defer allocator.free(top);
    out.appendSlice(allocator, top) catch return;

    for (models) |m| {
        const is_cur = std.mem.eql(u8, m.id, current_model);
        const prefix = if (is_cur) "  ▶ " else "    ";
        const id_color = if (is_cur) G else W;
        const line = std.fmt.allocPrint(
            allocator,
            "{s}│{s}{s}{s}{s:<24}{s} {s}{s}{s}\n",
            .{ B, R, prefix, id_color, m.id, R, D, m.desc, R },
        ) catch continue;
        defer allocator.free(line);
        out.appendSlice(allocator, line) catch continue;
    }

    out.appendSlice(allocator, B ++ "│" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, B ++ "│" ++ R ++ "  " ++ D ++ "Switch with: " ++ Colors.highlight ++ "/model <name>" ++ R ++ "\n") catch return;

    const bot = std.fmt.allocPrint(
        allocator,
        "{s}╰{s}{s}\n\n",
        .{ B, dashes_bot, R },
    ) catch return;
    defer allocator.free(bot);
    out.appendSlice(allocator, bot) catch return;

    stdout.writeStreamingAll(io, out.items) catch {};
}

pub fn printTuiToast(io: Io, stdout: File, allocator: Allocator, msg: []const u8) void {
    const toast = std.fmt.allocPrint(
        allocator,
        "\n  {s}{s}{s}\n\n",
        .{ Colors.success ++ Colors.bold, msg, Colors.reset },
    ) catch return;
    defer allocator.free(toast);
    stdout.writeStreamingAll(io, toast) catch {};
}

pub fn printSnippetHint(io: Io, stdout: File, allocator: Allocator, count: usize) void {
    if (count == 0) return;
    const msg = if (count == 1)
        std.fmt.allocPrint(
            allocator,
            "  {s}💡 Snippet: {s}/copy a{s} to copy, {s}/run a{s} to run, {s}/copy{s} for all text{s}\n\n",
            .{ Colors.text_dim, Colors.warn, Colors.text_dim, Colors.primary, Colors.text_dim, Colors.highlight, Colors.text_dim, Colors.reset },
        ) catch return
    else
        std.fmt.allocPrint(
            allocator,
            "  {s}💡 Snippets [a..{c}]: {s}/copy a{s}, {s}/run a{s}, or {s}/copy{s} for all text{s}\n\n",
            .{ Colors.text_dim, @as(u8, @intCast('a' + count - 1)), Colors.warn, Colors.text_dim, Colors.primary, Colors.text_dim, Colors.highlight, Colors.text_dim, Colors.reset },
        ) catch return;
    defer allocator.free(msg);
    stdout.writeStreamingAll(io, msg) catch {};
}

pub fn printHelp(io: Io, stdout: File, allocator: Allocator) void {
    const P = Colors.primary ++ Colors.bold;
    const S = Colors.secondary ++ Colors.bold;
    const W = Colors.warn;
    const H = Colors.highlight;
    const R = Colors.reset;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    out.appendSlice(allocator, "\n" ++ P ++ "ask" ++ R ++ " — Fast, lightweight terminal assistant powered by Gemini API\n\n") catch return;
    out.appendSlice(allocator, S ++ "USAGE:" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, "  ask [OPTIONS] \"<prompt>\"\n") catch return;
    out.appendSlice(allocator, "  <command> | ask [OPTIONS] \"<prompt>\"\n") catch return;
    out.appendSlice(allocator, "  ask (standalone interactive TUI)\n\n") catch return;

    out.appendSlice(allocator, S ++ "EXAMPLES:" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, "  " ++ W ++ "ask \"how to find large files over 1GB in linux\"" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, "  " ++ W ++ "git diff | ask \"write a concise commit message\"" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, "  " ++ W ++ "cat log.txt | ask \"explain why this failed\"" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, "  " ++ W ++ "ask -m gemini-2.5-pro \"design a clean database schema\"" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, "  " ++ W ++ "ask --stream \"live streaming response\"" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, "  " ++ W ++ "ask --key \"AIzaSy...\"" ++ R ++ "\n\n") catch return;

    out.appendSlice(allocator, S ++ "OPTIONS:" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, "  " ++ H ++ "-k, --key <api-key>" ++ R ++ "     Save API key securely for persistent use\n") catch return;
    out.appendSlice(allocator, "  " ++ H ++ "    --clear" ++ R ++ "             Remove saved credentials and reset configuration\n") catch return;
    out.appendSlice(allocator, "  " ++ H ++ "-m, --model <name>" ++ R ++ "     Override model (e.g. gemini-3.5-flash-lite, gemini-3.5-flash)\n") catch return;
    out.appendSlice(allocator, "  " ++ H ++ "    --fallback" ++ R ++ "         Enable automatic model fallback if model is busy/rate-limited (default)\n") catch return;
    out.appendSlice(allocator, "  " ++ H ++ "    --no-fallback" ++ R ++ "      Disable model fallback, fail if requested model fails\n") catch return;
    out.appendSlice(allocator, "  " ++ H ++ "-s, --stream" ++ R ++ "           Stream tokens live in real-time\n") catch return;
    out.appendSlice(allocator, "  " ++ H ++ "    --no-stream" ++ R ++ "        Wait for full response and render markdown (default)\n") catch return;
    out.appendSlice(allocator, "  " ++ H ++ "-r, --raw" ++ R ++ "              Output raw plain text (no styling or headers)\n") catch return;
    out.appendSlice(allocator, "  " ++ H ++ "-c, --config" ++ R ++ "           Show config file path and current configuration\n") catch return;
    out.appendSlice(allocator, "  " ++ H ++ "-h, --help" ++ R ++ "             Show this help message\n") catch return;
    out.appendSlice(allocator, "  " ++ H ++ "-v, --version" ++ R ++ "          Show version information\n\n") catch return;

    out.appendSlice(allocator, S ++ "INTERACTIVE RUNNER & TUI:" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, "  Code blocks in responses are labeled with shortcut keys (" ++ H ++ "[ a ]" ++ R ++ ", " ++ H ++ "[ b ]" ++ R ++ ", ...).\n") catch return;
    out.appendSlice(allocator, "  • In TUI: use " ++ W ++ "/copy a" ++ R ++ " or " ++ W ++ "/run a" ++ R ++ " or " ++ W ++ "/help" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, "  • In CLI prompt: press " ++ W ++ "a" ++ R ++ " to load command, " ++ W ++ "Enter" ++ R ++ " to run, " ++ W ++ "y" ++ R ++ " to copy, " ++ W ++ "q" ++ R ++ " to exit\n\n") catch return;

    out.appendSlice(allocator, S ++ "CONFIG & STORAGE:" ++ R ++ "\n") catch return;
    out.appendSlice(allocator, "  Config:      ~/.config/ask/config.json\n") catch return;
    out.appendSlice(allocator, "  Credentials: ~/.local/share/ask/credentials (mode 0600)\n\n") catch return;

    stdout.writeStreamingAll(io, out.items) catch {};
}

test "formatModelShort tests" {
    const allocator = std.testing.allocator;

    const s1 = try formatModelShort(allocator, "gemini-3.5-flash-lite", false);
    defer allocator.free(s1);
    try std.testing.expectEqualStrings("Gemini-3.5FL", s1);

    const s2 = try formatModelShort(allocator, "gemini-3.5-flash-lite", true);
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("Gemini-3.5FL (F)", s2);

    const s3 = try formatModelShort(allocator, "gemini-3.5-flash", false);
    defer allocator.free(s3);
    try std.testing.expectEqualStrings("Gemini-3.5F", s3);

    const s4 = try formatModelShort(allocator, "gemini-2.5-pro", false);
    defer allocator.free(s4);
    try std.testing.expectEqualStrings("Gemini-2.5P", s4);

    const s5 = try formatModelShort(allocator, "gemma-4-31b-it", false);
    defer allocator.free(s5);
    try std.testing.expectEqualStrings("Gemma-4-31B", s5);

    const s6 = try formatModelShort(allocator, "gemma-4-31b-it", true);
    defer allocator.free(s6);
    try std.testing.expectEqualStrings("Gemma-4-31B (F)", s6);
}

test "visualWidth tests" {
    // Plain ASCII
    try std.testing.expectEqual(@as(usize, 5), visualWidth("hello"));

    // Cyrillic UTF-8
    try std.testing.expectEqual(@as(usize, 6), visualWidth("Привет"));

    // ANSI escape sequences
    const styled = "\x1b[1m\x1b[38;2;138;173;244mTest\x1b[0m";
    try std.testing.expectEqual(@as(usize, 4), visualWidth(styled));
}

test "calculateCostUsd tests" {
    const cost_lite = calculateCostUsd("gemini-3.5-flash-lite", 1000, 1000);
    try std.testing.expect(cost_lite > 0.0003 and cost_lite < 0.0004);

    const cost_pro = calculateCostUsd("gemini-2.5-pro", 1000, 1000);
    try std.testing.expect(cost_pro > 0.006 and cost_pro < 0.007);
}

