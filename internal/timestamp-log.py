#!/usr/bin/env python3
"""Prefix every input line with a UTC timestamp.

Used by build-image.sh so every line of build.log has a wall-clock time.
"""

import sys
from datetime import datetime, timezone


def main() -> None:
    for line in sys.stdin:
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        sys.stdout.write(f"{stamp} {line}")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
