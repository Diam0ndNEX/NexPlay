// NexJIT.h: 6.3.0 built-in JIT, the part that runs inside NexPlay. See NexJIT.c.
#ifndef NEXJIT_H
#define NEXJIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// CS_DEBUGGED is set: a debugger attached to NexPlay at some point in this process.
bool nexjit_cs_debugged(void);

/// Installs the SIGTRAP fallback: a BRK #0xf00d request that no debugger answers returns 0 instead of
/// crashing. Any other trap keeps its normal crash. Safe to call more than once.
void nexjit_install_trap_handler(void);

/// Asks the attached debugger (NexPlay's JIT script) to prepare `size` bytes at `addr` for execution, or,
/// with addr NULL, to allocate them RX. Returns the RX address, or NULL when nothing answered.
void *nexjit_prepare_region(void *addr, size_t size);

/// Tells the attached debugger to detach.
void nexjit_detach(void);

/// Asks the debugger for one 16 KB RX page, maps a writable alias of it, writes `mov x0, #42; ret` and runs it.
/// Returns 42 on success, -1 on failure, -2 when no debugger has attached. `detail` says what happened.
int64_t nexjit_selftest(char *detail, size_t detail_len);

/// Whether the device tree lists TXM: 1 yes, 0 no, -1 unknown.
int nexjit_txm_in_device_tree(void);

#endif
