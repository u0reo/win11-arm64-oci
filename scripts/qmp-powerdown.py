#!/usr/bin/env python3
"""Send a graceful ACPI power-down to a QEMU instance over QMP.

Never use a hard reset: it can corrupt the Windows SOFTWARE hive.
"""

import argparse
import json
import socket
import time


def recv_line(sock: socket.socket) -> dict:
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("QMP connection closed")
        buf += chunk
    return json.loads(buf.decode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("socket", help="QMP unix socket path")
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args()

    deadline = time.time() + args.timeout
    while True:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(args.socket)
            break
        except (FileNotFoundError, ConnectionRefusedError):
            if time.time() > deadline:
                raise SystemExit(f"cannot connect to {args.socket}")
            time.sleep(1)

    with sock:
        greeting = recv_line(sock)
        if "QMP" not in greeting:
            raise SystemExit(f"unexpected greeting: {greeting}")
        sock.sendall(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n")
        recv_line(sock)
        sock.sendall(json.dumps({"execute": "system_powerdown"}).encode() + b"\n")
        # The command returns immediately; the VM shuts down asynchronously.
        print("qmp: system_powerdown sent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
