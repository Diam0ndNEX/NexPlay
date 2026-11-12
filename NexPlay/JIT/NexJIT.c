// NexJIT.c: 6.3.0 built-in JIT, the part that runs inside NexPlay.
//
// Adapted from BCD's JITAllocator.c: the BRK #0xf00d calls (StikJIT's universal protocol, x16 = command), the
// SIGTRAP fallback, the debugger-allocated RX page with a vm_remap RW alias ("strategy 2", MeloNX's approach)
// and the device-tree TXM check. Portions copyright 2026 SirDank, from Madeira (https://github.com/willfaust/Madeira,
// pull request #362), GPL-3.0-or-later, modified for BCD. Includes work from BCD by thebcd69
// (https://github.com/thebcd69/bcd-games). The Windows runtime (7.0) brings BCD's full pool allocator.

#include "NexJIT.h"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <libkern/OSCacheControl.h>
#include <signal.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>

#define NEXJIT_PAGE 0x4000
#define NEXJIT_CS_DEBUGGED 0x10000000
#define NEXJIT_BRK_F00D 0xd43e01a0u

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

bool nexjit_cs_debugged(void) {
    uint32_t flags = 0;
    if (csops(getpid(), 0, &flags, sizeof(flags)) != 0) return false;
    return (flags & NEXJIT_CS_DEBUGGED) != 0;
}

// Only the JIT protocol's BRK #0xf00d is skipped (x0 = 0 tells the caller nothing answered). Any other trap
// (a Swift runtime trap is BRK #1) gets the default action back and traps again, so it crashes with a report.
static void nexjit_sigtrap(int sig, siginfo_t *info, void *context) {
    (void)info;
    ucontext_t *uc = (ucontext_t *)context;
    uint64_t pc = uc->uc_mcontext->__ss.__pc;
    if ((pc & 3) || *(const uint32_t *)(uintptr_t)pc != NEXJIT_BRK_F00D) {
        struct sigaction dfl;
        memset(&dfl, 0, sizeof(dfl));
        dfl.sa_handler = SIG_DFL;
        sigaction(sig, &dfl, NULL);
        return;
    }
    uc->uc_mcontext->__ss.__pc += 4;
    uc->uc_mcontext->__ss.__x[0] = 0;
}

void nexjit_install_trap_handler(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_SIGINFO;
    sa.sa_sigaction = nexjit_sigtrap;
    sigaction(SIGTRAP, &sa, NULL);
}

__attribute__((noinline, optnone))
void *nexjit_prepare_region(void *addr, size_t size) {
    register void *x0 __asm__("x0") = addr;
    register size_t x1 __asm__("x1") = size;
    __asm__ volatile(
        "mov x16, #1\n"
        "brk #0xf00d\n"
        : "+r"(x0)
        : "r"(x1)
        : "x16", "memory"
    );
    return x0;
}

__attribute__((noinline, optnone))
void nexjit_detach(void) {
    __asm__ volatile(
        "mov x16, #0\n"
        "brk #0xf00d\n"
        ::: "x16", "memory"
    );
}

int64_t nexjit_selftest(char *detail, size_t detail_len) {
    static const uint32_t code[] = {
        0xD2800540,  // mov x0, #42
        0xD65F03C0,  // ret
    };
    mach_port_t task = mach_task_self();

    if (!nexjit_cs_debugged()) {
        snprintf(detail, detail_len, "CS_DEBUGGED is not set: no debugger has attached");
        return -2;
    }

    void *rx = nexjit_prepare_region(NULL, NEXJIT_PAGE);
    if (!rx) {
        snprintf(detail, detail_len, "the debugger gave no executable page (the JIT script didn't answer)");
        return -1;
    }

    vm_address_t rw = 0;
    vm_prot_t cur = 0, max = 0;
    kern_return_t kr = vm_remap(task, &rw, NEXJIT_PAGE, 0, VM_FLAGS_ANYWHERE, task, (vm_address_t)rx,
                                FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        snprintf(detail, detail_len, "page at %p from the debugger, but vm_remap failed (kr=%d)", rx, kr);
        return -1;
    }
    kr = vm_protect(task, rw, NEXJIT_PAGE, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        snprintf(detail, detail_len, "the writable alias was refused (vm_protect kr=%d, max=0x%x)", kr, max);
        vm_deallocate(task, rw, NEXJIT_PAGE);
        return -1;
    }

    memcpy((void *)rw, code, sizeof(code));
    sys_icache_invalidate(rx, sizeof(code));
    if (memcmp(rx, code, sizeof(code)) != 0) {
        snprintf(detail, detail_len, "the executable page doesn't show what was written to its alias");
        vm_deallocate(task, rw, NEXJIT_PAGE);
        return -1;
    }

    int64_t (*function)(void) = (int64_t (*)(void))rx;
    int64_t result = function();
    vm_deallocate(task, rw, NEXJIT_PAGE);

    if (result == 42) {
        snprintf(detail, detail_len, "a page from the debugger at %p ran through a writable alias and returned 42", rx);
        return 42;
    }
    snprintf(detail, detail_len, "the page at %p returned %lld, not 42", rx, (long long)result);
    return -1;
}

// StikJIT's own test: IODeviceTree:/chosen/memory-map has a key with "TXM" in it.
int nexjit_txm_in_device_tree(void) {
    static const char *const paths[] = {
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
    };
    void *iokit = NULL;
    for (unsigned i = 0; i < sizeof(paths) / sizeof(paths[0]) && !iokit; i++) {
        iokit = dlopen(paths[i], RTLD_LAZY | RTLD_LOCAL);
    }
    if (!iokit) return -1;
    mach_port_t (*from_path)(mach_port_t, const char *) =
        (mach_port_t (*)(mach_port_t, const char *))dlsym(iokit, "IORegistryEntryFromPath");
    CFTypeRef (*property)(mach_port_t, CFStringRef, CFAllocatorRef, uint32_t) =
        (CFTypeRef (*)(mach_port_t, CFStringRef, CFAllocatorRef, uint32_t))dlsym(iokit, "IORegistryEntryCreateCFProperty");
    kern_return_t (*release)(mach_port_t) = (kern_return_t (*)(mach_port_t))dlsym(iokit, "IOObjectRelease");
    if (!from_path || !property || !release) return -1;
    mach_port_t node = from_path(MACH_PORT_NULL, "IODeviceTree:/chosen/memory-map");
    if (node == MACH_PORT_NULL) return -1;
    CFTypeRef keys = property(node, CFSTR("IORegistryEntryPropertyKeys"), kCFAllocatorDefault, 0);
    release(node);
    int found = -1;
    if (keys && CFGetTypeID(keys) == CFArrayGetTypeID()) {
        found = 0;
        for (CFIndex i = 0, n = CFArrayGetCount((CFArrayRef)keys); i < n && !found; i++) {
            CFTypeRef key = CFArrayGetValueAtIndex((CFArrayRef)keys, i);
            if (key && CFGetTypeID(key) == CFStringGetTypeID() &&
                CFStringFind((CFStringRef)key, CFSTR("TXM"), 0).location != kCFNotFound) {
                found = 1;
            }
        }
    }
    if (keys) CFRelease(keys);
    return found;
}
