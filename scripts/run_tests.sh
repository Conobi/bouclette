#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== deprecated-origin guard ==="
"$SCRIPT_DIR/check_no_deprecated_origins.sh"

source "$SCRIPT_DIR/_arch_sub.sh"
apply_arch_substitution

# Avoid stale-package gotcha: mojo run -I . picks up precompiled packages
# ahead of source. Wipe them so tests always see the current source.
rm -f "$PROJECT_DIR/boucle.mojopkg" "$PROJECT_DIR/boucle.mojoc"

TESTS=(
    tests/boucle/_sys/linux/raw/test_ctypes.mojo
    tests/boucle/_sys/linux/raw/test_net_structs.mojo
    tests/boucle/_sys/linux/raw/test_facade.mojo
    tests/boucle/_sys/linux/raw/test_aarch64_syscall_numbers.mojo
    tests/boucle/_sys/test_triple_helpers.mojo
    tests/boucle/_sys/test_linux_facade.mojo
    tests/boucle/_sys/linux/test_errno.mojo
    tests/boucle/_sys/linux/test_fd.mojo
    tests/boucle/test_ctypes_reexports.mojo
    tests/boucle/test_handle.mojo
    tests/boucle/test_token.mojo
    tests/boucle/test_error.mojo
    tests/boucle/test_buffer.mojo
    tests/boucle/net/test_options.mojo
    tests/boucle/net/test_ip.mojo
    tests/boucle/net/test_ip_parse.mojo
    tests/boucle/net/test_ip_display.mojo
    tests/boucle/net/test_addr.mojo
    tests/boucle/_sys/linux/test_mm.mojo
    tests/boucle/_sys/linux/test_ucontext.mojo
    tests/boucle/_sys/linux/io_uring/test_setup.mojo
    tests/boucle/_sys/linux/io_uring/test_nop.mojo
    tests/boucle/_sys/linux/io_uring/test_ops.mojo
    tests/boucle/_sys/linux/io_uring/test_provide_buffers.mojo
    tests/boucle/_sys/linux/io_uring/test_register_buf_ring.mojo
    tests/boucle/_sys/linux/io_uring/test_multishot_recv.mojo
    tests/boucle/_sys/linux/io_uring/test_multishot_recvmsg.mojo
    tests/boucle/_sys/linux/epoll/test_epoll.mojo
    tests/boucle/_sys/linux/net/test_syscalls.mojo
    tests/boucle/net/test_probe_pure.mojo
    tests/boucle/net/test_probe_state_machine.mojo
    tests/boucle/net/test_socket.mojo
    tests/boucle/net/test_socket_setopt.mojo
    tests/boucle/net/test_socket_connect.mojo
    tests/boucle/net/test_socket_factories.mojo
    tests/boucle/test_completion_reexports.mojo
    tests/boucle/test_completion.mojo
    tests/boucle/test_completion_io.mojo
    tests/boucle/test_completion_connect.mojo
    tests/boucle/test_interest.mojo
    tests/boucle/test_readiness_state.mojo
    tests/boucle/test_readiness.mojo
    tests/boucle/test_stackful.mojo
    tests/boucle/test_stackful_io.mojo
    tests/boucle/test_coroutine_pool.mojo
    tests/boucle/proactor/test_completion.mojo
    tests/boucle/proactor/test_driver_nop.mojo
    tests/boucle/proactor/test_event_loop.mojo
    tests/boucle/proactor/test_driver_timeout.mojo
    tests/boucle/proactor/test_driver_connect.mojo
    tests/boucle/proactor/test_driver_sq_space.mojo
    tests/boucle/net/test_probe_integration.mojo
    tests/boucle/net/test_probe_batch.mojo
    tests/boucle/net/test_probe_cooperative.mojo
    tests/boucle/net/test_probe_property.mojo
    tests/boucle/net/test_probe_exception.mojo
)

# Tests that exercise io_uring (via raw syscalls or CompletionLoop) plus
# epoll-on-pipe behavior that qemu-user-static cannot emulate. Auto-skipped
# when run under qemu-user emulation; set SKIP_IO_URING_TESTS=1 to force-skip
# on hosts where the detection cannot decide for itself.
SKIP_UNDER_QEMU=(
    tests/boucle/_sys/linux/io_uring/test_setup.mojo
    tests/boucle/_sys/linux/io_uring/test_nop.mojo
    tests/boucle/_sys/linux/io_uring/test_ops.mojo
    tests/boucle/_sys/linux/io_uring/test_provide_buffers.mojo
    tests/boucle/_sys/linux/io_uring/test_register_buf_ring.mojo
    tests/boucle/_sys/linux/io_uring/test_multishot_recv.mojo
    tests/boucle/_sys/linux/io_uring/test_multishot_recvmsg.mojo
    tests/boucle/_sys/linux/epoll/test_epoll.mojo
    tests/boucle/test_completion.mojo
    tests/boucle/test_completion_io.mojo
    tests/boucle/test_completion_connect.mojo
    tests/boucle/test_readiness.mojo
    tests/boucle/test_stackful_io.mojo
    tests/boucle/proactor/test_driver_nop.mojo
    tests/boucle/proactor/test_event_loop.mojo
    tests/boucle/proactor/test_driver_timeout.mojo
    tests/boucle/proactor/test_driver_connect.mojo
    tests/boucle/proactor/test_driver_sq_space.mojo
    tests/boucle/net/test_probe_integration.mojo
    tests/boucle/net/test_probe_batch.mojo
    tests/boucle/net/test_probe_cooperative.mojo
    tests/boucle/net/test_probe_property.mojo
    tests/boucle/net/test_probe_exception.mojo
)

# Detect qemu-user emulation on aarch64. Two transports we care about
# leak different signatures into /proc/cpuinfo:
#
#  - uraimo/run-on-arch-action (and similar binfmt_misc setups): the
#    container does not virtualise /proc, so cpuinfo shows the HOST
#    x86_64 CPU verbatim — including a `vendor_id` line, which native
#    aarch64 cpuinfo never has (it exposes `CPU implementer` instead).
#
#  - Docker --platform=linux/arm64 with the qemu binfmt installer
#    image: cpuinfo is rewritten to look aarch64-shaped but with
#    `CPU implementer: 0x00` (no real ARM vendor is assigned that id;
#    e.g. ARM=0x41, Cavium=0x43, Qualcomm=0x51) and a fixed
#    `BogoMIPS: 100.00`. Either alone is impossible on real hardware.
#
# Either signature is sufficient to identify userspace emulation.
QEMU_USER_DETECTED=0
case "$(uname -m)" in
    aarch64|arm64)
        if grep -qE '^vendor_id[[:space:]]*:[[:space:]]*(GenuineIntel|AuthenticAMD|HygonGenuine|CentaurHauls|VIA |GenuineTMx86)' /proc/cpuinfo 2>/dev/null \
           || (grep -qE '^CPU implementer[[:space:]]*:[[:space:]]*0x00[[:space:]]*$' /proc/cpuinfo 2>/dev/null \
               && grep -qE '^BogoMIPS[[:space:]]*:[[:space:]]*100\.00[[:space:]]*$' /proc/cpuinfo 2>/dev/null); then
            QEMU_USER_DETECTED=1
        fi
        ;;
esac
if [ "$QEMU_USER_DETECTED" = "1" ]; then
    echo "Note: running under qemu-user emulation; skipping ${#SKIP_UNDER_QEMU[@]} tests it cannot emulate (io_uring, epoll-on-pipe, etc.)."
fi

# Tests that SIGSEGV through Mojo 1.0.0b1's signal handler on a subset of
# github-hosted Azure ubuntu-24.04 runners. The pool is non-deterministic:
# runs on some VMs land all-green, runs on others reproducibly crash these
# 15 tests through identical signal-handler traces (frames in
# libKGENCompilerRTShared.so → libc.so.6 → JIT code).
#
# The only environmental signal correlated with the crash is `user_shstk`
# in /proc/cpuinfo. It is NOT a CET shadow-stack issue: AT_HWCAP2 on the
# failing runners is 0x2 (HWCAP2_SHSTK bit 29 clear), so glibc cannot be
# activating shadow stack for any process. The cpuinfo flag is therefore
# a proxy for some other VM property (microcode, CPU stepping, kernel
# build variant) we have not yet isolated.
#
# To avoid false-positives on dev machines that happen to expose
# user_shstk (e.g. recent Intel desktops), the skip only triggers when
# GITHUB_ACTIONS=true. Local runs always execute all 43 tests.
HOSTED_CI_INCOMPAT=(
    tests/boucle/net/test_ip_parse.mojo
    tests/boucle/_sys/linux/test_ucontext.mojo
    tests/boucle/_sys/linux/io_uring/test_setup.mojo
    tests/boucle/_sys/linux/io_uring/test_nop.mojo
    tests/boucle/_sys/linux/io_uring/test_ops.mojo
    tests/boucle/_sys/linux/io_uring/test_provide_buffers.mojo
    tests/boucle/_sys/linux/io_uring/test_register_buf_ring.mojo
    tests/boucle/_sys/linux/io_uring/test_multishot_recv.mojo
    tests/boucle/_sys/linux/io_uring/test_multishot_recvmsg.mojo
    tests/boucle/test_completion.mojo
    tests/boucle/test_completion_io.mojo
    tests/boucle/test_completion_connect.mojo
    tests/boucle/test_stackful.mojo
    tests/boucle/test_stackful_io.mojo
    tests/boucle/test_coroutine_pool.mojo
)

# Set BOUCLE_FORCE_HOSTED_CI_INCOMPAT=1 to force-skip locally.
HOSTED_CI_DETECTED=0
if [ "${BOUCLE_FORCE_HOSTED_CI_INCOMPAT:-0}" = "1" ]; then
    HOSTED_CI_DETECTED=1
elif [ "${GITHUB_ACTIONS:-}" = "true" ] && [ "$(uname -m)" = "x86_64" ] && \
     grep -qE '(^|[[:space:]])user_shstk([[:space:]]|$)' /proc/cpuinfo 2>/dev/null; then
    HOSTED_CI_DETECTED=1
fi
if [ "$HOSTED_CI_DETECTED" = "1" ]; then
    echo "Note: github-hosted runner with user_shstk in cpuinfo; skipping ${#HOSTED_CI_INCOMPAT[@]} tests known to SIGSEGV on this VM class."
fi

_in_list() {
    local needle="$1"
    shift
    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

# Sets SKIP_REASON if the test should be skipped, otherwise leaves it empty.
skip_reason_for() {
    SKIP_REASON=""
    if _in_list "$1" "${SKIP_UNDER_QEMU[@]}"; then
        if [ "$QEMU_USER_DETECTED" = "1" ]; then
            SKIP_REASON="QEMU_USER_EMULATION"
            return
        fi
        if [ "${SKIP_IO_URING_TESTS:-0}" = "1" ]; then
            SKIP_REASON="SKIP_IO_URING_TESTS=1"
            return
        fi
    fi
    if [ "$HOSTED_CI_DETECTED" = "1" ] && _in_list "$1" "${HOSTED_CI_INCOMPAT[@]}"; then
        SKIP_REASON="HOSTED_CI_INCOMPAT"
        return
    fi
}

cd "$PROJECT_DIR"

PASS=0
FAIL=0
SKIP=0

for test in "${TESTS[@]}"; do
    skip_reason_for "$test"
    if [ -n "$SKIP_REASON" ]; then
        echo "--- SKIPPED ($SKIP_REASON): $test ---"
        echo ""
        SKIP=$((SKIP + 1))
        continue
    fi
    echo "--- Running: $test ---"
    if uv run mojo run -I . -D ASSERT=all "$test"; then
        echo "--- PASSED: $test ---"
        PASS=$((PASS + 1))
    else
        echo "--- FAILED: $test ---"
        FAIL=$((FAIL + 1))
    fi
    echo ""
done

echo "Results: $PASS passed, $FAIL failed, $SKIP skipped (out of ${#TESTS[@]})"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
