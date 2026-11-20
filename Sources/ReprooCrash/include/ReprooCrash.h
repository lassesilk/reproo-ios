#ifndef REPROO_CRASH_H
#define REPROO_CRASH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Crash handlers of the reproo iOS SDK. Everything that runs inside a signal handler lives here:
/// it is async-signal-safe (no locks, no malloc, no Objective-C/Swift), writes a small line-based
/// record to a file opened at install time and then hands the signal on to the previous handler
/// (other crash reporters, the OS), so their reports keep working. The header lines are on disk
/// before the stack is walked, so a record cut short still counts as a crash; a second thread that
/// crashes meanwhile waits (bounded) until the first one has written the record.
///
/// Record format (one "key value" per line, read back by the Swift side on the next launch; the first
/// line keeps the SDK's former name – an on-device format, like the storage folder ai.uatai):
///   uatai-crash 1
///   type signal | exception
///   signal 5                         (signal number; signal crashes only)
///   exception_name NSRangeException  (exception crashes only)
///   reason …                         (exception reason; control characters become spaces)
///   time 1761742800123               (milliseconds since 1970)
///   foreground 1
///   message …                        (Swift runtime crash message, e.g. "…swift:24: Fatal error: …")
///   message2 …
///   pc 0x1045f3a2c                   (the crashing instruction; signal crashes only)
///   lr 0x1045f3a10                   (arm64 link register: the caller when a leaf function crashed)
///   frame 0x1045f3a00                (return addresses of the crashed thread, innermost first)
///   end

/// Opens (and truncates) the record file the handlers write to. Returns 0 on success.
int reproo_crash_open_record(const char *path);

/// Installs chained SA_SIGINFO|SA_ONSTACK handlers for SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE,
/// SIGTRAP and SIGSYS, an alternate signal stack for the calling thread (stack overflows) and
/// locates the Swift runtime's crash message. Idempotent. Returns 0 on success.
int reproo_crash_install_signal_handlers(void);

/// Gives the calling thread its own alternate signal stack (sigaltstack is per thread), so a stack
/// overflow on it can still be recorded. The SDK calls it on the main thread when configure() runs
/// elsewhere; stack overflows on other threads are not captured. Idempotent. Returns 0 on success.
int reproo_crash_install_alternate_stack(void);

/// 1 while the signal handlers are installed.
int reproo_crash_signal_handlers_installed(void);

/// Restores the previous signal handlers, closes the record and resets the "record written" flag.
void reproo_crash_uninstall(void);

/// Whether the app was in the foreground; written into the record (called from app state notifications).
void reproo_crash_set_foreground(int in_foreground);

/// Records an uncaught Objective-C exception (called from the uncaught exception handler, which is
/// not a signal handler). Afterwards the SIGABRT that follows does not overwrite the record.
/// Returns 0 when the record was written.
int reproo_crash_record_exception(const char *name, const char *reason, const uintptr_t *addresses, int count);

/// 1 once a record has been written completely (a second crashing thread waits for this before it
/// hands its signal on). Reset by reproo_crash_uninstall.
int reproo_crash_record_finished(void);

/// 1 when the Swift runtime's crash annotations (libswiftCore `__crash_info`) were found at install.
int reproo_crash_has_swift_crash_info(void);

/// Writes a signal record for `signal` with the calling thread's stack to `fd` – the writer the
/// handler uses, without a signal (tests). Returns 0 on success.
int reproo_crash_write_signal_record(int fd, int signal);

#ifdef __cplusplus
}
#endif

#endif /* REPROO_CRASH_H */
