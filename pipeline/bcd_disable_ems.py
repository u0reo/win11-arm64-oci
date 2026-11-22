#!/usr/bin/env python3
"""Deprecated alias for bcd_normalize.py.

Older documentation and scripts called this tool ``bcd_disable_ems.py``.
Keep the old name working; all behaviour now lives in bcd_normalize.py.
"""
from __future__ import annotations

import sys

from bcd_normalize import main

if __name__ == "__main__":
    sys.exit(main())
