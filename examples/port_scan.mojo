"""TCP port scanner — concurrent connect probes via WatchLoop.

Scans ports in batches using ConnectWithTimeoutFuture. Each batch
submits up to BATCH_SIZE connect+timeout operations in parallel,
runs them in a single WatchLoop.run() call, then classifies results.
A single WatchLoop is reused across all batches.

Build & run:
    uv run mojox build
    uv run -- mojo build -I .mojox/build/pkg examples/port_scan.mojo -o port_scan
    ./port_scan <ip> <start>-<end> [timeout_ms]

Examples:
    ./port_scan 127.0.0.1 1-100
    ./port_scan 127.0.0.1 20-25 200
    ./port_scan 192.168.1.1 80-443 1000
"""

from boucle.watch import WatchLoop, ConnectWithTimeoutFuture, ConnectOutcome
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4
from boucle.net.ip import IpAddrV4
from std.sys import argv


comptime BATCH_SIZE: Int = 256


def main() raises:
    var args = argv()
    if len(args) < 3:
        print("Usage: port_scan <ip> <start>-<end> [timeout_ms]")
        print("  ip          IPv4 address to scan")
        print("  start-end   Port range (e.g. 1-1024)")
        print("  timeout_ms  Per-port timeout (default 500)")
        return

    var ip_opt = IpAddrV4.parse(args[1])
    if not ip_opt:
        print("Invalid IPv4 address:", args[1])
        return
    var ip = ip_opt.value()

    var range_str = String(args[2])
    var dash = range_str.find("-")
    if dash < 0:
        print("Port range must be start-end (e.g. 1-1024)")
        return
    var start_port = atol(range_str[byte=:dash])
    var end_port = atol(range_str[byte=dash + 1 :])
    if start_port < 1 or end_port > 65535 or start_port > end_port:
        print("Invalid port range:", start_port, "-", end_port)
        return

    var timeout_ms = UInt64(500)
    if len(args) > 3:
        timeout_ms = UInt64(atol(args[3]))

    print(
        "Scanning",
        args[1],
        "ports",
        start_port,
        "-",
        end_port,
        "(" + String(timeout_ms) + "ms timeout)...",
    )

    var open_count = 0
    var closed_count = 0
    var filtered_count = 0
    var o = ip.octets

    var loop = WatchLoop(sq_entries=UInt32(1024))

    var p = start_port
    while p <= end_port:
        var batch_end = p + BATCH_SIZE - 1
        if batch_end > end_port:
            batch_end = end_port
        var batch_size = batch_end - p + 1

        # Submit batch.
        var sockets = List[Socket]()
        var futures = List[ConnectWithTimeoutFuture]()
        for port in range(p, batch_end + 1):
            var sock = Socket.tcp_v4()
            var addr = SocketAddrV4(
                o[0], o[1], o[2], o[3], port=UInt16(port)
            )
            futures.append(
                loop.connect_with_timeout(sock, addr, timeout_ms)
            )
            sockets.append(sock^)

        loop.run()

        # Classify results.
        for i in range(batch_size):
            var port = p + i
            var outcome = futures[i].result()
            if outcome.is_connected():
                print("  " + String(port) + "/tcp\tOPEN")
                open_count += 1
            elif outcome.is_refused():
                closed_count += 1
            elif outcome.is_timeout():
                print("  " + String(port) + "/tcp\tFILTERED")
                filtered_count += 1
            elif outcome.is_network_unreachable():
                print("  " + String(port) + "/tcp\tFILTERED (unreachable)")
                filtered_count += 1
            else:
                print(
                    "  " + String(port) + "/tcp\tERROR ("
                    + String(outcome.raw_result())
                    + ")"
                )
                filtered_count += 1

        # Close sockets before next batch.
        for i in range(batch_size):
            sockets[i].close()

        p = batch_end + 1

    print()
    print(
        String(open_count)
        + " open, "
        + String(closed_count)
        + " closed, "
        + String(filtered_count)
        + " filtered"
    )
