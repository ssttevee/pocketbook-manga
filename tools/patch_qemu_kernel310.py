"""Test-only: make post-3.10 ARM EABI syscalls return ENOSYS in QEMU.

ARM syscall 379 is finit_module (3.8); 380 is sched_setattr (3.14).
Keep ARM private calls (0xf0000+) such as set_tls available. This changes
QEMU's guest dispatch, not the host kernel's syscall results/translation.
"""
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
pattern = r'(static abi_long do_syscall1\([^)]*\)\s*\n\{)'
replacement = r"""\1
    /* PocketManga developer test: no post-Linux-3.10 ARM syscalls. */
    if (num >= 380 && num < 0xf0000 && getenv("QEMU_POCKETMANGA_KERNEL310")) {
        return -TARGET_ENOSYS;
    }
"""
source, count = re.subn(pattern, replacement, source, count=1)
if count != 1: raise RuntimeError('QEMU syscall dispatch changed; review injection')
path.write_text(source)
