// Provide __rust_probestack for Wasmer's VM.
// This symbol is normally provided by compiler_builtins but isn't linked
// into cdylib targets automatically when Wasmer references it at runtime.
//
// On x86_64, probestack walks the stack in page-sized increments to trigger
// guard pages. The simplest safe implementation is a no-op (the OS guard
// page will still catch stack overflow, just without per-page probing).

#[cfg(target_arch = "x86_64")]
core::arch::global_asm!(
    ".globl __rust_probestack",
    "__rust_probestack:",
    "ret",
);

#[cfg(not(target_arch = "x86_64"))]
#[unsafe(no_mangle)]
pub extern "C" fn __rust_probestack() {}
