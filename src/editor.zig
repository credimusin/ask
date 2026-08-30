const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = std.Io.File;
const ui_mod = @import("ui.zig");
const Colors = ui_mod.Colors;

pub const LineResult = union(enum) {
    line: []const u8,
    exit: void,
    clear_screen: void,
};

pub fn visualWidth(str: []const u8) usize {
    return ui_mod.visualWidth(str);
}

pub fn getTerminalWidth() usize {
    var ws: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0 and ws.col > 0) {
        return ws.col;
    }
    return 80;
}

pub fn visualOffsetToByteIndex(buf: []const u8, target_w: usize) usize {
    var cur_w: usize = 0;
    var i: usize = 0;
    while (i < buf.len) {
        if (cur_w >= target_w) return i;
        const b = buf[i];
        if ((b & 0xC0) != 0x80) {
            cur_w += 1;
        }
        i += 1;
    }
    return buf.len;
}

pub fn prevCharIndex(buf: []const u8, idx: usize) usize {
    if (idx == 0) return 0;
    var i = idx - 1;
    while (i > 0 and (buf[i] & 0xC0) == 0x80) {
        i -= 1;
    }
    return i;
}

pub fn nextCharIndex(buf: []const u8, idx: usize) usize {
    if (idx >= buf.len) return buf.len;
    var i = idx + 1;
    while (i < buf.len and (buf[i] & 0xC0) == 0x80) {
        i += 1;
    }
    return i;
}

fn redrawLine(
    io: Io,
    stdout: File,
    allocator: Allocator,
    prompt_colored: []const u8,
    buffer: []const u8,
    cursor_pos: usize,
) void {
    const term_w = getTerminalWidth();
    const prompt_w = ui_mod.visualWidth(prompt_colored);
    const total_w = ui_mod.visualWidth(buffer);
    const avail_w = if (term_w > prompt_w + 4) term_w - prompt_w - 3 else 20;

    stdout.writeStreamingAll(io, "\r\x1b[2K") catch return;
    stdout.writeStreamingAll(io, prompt_colored) catch return;

    if (total_w <= avail_w) {
        const text_colored = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ Colors.text, buffer, Colors.reset }) catch return;
        defer allocator.free(text_colored);
        stdout.writeStreamingAll(io, text_colored) catch return;

        if (cursor_pos < buffer.len) {
            const cur_w = ui_mod.visualWidth(buffer[0..cursor_pos]);
            if (total_w > cur_w) {
                const move_back = total_w - cur_w;
                const esc = std.fmt.allocPrint(allocator, "\x1b[{d}D", .{move_back}) catch return;
                defer allocator.free(esc);
                stdout.writeStreamingAll(io, esc) catch return;
            }
        }
    } else {
        const cur_w = ui_mod.visualWidth(buffer[0..cursor_pos]);
        const view_start_w: usize = if (cur_w + 4 < avail_w)
            0
        else
            cur_w -| (avail_w - 6);

        const has_left_indicator = view_start_w > 0;
        const effective_start_w = if (has_left_indicator) view_start_w + 1 else 0;
        const start_byte = visualOffsetToByteIndex(buffer, effective_start_w);

        const view_end_w = view_start_w + avail_w;
        const has_right_indicator = total_w > view_end_w;
        const effective_end_w = if (has_right_indicator) view_end_w - 1 else view_end_w;
        const end_byte = visualOffsetToByteIndex(buffer, effective_end_w);

        const slice = buffer[start_byte..end_byte];

        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(allocator);

        if (has_left_indicator) {
            rendered.appendSlice(allocator, Colors.text_dim ++ "…" ++ Colors.reset) catch return;
        }
        rendered.appendSlice(allocator, Colors.text) catch return;
        rendered.appendSlice(allocator, slice) catch return;
        rendered.appendSlice(allocator, Colors.reset) catch return;
        if (has_right_indicator) {
            rendered.appendSlice(allocator, Colors.text_dim ++ "…" ++ Colors.reset) catch return;
        }

        stdout.writeStreamingAll(io, rendered.items) catch return;

        const slice_cursor_w = if (cursor_pos >= start_byte and cursor_pos <= end_byte)
            ui_mod.visualWidth(buffer[start_byte..cursor_pos])
        else if (cursor_pos > end_byte)
            ui_mod.visualWidth(slice)
        else
            0;

        const cursor_screen_col = (if (has_left_indicator) @as(usize, 1) else 0) + slice_cursor_w;
        const total_rendered_col = (if (has_left_indicator) @as(usize, 1) else 0) + ui_mod.visualWidth(slice) + (if (has_right_indicator) @as(usize, 1) else 0);

        if (total_rendered_col > cursor_screen_col) {
            const move_back = total_rendered_col - cursor_screen_col;
            const esc = std.fmt.allocPrint(allocator, "\x1b[{d}D", .{move_back}) catch return;
            defer allocator.free(esc);
            stdout.writeStreamingAll(io, esc) catch return;
        }
    }
}

pub fn readInteractiveLine(
    allocator: Allocator,
    io: Io,
    stdin: File,
    stdout: File,
    prompt_colored: []const u8,
    history: *std.ArrayList([]const u8),
) LineResult {
    const input_fd: std.posix.fd_t = stdin.handle;
    const is_tty = stdin.isTty(io) catch false;

    if (!is_tty) {
        // Fallback for non-TTY
        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(allocator);
        var char_buf: [1]u8 = undefined;
        var iov = [_][]u8{&char_buf};
        var eof = false;

        while (true) {
            const amt = stdin.readStreaming(io, &iov) catch break;
            if (amt == 0) {
                eof = true;
                break;
            }
            if (char_buf[0] == '\n') break;
            line_buf.append(allocator, char_buf[0]) catch break;
        }
        if (eof and line_buf.items.len == 0) return .exit;
        const duped = allocator.dupe(u8, line_buf.items) catch return .exit;
        return .{ .line = duped };
    }

    // Set raw mode
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

    var cursor_pos: usize = 0;
    var hist_idx: usize = history.items.len;
    var saved_current_input: ?[]const u8 = null;
    defer if (saved_current_input) |s| allocator.free(s);

    redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);

    var char_buf: [1]u8 = undefined;
    var iov = [_][]u8{&char_buf};

    while (true) {
        const amt = stdin.readStreaming(io, &iov) catch break;
        if (amt == 0) break;
        const b = char_buf[0];

        // 1. Escape Sequences
        if (b == 0x1B) {
            // Read next byte
            var seq: [8]u8 = undefined;
            seq[0] = 0x1B;
            var seq_len: usize = 1;

            // Non-blocking or small read for escape sequence trailing bytes
            // If nothing follows within a short period, it's just the Escape key!
            while (seq_len < 6) {
                var next_b: [1]u8 = undefined;
                var next_iov = [_][]u8{&next_b};
                // Poll/read next char
                var pfd = [_]std.posix.pollfd{.{
                    .fd = input_fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const poll_res = std.posix.poll(&pfd, 30) catch 0;
                if (poll_res > 0 and (pfd[0].revents & std.posix.POLL.IN) != 0) {
                    const read_amt = stdin.readStreaming(io, &next_iov) catch 0;
                    if (read_amt == 1) {
                        seq[seq_len] = next_b[0];
                        seq_len += 1;
                        // Stop if terminal char reached
                        const last = next_b[0];
                        if ((last >= 'A' and last <= 'Z') or (last >= 'a' and last <= 'z') or last == '~') {
                            break;
                        }
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            }

            if (seq_len == 1) {
                // Standalone Escape key pressed!
                if (line_buf.items.len == 0) {
                    stdout.writeStreamingAll(io, "\r\x1b[2K\n") catch {};
                    return .exit;
                } else {
                    // Clear line on Esc
                    line_buf.clearRetainingCapacity();
                    cursor_pos = 0;
                    redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
                    continue;
                }
            }

            // Parse known escape sequences
            const seq_slice = seq[0..seq_len];

            // Up Arrow (\x1b[A or \x1bOA)
            if (std.mem.eql(u8, seq_slice, "\x1b[A") or std.mem.eql(u8, seq_slice, "\x1bOA")) {
                if (history.items.len > 0 and hist_idx > 0) {
                    if (hist_idx == history.items.len) {
                        if (saved_current_input) |s| allocator.free(s);
                        saved_current_input = allocator.dupe(u8, line_buf.items) catch null;
                    }
                    hist_idx -= 1;
                    line_buf.clearRetainingCapacity();
                    line_buf.appendSlice(allocator, history.items[hist_idx]) catch {};
                    cursor_pos = line_buf.items.len;
                    redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
                }
                continue;
            }

            // Down Arrow (\x1b[B or \x1bOB)
            if (std.mem.eql(u8, seq_slice, "\x1b[B") or std.mem.eql(u8, seq_slice, "\x1bOB")) {
                if (hist_idx < history.items.len) {
                    hist_idx += 1;
                    line_buf.clearRetainingCapacity();
                    if (hist_idx == history.items.len) {
                        if (saved_current_input) |saved| {
                            line_buf.appendSlice(allocator, saved) catch {};
                        }
                    } else {
                        line_buf.appendSlice(allocator, history.items[hist_idx]) catch {};
                    }
                    cursor_pos = line_buf.items.len;
                    redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
                }
                continue;
            }

            // Left Arrow (\x1b[D or \x1bOD)
            if (std.mem.eql(u8, seq_slice, "\x1b[D") or std.mem.eql(u8, seq_slice, "\x1bOD")) {
                if (cursor_pos > 0) {
                    cursor_pos = prevCharIndex(line_buf.items, cursor_pos);
                    redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
                }
                continue;
            }

            // Right Arrow (\x1b[C or \x1bOC)
            if (std.mem.eql(u8, seq_slice, "\x1b[C") or std.mem.eql(u8, seq_slice, "\x1bOC")) {
                if (cursor_pos < line_buf.items.len) {
                    cursor_pos = nextCharIndex(line_buf.items, cursor_pos);
                    redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
                }
                continue;
            }

            // Home (\x1b[H, \x1b[1~, \x1b[7~, \x1bOH)
            if (std.mem.eql(u8, seq_slice, "\x1b[H") or std.mem.eql(u8, seq_slice, "\x1b[1~") or std.mem.eql(u8, seq_slice, "\x1b[7~") or std.mem.eql(u8, seq_slice, "\x1bOH")) {
                cursor_pos = 0;
                redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
                continue;
            }

            // End (\x1b[F, \x1b[4~, \x1b[8~, \x1bOF)
            if (std.mem.eql(u8, seq_slice, "\x1b[F") or std.mem.eql(u8, seq_slice, "\x1b[4~") or std.mem.eql(u8, seq_slice, "\x1b[8~") or std.mem.eql(u8, seq_slice, "\x1bOF")) {
                cursor_pos = line_buf.items.len;
                redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
                continue;
            }

            // Delete (\x1b[3~)
            if (std.mem.eql(u8, seq_slice, "\x1b[3~")) {
                if (cursor_pos < line_buf.items.len) {
                    const next_pos = nextCharIndex(line_buf.items, cursor_pos);
                    const remove_count = next_pos - cursor_pos;
                    var r: usize = 0;
                    while (r < remove_count) : (r += 1) {
                        _ = line_buf.orderedRemove(cursor_pos);
                    }
                    redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
                }
                continue;
            }

            // Ignored escape sequences
            continue;
        }

        // 2. Ctrl+C (0x03) or Ctrl+D (0x04)
        if (b == 0x03 or b == 0x04) {
            if (line_buf.items.len == 0) {
                stdout.writeStreamingAll(io, "\r\x1b[2K\n") catch {};
                return .exit;
            } else {
                line_buf.clearRetainingCapacity();
                cursor_pos = 0;
                redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
                continue;
            }
        }

        // 3. Ctrl+L (0x0C) -> Clear screen
        if (b == 0x0C) {
            return .clear_screen;
        }

        // 4. Ctrl+A (0x01) -> Home
        if (b == 0x01) {
            cursor_pos = 0;
            redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
            continue;
        }

        // 5. Ctrl+E (0x05) -> End
        if (b == 0x05) {
            cursor_pos = line_buf.items.len;
            redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
            continue;
        }

        // 6. Ctrl+U (0x15) -> Clear line before cursor
        if (b == 0x15) {
            if (cursor_pos > 0) {
                var r: usize = 0;
                while (r < cursor_pos) : (r += 1) {
                    _ = line_buf.orderedRemove(0);
                }
                cursor_pos = 0;
                redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
            }
            continue;
        }

        // 7. Ctrl+K (0x0B) -> Clear to end of line
        if (b == 0x0B) {
            if (cursor_pos < line_buf.items.len) {
                line_buf.items.len = cursor_pos;
                redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
            }
            continue;
        }

        // 8. Ctrl+W (0x17) -> Delete previous word
        if (b == 0x17) {
            if (cursor_pos > 0) {
                var new_pos = cursor_pos;
                // Skip trailing spaces
                while (new_pos > 0 and line_buf.items[new_pos - 1] == ' ') {
                    new_pos -= 1;
                }
                // Skip non-spaces
                while (new_pos > 0 and line_buf.items[new_pos - 1] != ' ') {
                    new_pos = prevCharIndex(line_buf.items, new_pos);
                }
                const to_remove = cursor_pos - new_pos;
                var r: usize = 0;
                while (r < to_remove) : (r += 1) {
                    _ = line_buf.orderedRemove(new_pos);
                }
                cursor_pos = new_pos;
                redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
            }
            continue;
        }

        // 9. Backspace (0x7F or 0x08)
        if (b == 0x7F or b == 0x08) {
            if (cursor_pos > 0) {
                const prev_pos = prevCharIndex(line_buf.items, cursor_pos);
                const remove_count = cursor_pos - prev_pos;
                var r: usize = 0;
                while (r < remove_count) : (r += 1) {
                    _ = line_buf.orderedRemove(prev_pos);
                }
                cursor_pos = prev_pos;
                redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
            }
            continue;
        }

        // 10. Enter key (\r or \n) -> Submit line
        if (b == '\r' or b == '\n') {
            stdout.writeStreamingAll(io, "\r\x1b[2K") catch {};
            // Echo final entered prompt & line nicely
            const finalize = std.fmt.allocPrint(allocator, "{s}{s}{s}{s}\n\n", .{ prompt_colored, Colors.code_line, line_buf.items, Colors.reset }) catch return .exit;
            defer allocator.free(finalize);
            stdout.writeStreamingAll(io, finalize) catch {};

            const trimmed = std.mem.trim(u8, line_buf.items, " \t\r\n");
            if (trimmed.len > 0) {
                const duped = allocator.dupe(u8, trimmed) catch return .exit;
                return .{ .line = duped };
            } else {
                return .{ .line = "" };
            }
        }

        // 11. Normal character / UTF-8 byte
        if (b >= 0x20 or (b & 0xC0) == 0x80 or (b & 0xC0) == 0xC0 or (b & 0xE0) == 0xE0 or (b & 0xF0) == 0xF0) {
            line_buf.insert(allocator, cursor_pos, b) catch continue;
            cursor_pos += 1;
            redrawLine(io, stdout, allocator, prompt_colored, line_buf.items, cursor_pos);
        }
    }

    return .exit;
}

test "prevCharIndex and nextCharIndex with ASCII and UTF-8" {
    const ascii = "hello";
    try std.testing.expectEqual(@as(usize, 4), prevCharIndex(ascii, 5));
    try std.testing.expectEqual(@as(usize, 1), nextCharIndex(ascii, 0));

    const utf8 = "Привет"; // 6 cyrillic chars, 12 bytes
    try std.testing.expectEqual(@as(usize, 12), utf8.len);
    try std.testing.expectEqual(@as(usize, 10), prevCharIndex(utf8, 12));
    try std.testing.expectEqual(@as(usize, 2), nextCharIndex(utf8, 0));
    try std.testing.expectEqual(@as(usize, 6), visualWidth(utf8));

    try std.testing.expectEqual(@as(usize, 0), visualOffsetToByteIndex(utf8, 0));
    try std.testing.expectEqual(@as(usize, 2), visualOffsetToByteIndex(utf8, 1));
    try std.testing.expectEqual(@as(usize, 6), visualOffsetToByteIndex(utf8, 3));
    try std.testing.expectEqual(@as(usize, 12), visualOffsetToByteIndex(utf8, 6));
}

