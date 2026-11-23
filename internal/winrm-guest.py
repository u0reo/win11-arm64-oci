#!/usr/bin/env python3
"""Guest-side readiness and shutdown over WinRM (NTLM).

The host-side HTTP probe on the WinRM port only proves that http.sys accepted
a connection.  OEM firstlogon.ps1 / boot.ps1 keep running for several minutes
after that, and an ACPI powerdown sent during setup is silently ignored by
Windows (docs/BUILD.md).  Poll the OEM completion markers instead, and use
WinRM as a shutdown fallback when the power button request is ignored.

Usage:
    WIN_USERNAME=... WIN_PASSWORD=... winrm-guest.py ready
    WIN_USERNAME=... WIN_PASSWORD=... winrm-guest.py shutdown

Exit codes for `ready`:
    0  SETUP_READY printed, setup finished
    1  markers not present yet (normal while setup is running)
    2  WinRM/auth/timeout error (caller may keep polling)
"""

import argparse
import os
import sys


def make_session(port: int, timeout: int):
    try:
        import winrm
    except ImportError:
        raise SystemExit("python3-winrm is not installed (run scripts/setup.sh)")

    user = os.environ.get("WIN_USERNAME", "")
    password = os.environ.get("WIN_PASSWORD", "")
    if not user or not password:
        raise SystemExit("WIN_USERNAME/WIN_PASSWORD are not set")

    return winrm.Session(
        f"http://127.0.0.1:{port}/wsman",
        auth=(user, password),
        transport="ntlm",
        read_timeout_sec=timeout,
        operation_timeout_sec=max(1, timeout - 5),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("ready", "shutdown"))
    parser.add_argument("--port", type=int,
                        default=int(os.environ.get("WINRM_PORT", "15985")))
    parser.add_argument("--timeout", type=int,
                        default=int(os.environ.get("WINRM_TIMEOUT", "120")))
    args = parser.parse_args()

    session = make_session(args.port, args.timeout)

    if args.action == "shutdown":
        try:
            result = session.run_cmd("shutdown.exe /s /t 0 /f")
            print(f"winrm: shutdown rc={result.status_code}")
        except Exception as exc:
            # The command may have been accepted before the response timed out.
            print(f"winrm: shutdown sent (no response: {type(exc).__name__})")
        return 0

    # boot.ps1 writes done.txt only after both listeners are up; firstlogon.ps1
    # writes firstlogon.done after boot.ps1 (and winre.ps1) have returned.
    check = ('cmd /c "if exist C:\\OEM\\done.txt '
             'if exist C:\\OEM\\firstlogon.done echo SETUP_READY"')
    try:
        result = session.run_cmd(check)
    except Exception as exc:
        print(f"winrm: ready probe failed ({type(exc).__name__}: {exc})",
              file=sys.stderr)
        return 2

    out = (result.std_out or b"").decode("utf-8", "replace")
    err = (result.std_err or b"").decode("utf-8", "replace")
    if "SETUP_READY" in out:
        print("OEM setup complete: done.txt + firstlogon.done")
        return 0
    print("winrm: setup markers not present yet"
          + (f" (stdout={out.strip()!r} stderr={err.strip()!r})"
             if (out.strip() or err.strip()) else ""))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
