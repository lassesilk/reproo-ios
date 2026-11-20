#include "ReprooCrash.h"

#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

// Everything reachable from `handle_signal` must stay async-signal-safe: only write(2), raise,
// sigaction, clock_gettime, nanosleep, vm_read_overwrite (a Mach trap that fails instead of faulting
// on bad addresses), static buffers and lock-free atomics. All lookups (record file, Swift crash
// message) happen at install time.

#define REPROO_SIGNAL_COUNT 7
#define REPROO_MAX_FRAMES 128
#define REPROO_MAX_TEXT 2000

static const int k_signals[REPROO_SIGNAL_COUNT] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGSYS};
static struct sigaction g_previous[REPROO_SIGNAL_COUNT];
static int g_installed = 0;

static volatile int g_record_fd = -1;
/// Set by whoever writes the record first (the exception handler or a signal handler): the
/// SIGABRT that follows an uncaught exception, or a second crashing thread, leaves it alone.
static volatile int g_record_claimed = 0;
/// Set once the claiming writer has written its last byte: a second crashing thread waits for it
/// before handing its signal on (which ends the whole process).
static volatile int g_record_done = 0;
/// The thread writing the record – a fault inside the writer must not wait for itself.
static pthread_t g_record_writer;
static volatile sig_atomic_t g_in_foreground = 1;

/// libswiftCore's `crashreporter_annotations_t` (version, message, signature_string, backtrace,
/// message2, …): the runtime puts "File.swift:24: Fatal error: …" there right before it traps.
static const volatile uint64_t *g_swift_crash_info = NULL;
static unsigned long g_swift_crash_info_size = 0;

static void *g_frames[REPROO_MAX_FRAMES];
/// The Swift runtime message, copied with checked reads (the runtime's pointer is never dereferenced).
static char g_message[REPROO_MAX_TEXT + 1];

// ---- writer (static buffer, write(2) only) -----------------------------------------------

static struct {
    int fd;
    size_t used;
    char buffer[1024];
} g_writer;

static void writer_flush(void) {
    size_t offset = 0;
    while (offset < g_writer.used) {
        ssize_t written = write(g_writer.fd, g_writer.buffer + offset, g_writer.used - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) break;
        offset += (size_t)written;
    }
    g_writer.used = 0;
}

static void writer_begin(int fd) {
    g_writer.fd = fd;
    g_writer.used = 0;
}

static void writer_byte(char byte) {
    if (g_writer.used == sizeof(g_writer.buffer)) writer_flush();
    g_writer.buffer[g_writer.used++] = byte;
}

static void writer_string(const char *text) {
    while (*text) writer_byte(*text++);
}

/// Text value on one line: at most `max` bytes, control characters replaced by spaces.
static void writer_text(const char *text, size_t max) {
    for (size_t index = 0; index < max && text[index]; index++) {
        unsigned char byte = (unsigned char)text[index];
        writer_byte(byte < 0x20 || byte == 0x7f ? ' ' : (char)byte);
    }
}

static void writer_decimal(uint64_t value) {
    char digits[24];
    int count = 0;
    do {
        digits[count++] = (char)('0' + value % 10);
        value /= 10;
    } while (value > 0 && count < (int)sizeof(digits));
    while (count > 0) writer_byte(digits[--count]);
}

static void writer_hex(uint64_t value) {
    static const char k_hex[] = "0123456789abcdef";
    char digits[16];
    int count = 0;
    do {
        digits[count++] = k_hex[value & 0xf];
        value >>= 4;
    } while (value > 0 && count < (int)sizeof(digits));
    writer_string("0x");
    while (count > 0) writer_byte(digits[--count]);
}

static void writer_header(const char *type) {
    // The record's magic line keeps the former name: an on-device format (see ReprooCrash.h).
    writer_string("uatai-crash 1\ntype ");
    writer_string(type);
    writer_string("\ntime ");
    struct timespec now;
    if (clock_gettime(CLOCK_REALTIME, &now) == 0) {
        writer_decimal((uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000);
    } else {
        writer_byte('0');
    }
    writer_string("\nforeground ");
    writer_byte(g_in_foreground ? '1' : '0');
    writer_byte('\n');
}

static int read_memory(uintptr_t address, void *destination, size_t size);

/// Copies a C string with checked reads (never across a page boundary in one read: the next page may
/// be unmapped). Returns its length; the copy is NUL-terminated.
static size_t copy_string(uintptr_t address, char *destination, size_t max) {
    size_t length = 0;
    while (address && length < max) {
        size_t chunk = max - length < 64 ? max - length : 64;
        size_t to_page = 4096 - ((address + length) & 4095);
        if (chunk > to_page) chunk = to_page;
        if (!read_memory(address + length, destination + length, chunk)) break;
        for (size_t index = 0; index < chunk; index++) {
            if (destination[length + index] == 0) return length + index;
        }
        length += chunk;
    }
    destination[length] = 0;
    return length;
}

static void writer_annotation(const char *key, uint64_t pointer) {
    if (!pointer || copy_string((uintptr_t)pointer, g_message, REPROO_MAX_TEXT) == 0) return;
    writer_string(key);
    writer_byte(' ');
    writer_text(g_message, REPROO_MAX_TEXT);
    writer_byte('\n');
}

/// The Swift runtime message, copied (bounded) from libswiftCore's crash annotations.
static void writer_swift_message(void) {
    const volatile uint64_t *info = g_swift_crash_info;
    if (!info) return;
    uint64_t version = info[0];
    if (version == 0) return;
    writer_annotation("message", info[1]);
    if (g_swift_crash_info_size >= 5 * sizeof(uint64_t) && version >= 2) writer_annotation("message2", info[4]);
}

// ---- frames ------------------------------------------------------------------------------

static int read_memory(uintptr_t address, void *destination, size_t size) {
    vm_size_t copied = 0;
    kern_return_t result = vm_read_overwrite(mach_task_self(), (vm_address_t)address, (vm_size_t)size, (vm_address_t)destination, &copied);
    return result == KERN_SUCCESS && copied == size;
}

/// Follows the frame records ({previous fp, return address}) from `fp`. Each read is checked, so a
/// corrupted stack ends the walk instead of crashing the handler.
static int walk_frame_pointers(uintptr_t fp, int count) {
    while (fp && count < REPROO_MAX_FRAMES) {
        uintptr_t record[2];
        if ((fp & (sizeof(uintptr_t) - 1)) != 0 || !read_memory(fp, record, sizeof(record))) break;
        if (record[1] == 0) break;
        g_frames[count++] = (void *)record[1];
        // The stack grows down: the caller's frame record is always at a higher address.
        if (record[0] <= fp) break;
        fp = record[0];
    }
    return count;
}

/// The crashed thread's stack: the interrupted pc and link register, then the return addresses
/// found by walking the frame pointers of the interrupted context. (The handler itself runs on the
/// alternate stack, where backtrace() finds nothing.) Without a context: the calling thread's stack.
static int capture_frames(const ucontext_t *context, uintptr_t *pc, uintptr_t *lr) {
    uintptr_t fp = 0;
    *pc = 0;
    *lr = 0;
    if (!context) return backtrace(g_frames, REPROO_MAX_FRAMES);
    if (context->uc_mcontext) {
#if defined(__arm64__)
        *pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(context->uc_mcontext->__ss);
        *lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(context->uc_mcontext->__ss);
        fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(context->uc_mcontext->__ss);
#elif defined(__x86_64__)
        *pc = (uintptr_t)context->uc_mcontext->__ss.__rip;
        fp = (uintptr_t)context->uc_mcontext->__ss.__rbp;
#endif
    }
    return walk_frame_pointers(fp, 0);
}

static void write_signal_record(int fd, int signal, const ucontext_t *context) {
    uintptr_t pc = 0;
    uintptr_t lr = 0;
    writer_begin(fd);
    writer_header("signal");
    writer_string("signal ");
    writer_decimal((uint64_t)signal);
    writer_byte('\n');
    // On disk before anything that could take long or fault: a record cut short still says "crash".
    writer_flush();
    writer_swift_message();
    writer_flush();
    int count = capture_frames(context, &pc, &lr);
    if (pc) {
        writer_string("pc ");
        writer_hex(pc);
        writer_byte('\n');
    }
    if (lr) {
        writer_string("lr ");
        writer_hex(lr);
        writer_byte('\n');
    }
    for (int index = 0; index < count; index++) {
        writer_string("frame ");
        writer_hex((uint64_t)(uintptr_t)g_frames[index]);
        writer_byte('\n');
    }
    writer_string("end\n");
    writer_flush();
}

// ---- signal handling ---------------------------------------------------------------------

static void restore_previous_handlers(void) {
    for (int index = 0; index < REPROO_SIGNAL_COUNT; index++) sigaction(k_signals[index], &g_previous[index], NULL);
}

static void mark_record_done(void) {
    __atomic_store_n(&g_record_done, 1, __ATOMIC_SEQ_CST);
}

/// Another thread is writing the record: handing this signal on ends the process, so wait (bounded,
/// about 2 s) until it is written. A fault inside the writer itself (same thread) does not wait.
static void wait_for_record(void) {
    if (pthread_equal(pthread_self(), g_record_writer)) return;
    struct timespec step = {0, 10 * 1000 * 1000};
    for (int round = 0; round < 200 && !__atomic_load_n(&g_record_done, __ATOMIC_SEQ_CST); round++) nanosleep(&step, NULL);
}

static void handle_signal(int signal, siginfo_t *info, void *context) {
    (void)info;
    if (!__atomic_exchange_n(&g_record_claimed, 1, __ATOMIC_SEQ_CST)) {
        g_record_writer = pthread_self();
        int fd = g_record_fd;
        if (fd >= 0) write_signal_record(fd, signal, (const ucontext_t *)context);
        mark_record_done();
    } else {
        wait_for_record();
    }
    // Hand the crash on: the previous handler (another crash reporter) or the default action
    // runs as soon as this handler returns, so the OS crash report is produced as usual.
    restore_previous_handlers();
    raise(signal);
}

static int ends_with(const char *text, const char *suffix) {
    size_t text_length = strlen(text);
    size_t suffix_length = strlen(suffix);
    return text_length >= suffix_length && strcmp(text + text_length - suffix_length, suffix) == 0;
}

static void locate_swift_crash_info(void) {
    if (g_swift_crash_info) return;
    static const char *const k_segments[] = {"__DATA", "__DATA_DIRTY"};
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (!name || !ends_with(name, "/libswiftCore.dylib")) continue;
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(index);
        if (!header) continue;
        for (size_t segment = 0; segment < sizeof(k_segments) / sizeof(k_segments[0]); segment++) {
            unsigned long size = 0;
            uint8_t *data = getsectiondata(header, k_segments[segment], "__crash_info", &size);
            if (data && size >= 2 * sizeof(uint64_t)) {
                g_swift_crash_info_size = size;
                g_swift_crash_info = (const volatile uint64_t *)data;
                return;
            }
        }
    }
}

/// Stack overflows exhaust the thread's own stack, so the handler needs one of its own. sigaltstack
/// is per thread: each thread gets its own buffer (kept for the life of the process).
static int install_alternate_stack(void) {
    stack_t current;
    if (sigaltstack(NULL, &current) == 0 && !(current.ss_flags & SS_DISABLE)) return 0;
    void *buffer = malloc(SIGSTKSZ);
    if (!buffer) return -1;
    stack_t stack;
    stack.ss_sp = buffer;
    stack.ss_size = SIGSTKSZ;
    stack.ss_flags = 0;
    if (sigaltstack(&stack, NULL) != 0) {
        free(buffer);
        return -1;
    }
    return 0;
}

int reproo_crash_install_alternate_stack(void) {
    return install_alternate_stack();
}

int reproo_crash_open_record(const char *path) {
    if (!path) return -1;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    int previous = g_record_fd;
    g_record_fd = fd;
    if (previous >= 0) close(previous);
    return 0;
}

int reproo_crash_install_signal_handlers(void) {
    if (g_installed) return 0;
    locate_swift_crash_info();
    // Resolve and fault in everything the handler calls now, not in the handler.
    uintptr_t probe[2];
    read_memory((uintptr_t)probe, probe, sizeof(probe));
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    install_alternate_stack();

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = handle_signal;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    for (int index = 0; index < REPROO_SIGNAL_COUNT; index++) {
        if (sigaction(k_signals[index], &action, &g_previous[index]) != 0) {
            for (int undo = 0; undo < index; undo++) sigaction(k_signals[undo], &g_previous[undo], NULL);
            return -1;
        }
    }
    g_installed = 1;
    return 0;
}

int reproo_crash_signal_handlers_installed(void) {
    return g_installed;
}

void reproo_crash_uninstall(void) {
    if (g_installed) {
        restore_previous_handlers();
        g_installed = 0;
    }
    int fd = g_record_fd;
    g_record_fd = -1;
    if (fd >= 0) close(fd);
    __atomic_store_n(&g_record_done, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_record_claimed, 0, __ATOMIC_SEQ_CST);
}

void reproo_crash_set_foreground(int in_foreground) {
    g_in_foreground = in_foreground ? 1 : 0;
}

int reproo_crash_record_exception(const char *name, const char *reason, const uintptr_t *addresses, int count) {
    int fd = g_record_fd;
    if (fd < 0) return -1;
    if (__atomic_exchange_n(&g_record_claimed, 1, __ATOMIC_SEQ_CST)) return -1;
    g_record_writer = pthread_self();
    writer_begin(fd);
    writer_header("exception");
    if (name && name[0]) {
        writer_string("exception_name ");
        writer_text(name, 200);
        writer_byte('\n');
    }
    if (reason && reason[0]) {
        writer_string("reason ");
        writer_text(reason, REPROO_MAX_TEXT);
        writer_byte('\n');
    }
    writer_swift_message();
    for (int index = 0; addresses && index < count && index < REPROO_MAX_FRAMES; index++) {
        writer_string("frame ");
        writer_hex((uint64_t)addresses[index]);
        writer_byte('\n');
    }
    writer_string("end\n");
    writer_flush();
    mark_record_done();
    return 0;
}

int reproo_crash_record_finished(void) {
    return __atomic_load_n(&g_record_done, __ATOMIC_SEQ_CST);
}

int reproo_crash_has_swift_crash_info(void) {
    locate_swift_crash_info();
    return g_swift_crash_info != NULL;
}

int reproo_crash_write_signal_record(int fd, int signal) {
    if (fd < 0) return -1;
    write_signal_record(fd, signal, NULL);
    return 0;
}
