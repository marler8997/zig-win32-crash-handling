//! Catches, reports and handles every kind of error/crash in a win32 GUI program. This
//! example logs each one (with a trace if applicable) and shows a message box. It logs to
//! stderr. If there is no stderr (common for win32 applications) it will open a log file and
//! assign it to the stderr handle slot in the PEB.
//!
//! This is the file to copy into your project. The demo application lives in app.zig, which
//! main.zig uses only for `app.name` and `app.init()`.

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

/// The stack left after an overflow, for the filter to write the report and show the box.
/// Without it the filter overflows again and Windows ends the process with no report. The
/// trace needs almost all of it, to open the PDB: std's Windows file functions put several
/// 64 KiB path buffers on the stack. Zig can't compute a call's stack requirement, so the
/// smallest guarantee that still reports was found by trial. It depends on the Zig version and
/// optimize mode, and on whatever else the filter does:
///     Zig 0.15.2: 1.15 MiB Debug, 0.75 MiB ReleaseSafe
///     Zig 0.17.0: 1.6 MiB Debug, 0.7 MiB ReleaseSafe
/// It comes out of each thread's stack (16 MiB for the main thread, Zig's default for an exe).
/// Run `zig build test` (in each optimize mode you ship) after changing the Zig version, the
/// report or this size: the test below overflows a stack and fails if the report no longer fits.
const stack_guarantee = 2 * 1024 * 1024;

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

    // Only for this thread, other threads that should report an overflow need their own call.
    setStackGuarantee();

    app.init();

    // Be wary of changing this loop from the default. It isn't the only code that pumps this
    // thread's messages: a modal loop deep in the call graph takes over dispatching, such as
    // MessageBox or the loop Windows runs while the user drags or resizes a window. Anything
    // added here (filtering, accelerators, idle work, crash handling) is skipped while one of
    // those runs, so handle it in the window procedure instead.
    while (true) {
        var msg: win32.MSG = undefined;
        const result = win32.GetMessageW(&msg, null, 0, 0);
        if (result <= 0) {
            @branchHint(.unlikely);
            if (result < 0) win32.panicWin32("GetMessage", win32.GetLastError());
            break; // result == 0 means WM_QUIT
        }
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

/// Creates <app.name>.log next to the exe.
fn createLogFile(exe_path: std.os.windows.UNICODE_STRING) std.os.windows.HANDLE {
    const exe = exe_path.Buffer.?[0 .. exe_path.Length / 2];
    const dir = exe[0 .. std.mem.lastIndexOfScalar(u16, exe, '\\') orelse 0];
    const name = win32.L("\\" ++ app.name ++ ".log");
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
    if (handle == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFile(" ++ app.name ++ ".log)", win32.GetLastError());
    return handle;
}

fn setStackGuarantee() void {
    var size: u32 = stack_guarantee;
    if (0 == win32.SetThreadStackGuarantee(&size)) win32.panicWin32("SetThreadStackGuarantee", win32.GetLastError());
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

    if (!global.reporting_exception) {
        global.reporting_exception = true;
        var buf: [256]u8 = undefined;
        // The lock is recursive, so a panic in the code below can still take it.
        const stderr = if (zig_0_17) std.debug.lockStderr(&buf).terminal() else std.debug.lockStderrWriter(&buf);
        defer if (zig_0_17) std.debug.unlockStderr() else std.debug.unlockStderrWriter();
        writeReport(stderr, info) catch {};
    }
    msgbox("unhandled exception 0x{X:0>8} at 0x{x}", .{ code, address });
    return execute_handler;
}

const Terminal = if (zig_0_17) std.Io.Terminal else *std.Io.Writer;

/// Writes the exception's code, address and module, then the stack trace from where it happened.
fn writeReport(t: Terminal, info: *win32.EXCEPTION_POINTERS) error{WriteFailed}!void {
    const w = if (zig_0_17) t.writer else t;
    const record = info.ExceptionRecord.?;
    const address = @intFromPtr(record.ExceptionAddress);
    try w.print("unhandled exception 0x{X:0>8} at 0x{x}", .{ @intFromEnum(record.ExceptionCode), address });
    // Flushed before anything that could fault again, so the code and address get out.
    try w.flush();
    try writeModule(w, address);
    try w.writeAll("\n");
    try w.flush();
    const context: *std.os.windows.CONTEXT = @ptrCast(@alignCast(info.ContextRecord.?));
    if (zig_0_17) {
        const native = std.debug.cpu_context.fromWindowsContext(context);
        try std.debug.writeCurrentStackTrace(.{ .context = &native }, t);
    } else std.debug.dumpStackTraceFromBase(context, w);
    try w.flush();
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
    _ = win32.MessageBoxA(null, buf[0..len :0], app.name ++ " crash", .{ .ICONHAND = 1 });
}

test "stack_guarantee leaves room to report a stack overflow" {
    const overflow = struct {
        var report_buf: [1024 * 1024]u8 = undefined;
        var report: std.Io.Writer = .fixed(&report_buf);
        var result: error{WriteFailed}!void = undefined;

        fn thread(_: ?*anyopaque) callconv(.winapi) u32 {
            setStackGuarantee();
            std.mem.doNotOptimizeAway(recurse(0));
            return 1;
        }
        /// Runs on the overflowed stack like the unhandled exception filter, then ends the
        /// thread since it can't continue.
        fn handler(info: ?*win32.EXCEPTION_POINTERS) callconv(.winapi) i32 {
            if (info.?.ExceptionRecord.?.ExceptionCode != win32.EXCEPTION_STACK_OVERFLOW) return 0;
            const t: Terminal = if (zig_0_17) .{ .writer = &report, .mode = .no_color } else &report;
            result = writeReport(t, info.?);
            win32.ExitThread(0);
        }
        noinline fn recurse(depth: usize) usize {
            var buf: [4096]u8 = undefined;
            buf[depth % buf.len] = @truncate(depth);
            std.mem.doNotOptimizeAway(&buf);
            return recurse(depth + 1) + buf[depth % buf.len];
        }
    };
    const handler = win32.AddVectoredExceptionHandler(1, overflow.handler) orelse
        win32.panicWin32("AddVectoredExceptionHandler", win32.GetLastError());
    defer _ = win32.RemoveVectoredExceptionHandler(handler);
    // A small stack, so the trace through recurse fits in the report buffer.
    const thread = win32.CreateThread(null, stack_guarantee + 1024 * 1024, overflow.thread, null, win32.STACK_SIZE_PARAM_IS_A_RESERVATION, null) orelse
        win32.panicWin32("CreateThread", win32.GetLastError());
    defer _ = win32.CloseHandle(thread);
    // If the report doesn't fit in stack_guarantee, the second overflow ends the test process.
    if (win32.WaitForSingleObject(thread, win32.INFINITE) != .NO_ERROR) win32.panicWin32("WaitForSingleObject", win32.GetLastError());
    try overflow.result;
    try std.testing.expect(std.mem.indexOf(u8, overflow.report.buffered(), " in recurse ") != null);
}

/// Builds with Zig 0.15.2 and 0.17.0; keep the branches for your version.
const zig_0_17 = builtin.zig_version.order(.{ .major = 0, .minor = 17, .patch = 0 }) != .lt;

const app = @import("app.zig");
const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
