//! A win32 GUI program that demonstrates how to catch, report and handle every kind of
//! error/crash. This example logs each one (with a trace if applicable) and shows a
//! message box. It logs to stderr. If there is no stderr (common for win32 applications)
//! it will open a log file and assign it to the stderr handle slot in the PEB.
//!
//! The window has a button for each kind of crash, which crashes from inside the window
//! procedure like a real GUI program would.

pub const std_options: std.Options = .{
    // std's segfault handler logs and aborts without a way for us to handle it. Disabling
    // it routes to our unhandledExceptionFilter like every other exception.
    .enable_segfault_handler = false,
};

const global = struct {
    /// The filter installed before ours (the mingw CRT's), which ours calls first. A filter
    /// gets no context argument, so this has to be a global.
    var previous_exception_filter: ?win32.LPTOP_LEVEL_EXCEPTION_FILTER = null;
    /// How far the panic handler got. A panic while logging or showing the message box re-enters
    /// the handler, which skips the step that panicked instead of recursing forever.
    var panic_state: enum { none, log, msgbox } = .none;
    /// Set while the filter writes its report. A fault while reporting re-enters the filter,
    /// which then skips the report and only shows the box, with the nested exception's code,
    /// so a fault that repeats every time doesn't recurse until the stack runs out.
    var reporting_exception = false;
};

// redirects panics to our handler which is almost the same as std's but ours
// shows a messagebox after writing the details to stderr.
pub const panic = std.debug.FullPanic(onPanic);
fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    if (global.panic_state == .none) {
        global.panic_state = .log;
        // Before the message box, which may never be dismissed.
        std.debug.print("panic: {s}\n", .{msg});
        const first_address = ret_addr orelse @returnAddress();
        if (zig_0_17)
            std.debug.dumpCurrentStackTrace(.{ .first_address = first_address })
        else
            std.debug.dumpCurrentStackTrace(first_address);
    }
    if (global.panic_state == .log) {
        global.panic_state = .msgbox;
        msgbox("{s}", .{msg});
    }
    // Not std.debug.defaultPanic, which would print the message and trace again.
    std.process.abort();
}

// note: do not return errors from main (i.e. use !void), we're not able to hook into
//       std's code that calls main, so it would just log the trace to stderr without
//       allowing us to show a messagebox.
pub fn main() void {
    // The mingw CRT (any program that links libc) installs a filter that maps exceptions to
    // signal() handlers. On the main thread it has already run by the time ours does, in the
    // __try mingw wraps around main. Ours chains to it so it also runs for other threads.
    global.previous_exception_filter = win32.SetUnhandledExceptionFilter(unhandledExceptionFilter);

    // Everything is reported through stderr. A GUI program usually starts without one, so if
    // stderr isn't usable, open a log file and use it as stderr.
    const params = std.os.windows.peb().ProcessParameters;
    if (!isUsableHandle(params.hStdError)) {
        params.hStdError = createLogFile(params.ImagePathName);
    }

    // Only needed if the program links C code that can call abort(). Zig's mingw libc uses
    // the Universal C Runtime, whose abort() (in ucrtbase.dll) raises SIGABRT and then ends the
    // process with a fast fail, which no exception filter sees. Panicking from the signal
    // handler reports it like any other panic, and the handler never returns to the fast fail.
    if (signal(SIGABRT, onAbort) == SIG_ERR) @panic("signal(SIGABRT) failed");

    {
        // Enough stack left after an overflow for the filter to write the trace and show the box.
        var stack_guarantee: u32 = 1024 * 1024;
        if (0 == win32.SetThreadStackGuarantee(&stack_guarantee)) win32.panicWin32("SetThreadStackGuarantee", win32.GetLastError());
    }

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
        win32.L("crashdemo"),
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

    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
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

/// Creates crashdemo.log next to the exe.
fn createLogFile(exe_path: std.os.windows.UNICODE_STRING) std.os.windows.HANDLE {
    const exe = exe_path.Buffer.?[0 .. exe_path.Length / 2];
    const dir = exe[0 .. std.mem.lastIndexOfScalar(u16, exe, '\\') orelse 0];
    const name = win32.L("\\crashdemo.log");
    var path_buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    if (dir.len + name.len > path_buf.len) @panic("exe path too long for the log path");
    @memcpy(path_buf[0..dir.len], dir);
    @memcpy(path_buf[dir.len..][0..name.len], name);
    path_buf[dir.len + name.len] = 0;
    const handle = win32.CreateFileW(
        path_buf[0 .. dir.len + name.len :0],
        win32.FILE_GENERIC_WRITE,
        .{ .READ = 1 },
        null,
        win32.CREATE_ALWAYS,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFile(crashdemo.log)", win32.GetLastError());
    return handle;
}

fn isUsableHandle(handle: std.os.windows.HANDLE) bool {
    if (@intFromPtr(handle) == 0) return false;
    // A parent that launches with handle inheritance can pass the value of a stderr handle it
    // didn't make inheritable, which isn't a handle in this process.
    win32.SetLastError(.NO_ERROR);
    return !(win32.GetFileType(handle) == .UNKNOWN and win32.GetLastError() == .ERROR_INVALID_HANDLE);
}

extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) usize;
const SIGABRT = 22;
const SIG_ERR = std.math.maxInt(usize);
fn onAbort(sig: c_int) callconv(.c) void {
    _ = sig;
    @panic("abort() was called");
}

fn unhandledExceptionFilter(maybe_info: ?*win32.EXCEPTION_POINTERS) callconv(.winapi) i32 {
    const continue_search: i32 = 0;
    const execute_handler: i32 = 1;
    if (global.previous_exception_filter) |previous| chain: {
        // mingw's filter (crt_handler.c) returns EXCEPTION_CONTINUE_EXECUTION for these, which
        // re-executes the faulting instruction forever.
        if (maybe_info) |i| switch (i.ExceptionRecord.?.ExceptionCode) {
            win32.EXCEPTION_DATATYPE_MISALIGNMENT,
            win32.EXCEPTION_ARRAY_BOUNDS_EXCEEDED,
            win32.EXCEPTION_FLT_STACK_CHECK,
            win32.EXCEPTION_INT_OVERFLOW,
            win32.EXCEPTION_INVALID_HANDLE,
            => break :chain,
            else => {},
        };
        const action = previous(maybe_info);
        if (action != continue_search) return action;
    }
    const info = maybe_info orelse return continue_search;
    const record = info.ExceptionRecord.?;
    // A Debug build's std.process.abort raises a breakpoint after a panic was already reported.
    if (record.ExceptionCode == win32.EXCEPTION_BREAKPOINT) return continue_search;
    const code = @intFromEnum(record.ExceptionCode);
    const address = @intFromPtr(record.ExceptionAddress);

    report: {
        if (global.reporting_exception) break :report;
        global.reporting_exception = true;
        var buf: [256]u8 = undefined;
        // The lock is recursive, so a panic in the code below can still take it.
        const stderr = if (zig_0_17) std.debug.lockStderr(&buf).terminal() else std.debug.lockStderrWriter(&buf);
        defer if (zig_0_17) std.debug.unlockStderr() else std.debug.unlockStderrWriter();
        const w = if (zig_0_17) stderr.writer else stderr;
        w.print("unhandled exception 0x{X:0>8} at 0x{x}", .{ code, address }) catch break :report;
        // Flushed before anything that could fault again, so the code and address get out.
        w.flush() catch break :report;
        writeModule(w, address) catch break :report;
        w.writeAll("\n") catch break :report;
        w.flush() catch break :report;
        const context: *std.os.windows.CONTEXT = @ptrCast(@alignCast(info.ContextRecord.?));
        if (zig_0_17) {
            const native = std.debug.cpu_context.fromWindowsContext(context);
            std.debug.writeCurrentStackTrace(.{ .context = &native }, stderr) catch break :report;
        } else std.debug.dumpStackTraceFromBase(context, w);
        w.flush() catch break :report;
    }
    msgbox("unhandled exception 0x{X:0>8} at 0x{x}", .{ code, address });
    return execute_handler;
}

fn writeModule(w: *std.Io.Writer, address: usize) error{WriteFailed}!void {
    var module: ?win32.HINSTANCE = null;
    // With FROM_ADDRESS, lpModuleName is any address in the module.
    if (0 == win32.GetModuleHandleExW(
        win32.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | win32.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        @ptrFromInt(address),
        &module,
    )) return w.print(" (GetModuleHandleExW failed, error={f})", .{win32.GetLastError()});
    const offset = address - @intFromPtr(module.?);
    // MAX_PATH, not PATH_MAX_WIDE (64 KiB): this runs on the faulting thread's stack.
    var path_buf: [win32.MAX_PATH:0]u16 = undefined;
    const len = win32.GetModuleFileNameW(module, &path_buf, path_buf.len + 1);
    if (len == 0 or len == path_buf.len + 1) return w.print(" (+0x{x})", .{offset});
    const path = path_buf[0..len];
    const name = path[if (std.mem.lastIndexOfScalar(u16, path, '\\')) |i| i + 1 else 0..];
    try w.print(" ({f}+0x{x})", .{ std.unicode.fmtUtf16Le(name), offset });
}

fn msgbox(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const len = if (std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args)) |text| text.len else |_| blk: {
        buf[buf.len - 4 ..][0..3].* = "...".*;
        break :blk buf.len - 1;
    };
    buf[len] = 0;
    _ = win32.MessageBoxA(null, buf[0..len :0], "crashdemo crash", .{ .ICONHAND = 1 });
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

/// Builds with Zig 0.15.2 and 0.17.0; keep the branches for your version.
const zig_0_17 = builtin.zig_version.order(.{ .major = 0, .minor = 17, .patch = 0 }) != .lt;

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
