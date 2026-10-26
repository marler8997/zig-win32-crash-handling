//! The crashdemo application: a window with a button for each kind of crash, which crashes
//! from inside the window procedure like a real GUI program would. Replace this file with
//! your own application; main.zig only needs `name` and `init` from it.

/// Names the log file and titles the crash message box.
pub const name = "crashdemo";

/// Creates the window. main.zig runs the message loop afterward.
pub fn init() void {
    {
        const class: win32.WNDCLASSEXW = .{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{},
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = win32.GetModuleHandleW(null),
            .hIcon = null,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = @ptrFromInt(@as(usize, @intFromEnum(win32.COLOR_BTNFACE)) + 1),
            .lpszMenuName = null,
            .lpszClassName = win32.L("CrashDemo"),
            .hIconSm = null,
        };
        if (0 == win32.RegisterClassExW(&class)) win32.panicWin32("RegisterClass", win32.GetLastError());
    }

    const kinds = std.enums.values(Crash);
    var rect: win32.RECT = .{
        .left = 0,
        .top = 0,
        .right = button_width + 2 * margin,
        .bottom = @intCast(kinds.len * (button_height + margin) + margin),
    };
    // WS_CAPTION is BORDER | DLGFRAME.
    const style: win32.WINDOW_STYLE = .{ .BORDER = 1, .DLGFRAME = 1, .SYSMENU = 1, .VISIBLE = 1 };
    if (0 == win32.AdjustWindowRect(&rect, style, 0)) win32.panicWin32("AdjustWindowRect", win32.GetLastError());
    const hwnd = win32.CreateWindowExW(
        .{},
        win32.L("CrashDemo"),
        win32.L(name),
        style,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        rect.right - rect.left,
        rect.bottom - rect.top,
        null,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse win32.panicWin32("CreateWindow", win32.GetLastError());

    inline for (comptime std.enums.values(Crash), 0..) |kind, i| {
        _ = win32.CreateWindowExW(
            .{},
            win32.L("BUTTON"),
            win32.L(comptime kind.label()),
            .{ .CHILD = 1, .VISIBLE = 1, .TABSTOP = 1 },
            margin,
            @intCast(margin + i * (button_height + margin)),
            button_width,
            button_height,
            hwnd,
            @ptrFromInt(@intFromEnum(kind) + 1),
            win32.GetModuleHandleW(null),
            null,
        ) orelse win32.panicWin32("CreateWindow(BUTTON)", win32.GetLastError());
    }
}

const Crash = enum {
    panic,
    bounds,
    av,
    trap,
    stackoverflow,
    div0,
    raise,
    abort,
    fastfail,

    fn label(comptime kind: Crash) []const u8 {
        return switch (kind) {
            .panic => "@panic",
            .bounds => "Index out of bounds (safety check)",
            .av => "Access violation",
            .trap => "Illegal instruction (@trap)",
            .stackoverflow => "Stack overflow",
            .div0 => "Integer divide by zero (hardware, like C code)",
            .raise => "RaiseException with a custom code",
            .abort => "C abort()",
            .fastfail => "__fastfail (not reported, by design)",
        };
    }
};

const button_height = 28;
const button_width = 360;
const margin = 10;

fn wndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_COMMAND => {
            const id: u16 = @truncate(wparam);
            if (id >= 1 and id <= std.enums.values(Crash).len) {
                const kind: Crash = @enumFromInt(id - 1);
                std.log.info("crashing with '{t}' from the window procedure", .{kind});
                crash(kind);
            }
            return 0;
        },
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn crash(kind: Crash) void {
    switch (kind) {
        .panic => @panic("crashdemo panic"),
        .bounds => {
            var array = [_]u8{ 1, 2, 3 };
            var index: usize = 5;
            std.mem.doNotOptimizeAway(&index);
            std.mem.doNotOptimizeAway(array[index]);
            std.mem.doNotOptimizeAway(&array);
        },
        .av => {
            const p: *volatile u8 = @ptrFromInt(0x10);
            p.* = 1;
        },
        .trap => @trap(),
        .stackoverflow => std.mem.doNotOptimizeAway(recurse(0)),
        .div0 => asm volatile (
            \\xorl %%ecx, %%ecx
            \\xorl %%edx, %%edx
            \\movl $1, %%eax
            \\divl %%ecx
            ::: .{ .eax = true, .ecx = true, .edx = true }),
        .raise => win32.RaiseException(0xE0001234, 0, 0, null),
        .abort => std.c.abort(),
        // Not reported, by design: only Windows Error Reporting sees a fast fail.
        .fastfail => asm volatile ("int $0x29"
            :
            : [code] "{ecx}" (@as(u32, 7)),
        ),
    }
    std.debug.panic("crash '{t}' returned", .{kind});
}

noinline fn recurse(depth: usize) usize {
    var buf: [4096]u8 = undefined;
    buf[depth % buf.len] = @truncate(depth);
    std.mem.doNotOptimizeAway(&buf);
    return recurse(depth + 1) + buf[depth % buf.len];
}

const std = @import("std");
const win32 = @import("win32").everything;
