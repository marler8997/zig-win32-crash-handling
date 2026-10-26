# zig-win32-crash-handling

A Zig win32 GUI program that demonstrates how to catch, report and handle every kind of
error/crash. The example logs each one, with a stack trace where one applies, and shows a dialog
box to the user.

`main.zig` is meant to be copied into your project as a starting point. After copying it, go
through it, review and remove the comments as you go, and decide how your application should
handle each case: where it logs, what the user sees, and which cases it needs at all.

`app.zig` is the demo application (the window of crash buttons) and is not meant to be copied.
`main.zig` uses only `app.name` (for the log file and message box title) and `app.init()`
(creates the window; `main.zig` then runs the message loop); replace those with your own
application.

```
zig build run
```

The window has a button for each kind of crash, which crashes from inside the window procedure.
The log is `crashdemo.log` next to the exe, unless the program was started with a stderr of its
own. `zig build run` passes it the terminal's, so to get the log file, start
`zig-out\bin\crashdemo.exe` from Explorer.

## Results

ReleaseSafe, Windows 11, started without a stderr:

| Crash | Reported |
|---|---|
| `@panic`, safety checks | box, `panic: msg` + trace, exit 3 |
| Access violation, illegal instruction, integer divide by zero, `RaiseException` | box, `code at addr (crashdemo.exe+0x4e41)` + trace, exit is the exception code |
| Stack overflow | box, code + trace (std stops at 1024 frames), exit `0xC00000FD` |
| C `abort()` | with the `SIGABRT` handler: box, `panic: abort() was called` + trace through `ucrtbase.dll`, exit 3. Without it: nothing, exit `0xC0000409` |
| `__fastfail` (/GS, heap corruption) | nothing, by design; only Windows Error Reporting sees it |

## Things the code doesn't show

- **Who gets a stderr:** a GUI exe started from Explorer, from cmd or PowerShell *without*
  redirection, or by `CreateProcess` without `STARTF_USESTDHANDLES` has `hStdError == null`. It
  has one only when the launcher redirects (`2> file`, a pipe, bash/msys).
- **The mingw CRT's filter returns `EXCEPTION_CONTINUE_EXECUTION`** for `EXCEPTION_INT_OVERFLOW`
  (`INT_MIN / -1` in C) and a few other codes. On the main thread, mingw's `__try` around `main`
  runs it before any unhandled exception filter, so those re-execute forever; nothing short of a
  vectored exception handler can stop that. On other threads, our filter skips mingw's for them.
- Exceptions raised inside a window procedure reach the filter like any other (older 64-bit
  Windows swallowed exceptions that crossed a kernel callback; Windows 11 doesn't).
- Traces only have function names when the `.pdb` is next to the exe. Without it you get
  addresses to symbolize against the PDB you archived.

## Zig versions

Builds with Zig 0.15.2 and 0.17.0. Where std differs, `main.zig` checks `zig_0_17` inline;
keep the branch for your version.

In 0.17, stack trace support costs about 160 KiB in a ReleaseSafe exe. It's worth it once the
trace reaches a log; without one, `std_options.allow_stack_tracing = false` saves it.
