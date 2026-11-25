//! Ghostty X: command blocks and folded output.
//!
//! Shell integration (OSC 133) marks which rows are prompts, so the screen
//! is a sequence of blocks: a command line and the rows it printed. This
//! file answers "which blocks are in view" for the app, which draws a box
//! with copy and fold buttons around each one, and it folds a block's
//! output away and brings it back.
//!
//! Folding removes the output rows from the screen and keeps their text
//! here, with colors. The command line gets a short label ("42 lines" and
//! the first line of the output) that carries the fold's identity as an OSC
//! 8 hyperlink, so nothing about positions is remembered between
//! operations: whatever row the command line has scrolled to, its label
//! says which fold it is.
//!
//! Folding is something you do (a click on the block's button or its label). With
//! `threshold` set, long output is also folded for you, and that kind of fold has one
//! rule above all: the line you are typing on does not move. See `Anchor`.
//!
//! Everything here runs with the terminal's renderer lock held by the caller.
const std = @import("std");
const Terminal = @import("Terminal.zig");
const Screen = @import("Screen.zig");
const PageList = @import("PageList.zig");
const Selection = @import("Selection.zig");
const pagepkg = @import("page.zig");
const ScreenFormatter = @import("formatter.zig").ScreenFormatter;
const Pin = PageList.Pin;
const Cell = pagepkg.Cell;

const log = std.log.scoped(.fold);

const link_prefix = "ghostty-fold:";

/// Output longer than this many rows is folded for you. Zero turns that off.
pub var threshold: std.atomic.Value(u32) = .init(0);

/// When long output is folded for you. By default it is when the next command starts,
/// so the output you just asked for is never taken away while you read it. With this
/// set it is as soon as the command finishes. Either way the cursor stays on its row.
pub var fold_latest: std.atomic.Value(bool) = .init(false);

/// Whether the last command failed, for the terminals seen most recently. Output of a
/// failed command is never folded for you: it is what you need to read.
const Exit = struct { terminal: usize = 0, failed: bool = false };
var exits: [16]Exit = @splat(.{});
var exits_next: usize = 0;

/// The last fold or opening, so the app can point it out: which terminal, the screen
/// row of the command line, and a count that goes up with every change.
var changed_terminal: usize = 0;
var changed_y: usize = 0;
var changed_serial: u32 = 0;

fn recordChange(t: *Terminal, head_y: usize) void {
    changed_terminal = @intFromPtr(t);
    changed_y = head_y;
    changed_serial +%= 1;
}

/// Why the last finished command was or was not folded, for diagnosis:
/// 1 folding off, 2 the screen is not in its plain state, 3 cursor not at
/// column 0, 4 no prompt found, 5 no output found, 6 a position could not
/// be resolved, 7 output not above the cursor, 8 under the limit (or far
/// too long), 9 folded, 10 failed with an error, 12 the command line could
/// not be labeled, 13 folding waits for the next command, 14 the command failed, so
/// its output is left open, 15 folding would have moved the cursor (the scrollback
/// holds fewer lines than the fold would free). The high bits carry the row count.
pub var last_status: std.atomic.Value(u32) = .init(0);

/// The last few outcomes with the rows involved, oldest first once full:
/// code, first output row, last output row, cursor row. Codes from 20 up are
/// about folding or opening a block by hand: 20 the block found (command
/// row, end of output, next prompt), 21 to 30 why it was left alone, 40 the
/// label found by `toggleLast`, 41 none found, 42 an error. 72 is written by every
/// fold: the cursor's row before, its row after, and the rows taken from the scrollback.
pub var trail: [16][4]u32 = @splat(@splat(0));
pub var trail_count: u32 = 0;

fn status(code: u32, rows: u32) void {
    last_status.store(code | (rows << 8), .monotonic);
    note(code, rows, 0, 0);
}

fn note(code: u32, a: u32, b: u32, c: u32) void {
    trail[trail_count % trail.len] = .{ code, a, b, c };
    trail_count +%= 1;
}

// ---------------------------------------------------------------------------
// The store
// ---------------------------------------------------------------------------

/// Folded output is kept in a small ring: the most recent folds across every
/// terminal. A fold that has been pushed out of the ring can no longer be
/// expanded or copied; its label stays on screen.
const Slot = struct {
    id: u32 = 0,
    /// The output as VT text: plain text with the escape sequences that
    /// give it back its colors.
    text: [:0]const u8 = "",
    /// Rows the output took when it was folded, and the width it had.
    lines: u32 = 0,
    cols: u32 = 0,
};

const max_slots = 48;
/// Longer output than this is left alone, so one command cannot hold a
/// large block of memory for as long as it stays in the ring.
const max_lines = 20_000;

/// All kept text together stays under this. Past it the oldest folds are let go (they
/// keep their label and lose their button), so a long session of folding long output
/// cannot grow without limit: 48 folds of 20,000 wide, colored rows would be far more.
const max_bytes = 16 * 1024 * 1024;
var held_bytes: usize = 0;

var slots: [max_slots]Slot = @splat(.{});
var next_id: u32 = 1;
var busy: std.atomic.Value(bool) = .init(false);
const store_alloc = std.heap.page_allocator;

fn lock() void {
    while (busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlock() void {
    busy.store(false, .release);
}

/// Takes ownership of `text`, which must come from `store_alloc`. With an
/// id, the text replaces what that fold held (or brings the fold back if it
/// had been pushed out).
fn put(existing: ?u32, text: [:0]const u8, lines: u32, cols: u32) u32 {
    lock();
    defer unlock();
    const id = existing orelse fresh: {
        const fresh = next_id;
        next_id +%= 1;
        if (next_id == 0) next_id = 1;
        break :fresh fresh;
    };
    const slot = &slots[id % max_slots];
    if (slot.id != 0) {
        held_bytes -|= slot.text.len;
        store_alloc.free(slot.text);
    }
    slot.* = .{ .id = id, .text = text, .lines = lines, .cols = cols };
    held_bytes += text.len;

    // Over the limit: the oldest other folds go, oldest first.
    while (held_bytes > max_bytes) {
        var oldest: ?*Slot = null;
        for (&slots) |*other| {
            if (other.id == 0 or other.id == id) continue;
            if (oldest == null or other.id < oldest.?.id) oldest = other;
        }
        const gone = oldest orelse break;
        held_bytes -|= gone.text.len;
        store_alloc.free(gone.text);
        gone.* = .{};
    }
    return id;
}

const Info = struct { lines: u32, cols: u32 };

fn info(id: u32) ?Info {
    lock();
    defer unlock();
    const slot = &slots[id % max_slots];
    if (id == 0 or slot.id != id) return null;
    return .{ .lines = slot.lines, .cols = slot.cols };
}

/// A copy of a fold's VT text owned by the caller, or null if it is gone.
fn getVt(alloc: std.mem.Allocator, id: u32) ?[:0]u8 {
    lock();
    defer unlock();
    const slot = &slots[id % max_slots];
    if (id == 0 or slot.id != id) return null;
    return alloc.dupeSentinel(u8, slot.text, 0) catch null;
}

/// A copy of a fold's text without escape sequences, owned by the caller,
/// or null if the fold is gone.
pub fn get(alloc: std.mem.Allocator, id: u32) ?[:0]u8 {
    lock();
    defer unlock();
    const slot = &slots[id % max_slots];
    if (id == 0 or slot.id != id) return null;
    const len = stripInto(slot.text, null);
    const out = alloc.allocSentinel(u8, len, 0) catch return null;
    _ = stripInto(slot.text, out);
    return out;
}

/// The index after the escape sequence that starts at `i`.
fn skipEscape(src: []const u8, i: usize) usize {
    if (i + 1 >= src.len) return src.len;
    var j = i + 2;
    switch (src[i + 1]) {
        '[' => {
            while (j < src.len and !(src[j] >= 0x40 and src[j] <= 0x7e)) j += 1;
            return @min(j + 1, src.len);
        },
        ']' => {
            while (j < src.len) : (j += 1) {
                if (src[j] == 0x07) return j + 1;
                if (src[j] == 0x1b and j + 1 < src.len and src[j + 1] == '\\') return j + 2;
            }
            return src.len;
        },
        else => return j,
    }
}

/// How many cells the escape sequence at `i` steps over, if it is a cursor
/// forward (CSI n C). Kept text has those where the screen had blank cells
/// between words, so in plain text each one is a space.
fn stepsOver(src: []const u8, i: usize) usize {
    if (i + 2 >= src.len or src[i + 1] != '[') return 0;
    var j = i + 2;
    var count: usize = 0;
    while (j < src.len and src[j] >= '0' and src[j] <= '9') : (j += 1) {
        count = @min(count * 10 + (src[j] - '0'), 4096);
    }
    if (j >= src.len or src[j] != 'C') return 0;
    return @max(count, 1);
}

/// Writes `src` without escape sequences and carriage returns. Returns the
/// length, and only measures when `out` is null.
fn stripInto(src: []const u8, out: ?[]u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == 0x1b) {
            const blanks = stepsOver(src, i);
            if (out) |o| @memset(o[n..][0..blanks], ' ');
            n += blanks;
            i = skipEscape(src, i);
            continue;
        }
        if (c != '\r') {
            if (out) |o| o[n] = c;
            n += 1;
        }
        i += 1;
    }
    return n;
}

/// The first line of VT text that has anything on it, with runs of blanks
/// squeezed, as much as fits.
fn previewInto(buf: []u8, vt: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    var blank = true;
    while (i < vt.len) {
        const c = vt[i];
        if (c == 0x1b) {
            // Blank cells between words: one space, like any other run of blanks.
            if (stepsOver(vt, i) > 0 and !blank and n < buf.len) {
                buf[n] = ' ';
                n += 1;
                blank = true;
            }
            i = skipEscape(vt, i);
            continue;
        }
        if (c == '\n') {
            if (n > 0) break;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t') {
            if (!blank and n < buf.len) {
                buf[n] = ' ';
                n += 1;
            }
            blank = true;
            i += 1;
            continue;
        }
        if (c < 0x20 or c == 0x7f) {
            i += 1;
            continue;
        }
        const len: usize = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (i + len > vt.len or n + len > buf.len) break;
        @memcpy(buf[n..][0..len], vt[i..][0..len]);
        n += len;
        i += len;
        blank = false;
    }
    while (n > 0 and buf[n - 1] == ' ') n -= 1;
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------------

/// Columns kept free at the right end of a command line for the app's copy
/// and fold buttons.
const button_cols = 9;

pub const Label = struct {
    id: u32,
    /// The label's first column.
    x: usize,
};

/// The fold a cell's link names, if the cell is part of a fold label.
pub fn targetAt(pin: Pin) ?u32 {
    const cell = pin.rowAndCell().cell;
    if (!cell.hyperlink) return null;
    const page = pin.node.page();
    const link_id = page.lookupHyperlink(cell) orelse return null;
    const entry = page.hyperlink_set.get(page.memory, link_id);
    const uri = entry.uri.slice(page.memory);
    if (!std.mem.startsWith(u8, uri, link_prefix)) return null;
    const id = std.fmt.parseInt(u32, uri[link_prefix.len..], 10) catch return null;
    return if (id == 0) null else id;
}

/// The fold label on a row, if it has one.
pub fn labelOnRow(pin: Pin) ?Label {
    if (!pin.rowAndCell().row.hyperlink) return null;
    var p = pin;
    const cols: usize = pin.node.cols();
    var x: usize = 0;
    while (x < cols) : (x += 1) {
        p.x = @intCast(x);
        if (targetAt(p)) |id| return .{ .id = id, .x = x };
    }
    return null;
}

/// Where a new label goes on a command line: two columns after its text,
/// or over the right end of the line when that leaves no room. Null when
/// the screen is too narrow for a label at all.
fn labelColumn(head: Pin, cols: usize, lines: u32) ?usize {
    var digits: usize = 1;
    var v = lines;
    while (v >= 10) : (v /= 10) digits += 1;
    const need = digits + " lines".len + 2;
    const limit = cols -| button_cols;
    if (limit < need + 4) return null;

    var p = head;
    p.x = 0;
    var end: usize = 0;
    for (p.cells(.all), 0..) |*cell, x| {
        if (cell.hasText()) end = x + 1;
    }
    const x = end + 2;
    return if (x + need <= limit) x else limit - need;
}

/// Prints text at the cursor, stopping before column `limit`.
fn printClipped(t: *Terminal, text: []const u8, limit: usize) !void {
    const screen: *Screen = t.screens.active;
    const view = std.unicode.Utf8View.init(text) catch return;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        // Two columns of room, so a wide character can never wrap the line.
        if (screen.cursor.x + 2 >= limit) return;
        if (cp < 0x20) continue;
        try t.print(cp);
    }
}

/// Writes a fold label on an active-area row from column `x` to the end of
/// the line: the line count, then the preview if there is one. The cursor
/// comes back to where it was.
fn writeLabel(
    t: *Terminal,
    row: usize,
    x: usize,
    id: u32,
    lines: u32,
    preview: []const u8,
) !void {
    const screen: *Screen = t.screens.active;
    const saved_x = screen.cursor.x;
    const saved_y = screen.cursor.y;
    const saved_wrap = screen.cursor.pending_wrap;
    const semantic = screen.cursor.semantic_content;
    defer {
        t.setCursorPos(saved_y + 1, saved_x + 1);
        screen.cursor.pending_wrap = saved_wrap;
        screen.cursor.semantic_content = semantic;
    }

    try t.setAttribute(.unset);
    screen.endHyperlink();
    t.setCursorPos(row + 1, x + 1);
    t.eraseLine(.right, false);

    // Marked as prompt text: it is not the command that was typed, and it
    // is not output.
    screen.cursor.semantic_content = .prompt;
    const limit = t.cols -| button_cols;

    var uri_buf: [48]u8 = undefined;
    var text_buf: [32]u8 = undefined;
    try screen.startHyperlink(
        try std.fmt.bufPrint(&uri_buf, "{s}{d}", .{ link_prefix, id }),
        null,
    );
    defer screen.endHyperlink();

    try t.setAttribute(.{ .@"8_fg" = .blue });
    try printClipped(t, try std.fmt.bufPrint(&text_buf, "{d} line{s}", .{
        lines,
        if (lines == 1) "" else "s",
    }), limit);
    try t.setAttribute(.unset);
    if (preview.len > 0) {
        try t.setAttribute(.faint);
        try printClipped(t, "  ", limit);
        try printClipped(t, preview, limit);
        try t.setAttribute(.unset);
    }
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

fn isPrompt(pin: Pin) bool {
    return pin.rowAndCell().row.semantic_prompt != .none;
}

fn rowHasText(pin: Pin) bool {
    if (pin.rowAndCell().row.blank) return false;
    var p = pin;
    p.x = 0;
    return Cell.hasTextAny(p.cells(.all));
}

fn screenY(screen: *Screen, pin: Pin) ?usize {
    const pt = screen.pages.pointFromPin(.screen, pin) orelse return null;
    return pt.screen.y;
}

/// One command and its output, in screen rows.
const Block = struct {
    /// First row of the prompt, and the command line (the prompt's last row).
    start: Pin,
    head: Pin,
    head_y: usize,
    /// One past the last output row that has text. `head_y + 1` when the
    /// block shows no output.
    out_end_y: usize,
    /// The row the next prompt starts on, or one past the last row of the
    /// screen when no prompt follows.
    limit_y: usize,
    /// A later prompt exists, so the command has finished.
    closed: bool,
    label: ?Label,

    fn hasOutput(self: Block) bool {
        return self.out_end_y > self.head_y + 1;
    }
};

/// The block that the row at `at` belongs to.
fn blockAt(screen: *Screen, at: Pin) ?Block {
    var p = at;
    p.x = 0;

    // Up through output to the prompt, then up to the prompt's first row.
    var steps: usize = 0;
    while (!isPrompt(p)) : (steps += 1) {
        if (steps > max_lines) return null;
        p = p.up(1) orelse return null;
    }
    while (p.rowAndCell().row.semantic_prompt == .prompt_continuation) {
        const above = p.up(1) orelse break;
        if (!isPrompt(above)) break;
        p = above;
    }
    const start = p;

    // Down to the command line.
    while (p.down(1)) |next| {
        if (next.rowAndCell().row.semantic_prompt != .prompt_continuation) break;
        p = next;
    }
    const head = p;
    const head_y = screenY(screen, head) orelse return null;

    // Down to the next prompt.
    var limit_y = head_y + 1;
    var closed = false;
    var last = head;
    while (last.down(1)) |next| {
        if (isPrompt(next)) {
            closed = true;
            break;
        }
        last = next;
        limit_y += 1;
    }

    // Back up over blank rows to the last one with text.
    var out_end_y = limit_y;
    while (out_end_y > head_y + 1 and !rowHasText(last)) {
        out_end_y -= 1;
        last = last.up(1) orelse break;
    }

    return .{
        .start = start,
        .head = head,
        .head_y = head_y,
        .out_end_y = out_end_y,
        .limit_y = limit_y,
        .closed = closed,
        .label = labelOnRow(head),
    };
}

/// What a block's output is right now.
pub const Output = union(enum) {
    none,
    /// Folded away: the text is in the store under this id.
    stored: u32,
    /// On screen: these rows.
    rows: Selection,
};

/// The output of the block that the row at `at` belongs to.
pub fn blockOutput(screen: *Screen, at: Pin) Output {
    const block = blockAt(screen, at) orelse return .none;
    if (!block.hasOutput()) {
        const label = block.label orelse return .none;
        return .{ .stored = label.id };
    }
    const first = block.head.down(1) orelse return .none;
    const end = screen.pages.pin(.{ .screen = .{
        .x = screen.pages.cols - 1,
        .y = @intCast(block.out_end_y - 1),
    } }) orelse return .none;
    return .{ .rows = Selection.init(first, end, false) };
}

/// The command line of the block that the row at `at` belongs to: the cells
/// the shell marked as typed input, or the text of the line when a prompt
/// theme lost those marks.
pub fn blockCommand(screen: *Screen, at: Pin) ?Selection {
    const block = blockAt(screen, at) orelse return null;
    var head_end = block.head;
    head_end.x = block.head.node.cols() - 1;

    var first: ?Pin = null;
    var last: Pin = block.start;
    var it = block.start.cellIterator(.right_down, head_end);
    while (it.next()) |p| {
        const cell = p.rowAndCell().cell;
        if (cell.semantic_content != .input or !cell.hasText()) continue;
        if (first == null) first = p;
        last = p;
    }
    if (first) |start| return Selection.init(start, last, false);

    // Fall back to the line's text, up to the label.
    const stop: usize = if (block.label) |label| label.x else block.head.node.cols();
    var p = block.head;
    var from: ?Pin = null;
    var x: usize = 0;
    while (x < stop) : (x += 1) {
        p.x = @intCast(x);
        if (!p.rowAndCell().cell.hasText()) continue;
        if (from == null) from = p;
        last = p;
    }
    const start = from orelse return null;
    return Selection.init(start, last, false);
}

// ---------------------------------------------------------------------------
// The blocks in view, for the app
// ---------------------------------------------------------------------------

/// One block as the viewport shows it. Rows count from the top of the
/// viewport.
pub const BlockInfo = extern struct {
    /// First and last row of the box.
    top: i32,
    bottom: i32,
    /// The command line, where the buttons go. -1 when it is above the view.
    head: i32,
    /// Rows of output: what the fold holds, or what is showing.
    lines: u32,
    flags: u32,
};

pub const flags = struct {
    /// The block starts above the view, or carries on below it.
    pub const clipped_top: u32 = 1 << 0;
    pub const clipped_bottom: u32 = 1 << 1;
    /// Its output is folded away.
    pub const folded: u32 = 1 << 2;
    /// It has output on screen.
    pub const has_output: u32 = 1 << 3;
    /// It is the prompt being typed at.
    pub const live: u32 = 1 << 4;
    /// The row above the box, or below it, is blank.
    pub const pad_above: u32 = 1 << 5;
    pub const pad_below: u32 = 1 << 6;
    /// Its command is still running.
    pub const running: u32 = 1 << 7;
    /// Folding or opening it would do something right now.
    pub const can_toggle: u32 = 1 << 8;
    /// It has a fold label, folded or open.
    pub const labeled: u32 = 1 << 9;
    /// Nothing was typed on its command line and nothing was printed.
    pub const empty: u32 = 1 << 10;
    /// Its command line starts with the Signal prompt's pointer mark, so the app draws
    /// the pointer there.
    pub const pointer: u32 = 1 << 11;
    /// This command failed (its pointer mark says so; see `markFailed`).
    pub const failed: u32 = 1 << 12;
};

/// Blank characters, one cell wide, that the Signal prompt writes so the app can draw its
/// pointer, its chip frames and their icons over exact cells.
pub const marks = struct {
    /// Where the pointer goes. The shell writes the first. The second is what the
    /// first is changed to, here, on the command line of a command that failed: the
    /// failure is recorded on the command that failed and stays with its row, rather
    /// than being shown on whatever prompt comes after it.
    pub const pointer: u21 = 0x2002;
    pub const pointer_failed: u21 = 0x2003;
    /// The first cell of a chip, by kind, and the last cell of any chip.
    pub const chip_dir: u21 = 0x2005;
    pub const chip_git: u21 = 0x2006;
    pub const chip_env: u21 = 0x2008;
    pub const chip_key: u21 = 0x200A;
    pub const chip_end: u21 = 0x2009;
    /// Which of the prompt's looks the shell laid its text out for. None means the card.
    pub const style_rail: u21 = 0x2000;
    pub const style_capsule: u21 = 0x2001;
    pub const style_dock: u21 = 0x2004;
    pub const style_hud: u21 = 0x2007;
};

/// One chip of the prompt being typed at: its viewport row and its first and last column.
pub const Chip = extern struct {
    row: i32 = -1,
    start: u16 = 0,
    end: u16 = 0,
    /// 1 directory, 2 git branch, 3 environment, 4 key hint.
    kind: u32 = 0,
};

/// What the prompt being typed at marked, if it is in view.
pub const PromptInfo = extern struct {
    count: u32 = 0,
    /// 0 card, 1 rail, 2 capsule, 3 dock, 4 brackets.
    style: u32 = 0,
    /// Where the pointer goes, in viewport cells; -1 when the prompt marked none.
    pointer_row: i32 = -1,
    pointer_col: i32 = -1,
    /// Not used any more, always 0. A failure is shown on the block of the command that
    /// failed (`flags.failed`), not on the prompt after it.
    failed: u32 = 0,
    /// The command line of the block that was last folded or opened in this terminal,
    /// as a viewport row (-1 when it is out of view), and a count that goes up with
    /// every such change anywhere.
    changed_row: i32 = -1,
    changed_serial: u32 = 0,
    /// The screen row the view starts at, so the app can tell one block from another
    /// while the view scrolls (a block's viewport row plus this stays the same).
    view_top: u32 = 0,
    /// 1 while the shell is at a prompt on the plain screen: the moment blocks can be
    /// folded, and the moment the app's block keys are its own.
    ready: u32 = 0,
    /// Cursor position in viewport cells (-1 when offscreen), style (0 bar, 1 block,
    /// 2 hollow block, 3 underline, 4 lock), and flags (1 visible, 2 blinking, 4 wide,
    /// 8 the cell under it holds text).
    cursor_row: i32 = -1,
    cursor_col: i32 = -1,
    cursor_style: u32 = 0,
    cursor_flags: u32 = 0,
    chips: [6]Chip = @splat(.{}),
};

/// Finds the chips marked on viewport rows `first` through `last`.
fn scanChips(top: Pin, first: usize, last: usize, found: *PromptInfo) void {
    const Open = struct { x: usize, kind: u32 };
    var r = first;
    while (r <= last) : (r += 1) {
        const pin = top.down(r) orelse return;
        var open: ?Open = null;
        for (pin.cells(.all), 0..) |*cell, x| {
            const mark = cell.codepoint();
            if (mark < 0x2000 or mark > 0x200A) continue;
            switch (mark) {
                marks.style_rail => found.style = 1,
                marks.style_capsule => found.style = 2,
                marks.style_dock => found.style = 3,
                marks.style_hud => found.style = 4,
                marks.pointer, marks.pointer_failed => if (found.pointer_row < 0) {
                    found.pointer_row = @intCast(r);
                    found.pointer_col = @intCast(x);
                },
                marks.chip_dir => open = .{ .x = x, .kind = 1 },
                marks.chip_git => open = .{ .x = x, .kind = 2 },
                marks.chip_env => open = .{ .x = x, .kind = 3 },
                marks.chip_key => open = .{ .x = x, .kind = 4 },
                marks.chip_end => if (open) |chip| {
                    if (found.count < found.chips.len) {
                        found.chips[found.count] = .{
                            .row = @intCast(r),
                            .start = @intCast(chip.x),
                            .end = @intCast(x),
                            .kind = chip.kind,
                        };
                        found.count += 1;
                    }
                    open = null;
                },
                else => {},
            }
        }
    }
}

const max_view_rows = 512;

/// Fills `out` with the blocks in the viewport, top to bottom, and returns
/// how many there are. This reads row flags and at most the cells of the
/// rows in view, so it is cheap enough to call as the view changes.
pub fn viewportBlocks(t: *Terminal, out: []BlockInfo, prompt: *PromptInfo) usize {
    prompt.* = .{};
    // Populate cursor state for every screen (including alternate screen / pre-prompt)
    // so the Signal cursor tracks the terminal cursor cleanly everywhere.
    {
        const active_screen: *Screen = t.screens.active;
        if (active_screen.pages.pointFromPin(.viewport, active_screen.cursor.page_pin.*)) |pt| {
            const cell_wide = active_screen.cursor.page_cell.wide;
            const cx: usize = if (cell_wide == .spacer_tail) pt.viewport.x -| 1 else pt.viewport.x;
            prompt.cursor_row = @intCast(pt.viewport.y);
            prompt.cursor_col = @intCast(cx);
            var cflags: u32 = 0;
            if (t.modes.get(.cursor_visible)) cflags |= 1;
            if (t.modes.get(.cursor_blinking)) cflags |= 2;
            if (cell_wide == .wide or cell_wide == .spacer_tail) cflags |= 4;
            if (cflags & 4 != 0 or active_screen.cursor.page_cell.hasText()) cflags |= 8;
            prompt.cursor_flags = cflags;
            prompt.cursor_style = if (t.flags.password_input) 4 else switch (active_screen.cursor.cursor_style) {
                .bar => 0,
                .block => 1,
                .block_hollow => 2,
                .underline => 3,
            };
        }
    }
    if (out.len == 0) return 0;
    if (t.screens.active_key != .primary) return 0;
    const screen: *Screen = t.screens.active;
    if (!screen.semantic_prompt.seen) return 0;

    // One pass over the rows in view: prompt state, text, links.
    const has_text: u8 = 4;
    const has_link: u8 = 8;
    var kind: [max_view_rows]u8 = undefined;
    const top = screen.pages.getTopLeft(.viewport);
    var rows: usize = 0;
    {
        var next: ?Pin = top;
        const want: usize = @min(t.rows, max_view_rows);
        while (rows < want) : (rows += 1) {
            var p = next orelse break;
            p.x = 0;
            const row = p.rowAndCell().row;
            var k: u8 = @backingInt(row.semantic_prompt);
            if (!row.blank and Cell.hasTextAny(p.cells(.all))) k |= has_text;
            if (row.hyperlink) k |= has_link;
            kind[rows] = k;
            next = p.down(1);
        }
    }
    if (rows == 0) return 0;

    const at_prompt = t.cursorIsAtPrompt();
    const cursor_row: ?usize = cursor: {
        const pt = screen.pages.pointFromPin(
            .viewport,
            screen.cursor.page_pin.*,
        ) orelse break :cursor null;
        break :cursor pt.viewport.y;
    };
    const rewritable = canRewrite(t);

    // The first row in view that is on the active screen (the row count when the view
    // is all scrollback). A block can only be folded if it reaches the active screen:
    // its command line has to end up there to be labeled.
    const active_from: usize = from: {
        const active_top = screen.pages.getTopLeft(.active);
        if (screen.pages.pointFromPin(.viewport, active_top)) |pt| break :from pt.viewport.y;
        // The active screen starts above the view (all of it is active) or below it.
        break :from if (screen.pages.pointFromPin(.active, top) != null) 0 else rows;
    };

    prompt.ready = @intFromBool(at_prompt and rewritable);
    if (screenY(screen, top)) |top_y| prompt.view_top = @intCast(top_y);
    prompt.changed_serial = changed_serial;
    if (changed_terminal == @intFromPtr(t)) {
        if (screenY(screen, top)) |top_y| {
            if (changed_y >= top_y and changed_y - top_y < rows) {
                prompt.changed_row = @intCast(changed_y - top_y);
            }
        }
    }

    var count: usize = 0;
    var r: usize = 0;

    // Rows before the first prompt in view belong to a block that starts
    // above the view, unless the view starts at the very top of the screen.
    if (kind[0] & 3 == 0) {
        var e: usize = 0;
        while (e < rows and kind[e] & 3 == 0) e += 1;
        if (top.up(1) != null) {
            var bottom = e - 1;
            while (bottom > 0 and kind[bottom] & has_text == 0) bottom -= 1;
            const has_text_out = kind[bottom] & has_text != 0;
            const holds_cursor = if (cursor_row) |c| c < e else false;
            if (!at_prompt and holds_cursor) {
                bottom = @max(bottom, cursor_row.?);
            }
            if (has_text_out or (!at_prompt and holds_cursor)) {
                var f: u32 = flags.clipped_top;
                if (has_text_out) f |= flags.has_output;
                if (bottom + 1 < rows and kind[bottom + 1] & has_text == 0) f |= flags.pad_below;
                if (e == rows and bottom == rows - 1) f |= flags.clipped_bottom;
                if (!at_prompt and (holds_cursor or e == rows)) f |= flags.running;
                // It can be folded from here, without scrolling back to its command
                // line first: that line is brought down into view by the fold.
                if (at_prompt and rewritable and e > active_from) f |= flags.can_toggle;
                out[count] = .{
                    .top = 0,
                    .bottom = @intCast(bottom),
                    .head = -1,
                    .lines = 0,
                    .flags = f,
                };
                count += 1;
            }
        }
        r = e;
    }

    while (r < rows and count < out.len) {
        // Prompt rows, then output rows up to the next prompt.
        const start = r;
        var head = r;
        while (head + 1 < rows and kind[head + 1] & 3 == 2) head += 1;
        var e = head + 1;
        while (e < rows and kind[e] & 3 == 0) e += 1;
        r = e;

        var box_top = start;
        while (box_top < head and kind[box_top] & has_text == 0) box_top += 1;
        var bottom = e - 1;
        while (bottom > head and kind[bottom] & has_text == 0) bottom -= 1;

        var f: u32 = 0;
        var lines: u32 = @intCast(bottom - head);
        if (bottom > head) f |= flags.has_output;

        const holds_cursor = if (cursor_row) |c| c >= start and c < e else false;
        if (at_prompt and holds_cursor) f |= flags.live;
        const last = e == rows;
        if (!at_prompt and (holds_cursor or (last and cursor_row == null))) f |= flags.running;

        // Keep the cursor inside its live or running block even on a trailing blank line.
        if ((f & (flags.live | flags.running)) != 0 and holds_cursor) {
            if (cursor_row) |c| {
                if (c < box_top) box_top = c;
                if (c > bottom) bottom = c;
            }
        }

        if (last and bottom == rows - 1 and f & flags.live == 0) f |= flags.clipped_bottom;

        if (box_top > 0 and kind[box_top - 1] & has_text == 0) f |= flags.pad_above;
        if (bottom + 1 < rows and kind[bottom + 1] & has_text == 0) f |= flags.pad_below;

        // The Signal prompt's marks: its pointer at the start of every command (on the
        // first of its rows when it was typed over several), and the chips of the prompt
        // being typed at. A prompt being typed at is never the one that failed.
        {
            var pr = box_top;
            while (pr <= head) : (pr += 1) {
                const pin = top.down(pr) orelse break;
                switch (pin.rowAndCell().cell.codepoint()) {
                    marks.pointer => f |= flags.pointer,
                    marks.pointer_failed => {
                        f |= flags.pointer;
                        if (f & flags.live == 0) f |= flags.failed;
                    },
                    else => continue,
                }
                break;
            }
        }
        if (f & flags.live != 0) scanChips(top, box_top, head, prompt);

        // The label, when the command line has links at all.
        var stored = false;
        if (kind[head] & has_link != 0) label: {
            const pin = top.down(head) orelse break :label;
            const label = labelOnRow(pin) orelse break :label;
            f |= flags.labeled;
            const state = info(label.id) orelse break :label;
            stored = true;
            if (f & flags.has_output == 0) {
                f |= flags.folded;
                lines = state.lines;
            }
        }

        // A prompt that was left empty is not a command.
        if (f & (flags.has_output | flags.labeled | flags.live) == 0) empty: {
            const pin = top.down(head) orelse break :empty;
            for (pin.cells(.all)) |*cell| {
                if (cell.semantic_content == .input and cell.hasText()) break :empty;
            }
            f |= flags.empty;
        }

        // Offer the fold control only where it will do something. Output can be folded
        // when its block reaches the active screen. A fold whose text is still kept can
        // always be looked at: in place when its command line is on the active screen,
        // and otherwise the app shows the text over the pane (`toggleBlock` refuses,
        // and the app falls back to its peek).
        const finished = at_prompt and f & (flags.live | flags.running) == 0;
        if (finished and rewritable) {
            if (stored and f & flags.has_output == 0) {
                f |= flags.can_toggle;
            } else if (f & flags.has_output != 0 and e > active_from) {
                f |= flags.can_toggle;
            }
        }

        out[count] = .{
            .top = @intCast(box_top),
            .bottom = @intCast(bottom),
            .head = @intCast(head),
            .lines = lines,
            .flags = f,
        };
        count += 1;
    }

    return count;
}

// ---------------------------------------------------------------------------
// Folding and opening
// ---------------------------------------------------------------------------

/// True while the screen is in the plain state a shell prompt leaves it in.
/// Blocks are only rewritten then, never under a full-screen program.
fn canRewrite(t: *Terminal) bool {
    if (t.screens.active_key != .primary) return false;
    if (t.modes.get(.origin)) return false;
    return t.scrolling_region.top == 0 and
        t.scrolling_region.bottom == t.rows - 1 and
        t.scrolling_region.left == 0 and
        t.scrolling_region.right == t.cols - 1;
}

/// The text of screen rows `first` up to `end`, as VT text owned by the
/// store's allocator.
fn captureRows(screen: *Screen, first: usize, end: usize) ![:0]const u8 {
    const start = screen.pages.pin(.{ .screen = .{
        .x = 0,
        .y = @intCast(first),
    } }) orelse return error.OutOfBounds;
    const stop = screen.pages.pin(.{ .screen = .{
        .x = screen.pages.cols - 1,
        .y = @intCast(end - 1),
    } }) orelse return error.OutOfBounds;

    var aw: std.Io.Writer.Allocating = .init(store_alloc);
    defer aw.deinit();
    var formatter: ScreenFormatter = .init(screen, .{
        .emit = .vt,
        .unwrap = true,
        .trim = true,
    });
    formatter.content = .{ .selection = Selection.init(start, stop, false) };
    formatter.format(&aw.writer) catch return error.OutOfMemory;
    return try aw.toOwnedSliceSentinel(0);
}

/// What stays where it is on the screen when rows are folded away.
const Anchor = enum {
    /// The command line that was clicked. Everything under it moves up, and the rows
    /// that are freed are left blank at the bottom, as if less had been printed. Your
    /// eye and the pointer are on that command line, so it is the thing that must not
    /// jump, and a second click in the same place undoes the first.
    ///
    /// When the command line is not on the screen at all (long output, folded from the
    /// rows still in view), there is nothing in view to hold still except the cursor.
    /// Then the space is filled from the scrollback, as far as it reaches, and the
    /// command line arrives with it.
    command_line,

    /// The cursor. Used when output is folded for you while you are at the keyboard:
    /// the rows from the fold down to the cursor do not move at all, and the space is
    /// filled from above, by lines coming back out of the scrollback. When the
    /// scrollback does not hold enough lines to do that, nothing is folded.
    cursor,

    /// The cursor, as far as the scrollback allows. Used when you ask for everything to
    /// be folded from the keyboard: it is done either way, the space is filled from the
    /// scrollback, and the cursor only moves up by what the scrollback could not fill.
    bottom,
};

/// True when `count` rows can be folded away with the cursor staying on its row.
fn cursorCanStay(screen: *Screen, count: usize) bool {
    return screen.pages.total_rows - screen.pages.rows >= count;
}

/// Folds screen rows away: the text of rows `first` up to `text_end` is
/// kept, rows `first` up to `erase_end` are removed, and the command line
/// (the row above `first`) is labeled. With a label already there, its fold
/// takes the new text. Returns false if nothing was changed.
fn foldRows(
    t: *Terminal,
    first: usize,
    text_end: usize,
    erase_end: usize,
    existing: ?Label,
    anchor: Anchor,
) !bool {
    const screen: *Screen = t.screens.active;
    if (first == 0 or text_end <= first or erase_end < text_end) return false;
    const count = erase_end - first;
    const lines: u32 = @intCast(text_end - first);

    const head = screen.pages.pin(.{ .screen = .{
        .x = 0,
        .y = @intCast(first - 1),
    } }) orelse return false;

    // How many of the freed rows are taken back from the scrollback (the rest are left
    // blank at the bottom of the screen). See `Anchor`.
    const history = screen.pages.total_rows - screen.pages.rows;
    const head_y = first - 1;
    const trim: usize = switch (anchor) {
        // All of them, so nothing from the fold down moves.
        .cursor => trim: {
            if (history < count) return false;
            break :trim count;
        },
        // None, so nothing above the fold moves. Unless the command line is up in the
        // scrollback: then as many as there are, which brings it down into view.
        .command_line => if (head_y >= history) 0 else @min(count, history),
        .bottom => @min(count, history),
    };

    // A new label is written with the cursor, so the command line has to be on the
    // active screen once the rows are gone.
    const x: usize = if (existing) |label| label.x else x: {
        if (head_y < history - trim) return false;
        break :x labelColumn(head, t.cols, lines) orelse return false;
    };

    // Keep the text before the rows go.
    var preview_buf: [160]u8 = undefined;
    const text = try captureRows(screen, first, text_end);
    const preview = previewInto(&preview_buf, text);
    const id = put(if (existing) |label| label.id else null, text, lines, t.cols);

    const head_pin = try screen.pages.trackPin(head);
    defer screen.pages.untrackPin(head_pin);

    // The cursor's style and hyperlink belong to the page it is on, and rows
    // are about to move between pages. Drop both first.
    try t.setAttribute(.unset);
    screen.endHyperlink();
    const cursor_before = screen.cursor.y;
    try screen.eraseRowsAt(first, count, trim);
    t.flags.dirty.clear = true;
    recordChange(t, head_y);
    note(72, @intCast(cursor_before), @intCast(screen.cursor.y), @intCast(trim));

    // Label the command line. One that is still up in the scrollback keeps
    // the label it has.
    const pt = screen.pages.pointFromPin(.active, head_pin.*) orelse return true;
    try writeLabel(t, pt.active.y, x, id, lines, preview);
    return true;
}

fn recordExit(t: *Terminal, failed: bool) void {
    lock();
    defer unlock();
    const key = @intFromPtr(t);
    for (&exits) |*entry| {
        if (entry.terminal == key) {
            entry.failed = failed;
            return;
        }
    }
    exits[exits_next % exits.len] = .{ .terminal = key, .failed = failed };
    exits_next +%= 1;
}

fn lastFailed(t: *Terminal) bool {
    lock();
    defer unlock();
    const key = @intFromPtr(t);
    for (&exits) |*entry| {
        if (entry.terminal == key) return entry.failed;
    }
    return false;
}

/// Records on the screen that the command that just finished failed: the pointer mark
/// at the start of its command line (a blank cell) becomes the failed one (another
/// blank cell). Nothing visible changes in the terminal. The app reads the mark and
/// shows the failure on that command's block, wherever it scrolls to.
fn markFailed(t: *Terminal) void {
    const screen: *Screen = t.screens.active;
    const cursor_pin = screen.cursor.page_pin.*;
    var it = cursor_pin.promptIterator(.left_up, null);
    // The command's prompt is the nearest one above the cursor. A prompt can be more
    // than one marked region (a spacer row, then the command line), so a few are tried.
    var tries: u8 = 0;
    while (it.next()) |candidate| : (tries += 1) {
        if (tries >= 3) return;
        var p = candidate;
        p.x = 0;
        var rows: usize = 0;
        while (rows < 64 and isPrompt(p)) : (rows += 1) {
            const cell = p.rowAndCell().cell;
            if (cell.content_tag == .codepoint and cell.content.codepoint.data == marks.pointer) {
                cell.content = .{ .codepoint = .{ .data = marks.pointer_failed } };
                return;
            }
            p = p.down(1) orelse break;
        }
    }
}

/// Called when a command finishes, before the next prompt is drawn.
pub fn commandFinished(t: *Terminal, exit_code: u8) void {
    recordExit(t, exit_code != 0);
    if (exit_code != 0) markFailed(t);
    if (!fold_latest.load(.monotonic)) return status(13, 0);
    if (exit_code != 0) return status(14, exit_code);
    foldLastOutput(t) catch |err| {
        status(10, 0);
        log.warn("could not fold output err={}", .{err});
    };
}

/// Called when a command starts running (the line was accepted, nothing printed yet).
/// This is when the command before it is folded if its output was long: the screen is
/// changing anyway, and the newest output has stayed open for as long as it was newest.
pub fn commandStarted(t: *Terminal) void {
    foldPrevious(t) catch |err| {
        status(10, 1);
        log.warn("could not fold the previous output err={}", .{err});
    };
}

fn foldPrevious(t: *Terminal) !void {
    if (fold_latest.load(.monotonic)) return;
    const limit = threshold.load(.monotonic);
    if (limit == 0) return;
    if (!canRewrite(t)) return;
    if (lastFailed(t)) return status(14, 1);
    const screen: *Screen = t.screens.active;

    // The prompt of the command that is starting, then the one before it.
    const cursor_pin = screen.cursor.page_pin.*;
    var it = cursor_pin.promptIterator(.left_up, null);
    _ = it.next() orelse return;
    const previous = it.next() orelse return;
    const block = blockAt(screen, previous) orelse return;
    if (!block.closed or !block.hasOutput()) return;
    // A block with a label has been folded before. If it is showing now, you opened
    // it, and it stays the way you left it.
    if (block.label != null) return;
    const lines = block.out_end_y - (block.head_y + 1);
    if (lines <= limit or lines > max_lines) return status(8, @intCast(lines));
    const cursor_y = screenY(screen, cursor_pin) orelse return;
    if (block.limit_y > cursor_y) return;
    // Never at the price of moving the line that is being typed on.
    if (!cursorCanStay(screen, block.limit_y - (block.head_y + 1))) return status(15, @intCast(lines));
    if (try foldRows(t, block.head_y + 1, block.out_end_y, block.limit_y, null, .cursor)) {
        status(9, @intCast(lines));
    } else {
        status(12, @intCast(lines));
    }
}

fn foldLastOutput(t: *Terminal) !void {
    const limit = threshold.load(.monotonic);
    if (limit == 0) return status(1, 0);
    if (!canRewrite(t)) return status(2, 0);
    const screen: *Screen = t.screens.active;

    // Only when the output ended with a newline: the cursor then sits at the
    // start of its own empty line, where the next prompt goes.
    if (screen.cursor.x != 0) return status(3, screen.cursor.x);

    // The finished command's prompt is the nearest one above the cursor that
    // has output under it. A prompt theme can leave rows marked as prompts
    // that have none (a blank spacer line, a first line of decoration).
    const cursor_pin = screen.cursor.page_pin.*;
    var it = cursor_pin.promptIterator(.left_up, null);
    var tries: u8 = 0;
    var prompt_pin: Pin = cursor_pin;
    const output = while (it.next()) |candidate| {
        if (screen.pages.highlightSemanticContent(candidate, .output)) |hl| {
            prompt_pin = candidate;
            break hl;
        }
        tries += 1;
        if (tries >= 4) return status(5, tries);
    } else return status(4, tries);

    const found_first = screenY(screen, output.start) orelse return status(6, 1);
    const found_last = screenY(screen, output.end) orelse return status(6, 2);
    const cursor_y = screenY(screen, cursor_pin) orelse return status(6, 3);

    // The output starts on the row under the command line, even if that row
    // is blank. The command line is the last row of the prompt.
    var head = prompt_pin;
    while (head.down(1)) |next| {
        if (next.rowAndCell().row.semantic_prompt != .prompt_continuation) break;
        head = next;
    }
    const head_y = screenY(screen, head) orelse return status(6, 4);
    const first = @min(found_first, head_y + 1);
    if (first <= head_y) return status(7, 1);

    // The cursor's own row is never output. zsh (PROMPT_SP) writes an
    // end-of-line marker and padding on it before the prompt hooks run, and
    // the prompt is about to be drawn over it.
    if (cursor_y <= first or found_last < first) {
        note(70, @intCast(first), @intCast(found_last), @intCast(cursor_y));
        return status(7, 0);
    }
    const last = @min(found_last, cursor_y - 1);
    note(71, @intCast(first), @intCast(last), @intCast(cursor_y));
    const lines: u32 = @intCast(last - first + 1);
    if (lines <= limit or lines > max_lines) return status(8, lines);

    // Never at the price of moving the line the prompt is about to be drawn on.
    if (!cursorCanStay(screen, cursor_y - first)) return status(15, lines);
    if (!try foldRows(t, first, last + 1, cursor_y, null, .cursor)) return status(12, lines);

    // The cursor is now directly under the command line. Clear what the
    // shell left on its row.
    t.eraseLine(.complete, false);
    status(9, lines);
}

/// Rows under the cursor that are blank, down to the bottom of the screen.
/// Zero if any row there has text.
fn blankRowsBelowCursor(t: *Terminal) usize {
    const screen: *Screen = t.screens.active;
    var p = screen.cursor.page_pin.*;
    var n: usize = 0;
    while (p.down(1)) |next| {
        if (rowHasText(next)) return 0;
        p = next;
        n += 1;
    }
    return n;
}

/// Puts a folded block's output back under its command line.
///
/// The rows come from two places. Blank rows at the bottom of the screen
/// are used first: everything under the command line moves down into them.
/// For the rest, everything above scrolls up into the scrollback, the way
/// it would have if the output had just been printed. If that carries the
/// command line off the top, the view follows it.
fn expand(t: *Terminal, block: Block, label: Label, alloc: std.mem.Allocator) !bool {
    const screen: *Screen = t.screens.active;
    const state = info(label.id) orelse return false;

    // The command line has to be on the active screen, above the cursor.
    const row = (screen.pages.pointFromPin(.active, block.head) orelse return false).active.y;
    if (row >= screen.cursor.y) return false;

    const text = getVt(alloc, label.id) orelse return false;
    defer alloc.free(text);

    // Room under the prompt can only be counted on when the text will wrap
    // the way it did.
    const down: usize = if (state.cols == t.cols)
        @min(blankRowsBelowCursor(t), state.lines)
    else
        0;
    if (row == 0 and down == 0) return false;

    const saved_x = screen.cursor.x;
    const saved_y = screen.cursor.y;
    const saved_wrap = screen.cursor.pending_wrap;
    const semantic = screen.cursor.semantic_content;
    const semantic_eol = screen.cursor.semantic_content_clear_eol;
    const history_before = screen.pages.total_rows - screen.pages.rows;
    try t.setAttribute(.unset);
    screen.endHyperlink();

    const head_pin = try screen.pages.trackPin(block.head);
    defer screen.pages.untrackPin(head_pin);

    if (down > 0) {
        t.setTopAndBottomMargin(row + 2, t.rows);
        t.setCursorPos(row + 2, 1);
        t.insertLines(down);
    }

    // From the command line, a line feed lands on the first output row:
    // one of the rows just opened, or a row made by scrolling.
    t.setTopAndBottomMargin(1, row + 1 + down);
    t.setCursorPos(row + 1, 1);
    screen.cursor.semantic_content = .output;
    screen.cursor.semantic_content_clear_eol = false;
    try t.linefeed();
    t.carriageReturn();
    {
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(text);
    }

    // Back to the full screen and the cursor's own place.
    try t.setAttribute(.unset);
    screen.endHyperlink();
    t.setTopAndBottomMargin(1, t.rows);
    t.setCursorPos(saved_y + down + 1, saved_x + 1);
    screen.cursor.pending_wrap = saved_wrap;
    screen.cursor.semantic_content = semantic;
    screen.cursor.semantic_content_clear_eol = semantic_eol;

    if (screen.pages.pointFromPin(.active, head_pin.*)) |pt| {
        // The open block needs no preview: its first line is right there.
        try writeLabel(t, pt.active.y, label.x, label.id, state.lines, "");
    }

    // Making room pushed rows up into the scrollback. The view stays where it was, so
    // the command line you opened does not move and its output unrolls under it. The
    // prompt may now be below the view; typing brings it back.
    const history_after = screen.pages.total_rows - screen.pages.rows;
    if (history_after > history_before) screen.scroll(.{ .row = history_before });
    recordChange(t, block.head_y);
    return true;
}

/// Folds or opens the block that the row at `pin` belongs to. Returns false
/// if nothing was changed.
pub fn toggleAt(t: *Terminal, pin: Pin, alloc: std.mem.Allocator) bool {
    const changed = toggleBlock(t, pin, alloc) catch |err| changed: {
        log.warn("could not toggle block err={}", .{err});
        note(42, 0, 0, 0);
        break :changed false;
    };
    if (changed) t.flags.dirty.clear = true;
    return changed;
}

fn toggleBlock(t: *Terminal, pin: Pin, alloc: std.mem.Allocator) !bool {
    // Only between commands: a running program owns the screen.
    if (!canRewrite(t)) return refused(21);
    if (!t.cursorIsAtPrompt()) return refused(22);
    const screen: *Screen = t.screens.active;
    const block = blockAt(screen, pin) orelse return refused(23);
    if (!block.closed) return refused(24);
    note(20, @intCast(block.head_y), @intCast(block.out_end_y), @intCast(block.limit_y));

    if (block.hasOutput()) {
        const cursor_y = screenY(screen, screen.cursor.page_pin.*) orelse return refused(25);
        if (block.limit_y > cursor_y) return refused(26);
        if (block.out_end_y - (block.head_y + 1) > max_lines) return refused(27);
        const done = try foldRows(t, block.head_y + 1, block.out_end_y, block.limit_y, block.label, .command_line);
        return if (done) true else refused(28);
    }
    const label = block.label orelse return refused(29);
    const done = try expand(t, block, label, alloc);
    return if (done) true else refused(30);
}

/// Whether the shell has the plain screen to itself: no full-screen program (an editor,
/// a pager) is showing. The app's own keys are only taken from the terminal then.
pub fn plainScreen(t: *Terminal) bool {
    return canRewrite(t);
}

/// Folds every block whose output is worth folding or, when none is left to fold, opens
/// every fold that can be opened in place. Returns how many blocks changed, or null when
/// this is not the moment (a program is running, or has the screen), so that the key
/// that asked can go to that program instead.
pub fn toggleAll(t: *Terminal, alloc: std.mem.Allocator) ?u32 {
    if (!canRewrite(t) or !t.cursorIsAtPrompt()) return null;
    var changed: u32 = 0;
    toggleAllBlocks(t, alloc, &changed) catch |err| {
        log.warn("could not fold or open every block err={}", .{err});
        note(42, 1, 0, 0);
    };
    if (changed > 0) t.flags.dirty.clear = true;
    note(50, changed, 0, 0);
    return changed;
}

/// The prompt `back` prompts above the cursor's own, which is 0.
fn promptBack(screen: *Screen, back: usize) ?Pin {
    const cursor_pin = screen.cursor.page_pin.*;
    var it = cursor_pin.promptIterator(.left_up, null);
    var i: usize = 0;
    while (it.next()) |pin| : (i += 1) {
        if (i == back) return pin;
    }
    return null;
}

fn toggleAllBlocks(t: *Terminal, alloc: std.mem.Allocator, changed: *u32) !void {
    const screen: *Screen = t.screens.active;
    // Blocks are named by how many prompts they are above the cursor. Folding and
    // opening move rows but never add or remove a prompt, so the count stays good
    // while positions do not.
    const most = 256;

    // Fold, from the newest finished command up. Each fold brings scrollback down, and
    // with it older blocks that were out of reach. A single row of output is left: its
    // label would take the same room.
    var back: usize = 1;
    var refusals: u8 = 0;
    while (back < most and refusals < 6) : (back += 1) {
        const pin = promptBack(screen, back) orelse break;
        const block = blockAt(screen, pin) orelse continue;
        if (!block.closed or !block.hasOutput()) continue;
        const lines = block.out_end_y - (block.head_y + 1);
        if (lines < 2 or lines > max_lines) continue;
        const cursor_y = screenY(screen, screen.cursor.page_pin.*) orelse break;
        if (block.limit_y > cursor_y) continue;
        if (try foldRows(t, block.head_y + 1, block.out_end_y, block.limit_y, block.label, .bottom)) {
            changed.* += 1;
            refusals = 0;
        } else {
            refusals += 1;
        }
    }
    if (changed.* > 0) return;

    // Nothing to fold, so open. The folds on the screen are found from the bottom up
    // and opened from the top down: an opening pushes what is above it into the
    // scrollback, and a fold up there could no longer be opened.
    var found: [64]usize = undefined;
    var n: usize = 0;
    back = 1;
    while (back < most and n < found.len) : (back += 1) {
        const pin = promptBack(screen, back) orelse break;
        const block = blockAt(screen, pin) orelse continue;
        if (block.hasOutput()) continue;
        const label = block.label orelse continue;
        if (info(label.id) == null) continue;
        if (screen.pages.pointFromPin(.active, block.head) == null) break;
        found[n] = back;
        n += 1;
    }
    while (n > 0) {
        n -= 1;
        const pin = promptBack(screen, found[n]) orelse continue;
        const block = blockAt(screen, pin) orelse continue;
        if (block.hasOutput()) continue;
        const label = block.label orelse continue;
        if (try expand(t, block, label, alloc)) changed.* += 1;
    }
    // Asked for from the keyboard: the view goes back to the prompt.
    if (changed.* > 0) screen.scroll(.active);
}

/// Records why a block was left as it was (see `trail`).
fn refused(code: u32) bool {
    note(code, 0, 0, 0);
    return false;
}

/// Folds or opens the nearest labeled block above the cursor.
pub fn toggleLast(t: *Terminal, alloc: std.mem.Allocator) bool {
    const screen: *Screen = t.screens.active;
    var p = screen.cursor.page_pin.*;
    p.x = 0;
    var steps: usize = 0;
    while (p.up(1)) |above| : (steps += 1) {
        if (steps > 4000) break;
        p = above;
        if (labelOnRow(p)) |label| {
            note(40, @intCast(steps), label.id, @intCast(label.x));
            return toggleAt(t, p, alloc);
        }
    }
    note(41, @intCast(steps), 0, 0);
    return false;
}
