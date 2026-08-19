"""TCP port scanner — concurrent connect probes via WatchLoop.

Submits N connect+timeout operations in parallel using
ConnectWithTimeoutFuture, runs them in a single WatchLoop.run()
call, then classifies each result as OPEN/CLOSED/FILTERED.

Build & run:
    uv run mojox build
    uv run -- mojo build -O0 -I .mojox/build/pkg examples/port_scan.mojo -o port_scan
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

    var num_ports = end_port - start_port + 1
    print(
        "Scanning",
        args[1],
        "ports",
        start_port,
        "-",
        end_port,
        "(" + String(timeout_ms) + "ms timeout)...",
    )

    # Create one socket per port and submit all probes.
    var sq_size = UInt32(1)
    while Int(sq_size) < num_ports * 3 + 16:
        sq_size <<= 1
    var loop = WatchLoop(sq_entries=sq_size)

    var sockets = List[Socket]()
    var futures = List[ConnectWithTimeoutFuture]()
    var ports = List[Int]()

    var o = ip.octets
    for p in range(start_port, end_port + 1):
        var sock = Socket.tcp_v4()
        var addr = SocketAddrV4(o[0], o[1], o[2], o[3], port=UInt16(p))
        futures.append(
            loop.connect_with_timeout(sock, addr, timeout_ms)
        )
        ports.append(p)
        sockets.append(sock^)

    loop.run()

    # Classify results.
    var open_count = 0
    var closed_count = 0
    var filtered_count = 0

    for i in range(num_ports):
        var outcome = futures[i].result()
        if outcome.is_connected():
            print("  " + String(ports[i]) + "/tcp\tOPEN")
            open_count += 1
        elif outcome.is_refused():
            closed_count += 1
        elif outcome.is_timeout():
            print("  " + String(ports[i]) + "/tcp\tFILTERED")
            filtered_count += 1
        elif outcome.is_network_unreachable():
            print("  " + String(ports[i]) + "/tcp\tFILTERED (unreachable)")
            filtered_count += 1
        else:
            print(
                "  " + String(ports[i]) + "/tcp\tERROR (" + String(
                    outcome.raw_result()
                ) + ")"
            )
            filtered_count += 1

    print()
    print(
        String(open_count) + " open, " + String(closed_count) + " closed, " + String(
            filtered_count
        ) + " filtered"
    )

    for i in range(num_ports):
        sockets[i].close()
