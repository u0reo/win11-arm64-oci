#!/usr/bin/env python3
"""Render the unattended-install templates.

Values are resolved with this precedence:

    environment variable  >  config/defaults.env  >  built-in default

The defaults are:

    WIN_USERNAME   User
    WIN_PASSWORD   oci-a1
    COMPUTER_NAME  OCI-WIN
    TIMEZONE       Tokyo Standard Time

In GitHub Actions the workflow maps repository secrets/variables to these
environment variables, so `WIN_USERNAME`, `WIN_PASSWORD` and `COMPUTER_NAME`
can be overridden without editing any file.

The rendered autounattend.xml contains the password in clear text.  It is
written with mode 0600 and the output directory is expected to be ignored by
git (see .gitignore).
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import stat
import sys
from pathlib import Path

BUILTIN = {
    "WIN_USERNAME": "User",
    "WIN_PASSWORD": "oci-a1",
    "COMPUTER_NAME": "OCI-WIN",
    "TIMEZONE": "Tokyo Standard Time",
}

USER_RE = re.compile(r"^[A-Za-z0-9._-]{1,20}$")
COMPUTER_RE = re.compile(r"^[A-Za-z0-9-]{1,15}$")


def parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def resolve(repo: Path) -> tuple[dict[str, str], str]:
    file_values = parse_env_file(repo / "config" / "defaults.env")
    resolved: dict[str, str] = {}
    sources: dict[str, str] = {}
    for key, builtin in BUILTIN.items():
        if key in os.environ and os.environ[key] != "":
            resolved[key] = os.environ[key]
            sources[key] = "env"
        elif key in file_values and file_values[key] != "":
            resolved[key] = file_values[key]
            sources[key] = "config/defaults.env"
        else:
            resolved[key] = builtin
            sources[key] = "builtin"
    source = "env" if any(s == "env" for s in sources.values()) else "defaults"
    return resolved, source


def validate(values: dict[str, str]) -> None:
    errors: list[str] = []
    user = values["WIN_USERNAME"]
    computer = values["COMPUTER_NAME"]
    password = values["WIN_PASSWORD"]

    if not USER_RE.match(user):
        errors.append(
            "WIN_USERNAME must be 1-20 chars of [A-Za-z0-9._-] "
            f"(got {user!r})"
        )
    if user.endswith("."):
        errors.append("WIN_USERNAME must not end with a dot")
    if not COMPUTER_RE.match(computer):
        errors.append(
            "COMPUTER_NAME must be 1-15 chars of [A-Za-z0-9-] "
            f"(got {computer!r})"
        )
    if computer.startswith("-") or computer.endswith("-"):
        errors.append("COMPUTER_NAME must not start or end with a hyphen")
    if not password:
        errors.append("WIN_PASSWORD must not be empty")
    if len(password) > 256:
        errors.append("WIN_PASSWORD must be at most 256 characters")
    if "\n" in password or "\r" in password:
        errors.append("WIN_PASSWORD must not contain newlines")
    if errors:
        for message in errors:
            print(f"render: error: {message}", file=sys.stderr)
        raise SystemExit(2)


def xml_escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def ps_escape(value: str) -> str:
    # The templates place values inside double-quoted PowerShell strings.
    return (
        value.replace("`", "``")
        .replace("$", "`$")
        .replace('"', '`"')
    )


def render_tree(
    repo: Path,
    out: Path,
    values: dict[str, str],
    image_index: str,
    product_key: str,
) -> list[Path]:
    out.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []

    xml_src = repo / "autounattend" / "autounattend.template.xml"
    xml_text = xml_src.read_text(encoding="utf-8")
    for key in ("WIN_USERNAME", "WIN_PASSWORD", "COMPUTER_NAME", "TIMEZONE"):
        xml_text = xml_text.replace("{{" + key + "}}", xml_escape(values[key]))
    xml_text = xml_text.replace("{{IMAGE_INDEX}}", xml_escape(image_index))
    if product_key:
        block = (
            "        <ProductKey>\n"
            f"          <Key>{xml_escape(product_key)}</Key>\n"
            "          <WillShowUI>Never</WillShowUI>\n"
            "        </ProductKey>"
        )
        xml_text = xml_text.replace("{{PRODUCT_KEY_BLOCK}}", block)
    else:
        xml_text = xml_text.replace("{{PRODUCT_KEY_BLOCK}}\n", "")
        xml_text = xml_text.replace("{{PRODUCT_KEY_BLOCK}}", "")
    xml_dst = out / "autounattend.xml"
    xml_dst.write_text(xml_text, encoding="utf-8")
    os.chmod(xml_dst, stat.S_IRUSR | stat.S_IWUSR)
    written.append(xml_dst)

    oem_out = out / "oem"
    oem_out.mkdir(parents=True, exist_ok=True)
    for src in sorted((repo / "oem").iterdir()):
        if not src.is_file():
            continue
        if src.name.endswith(".template"):
            text = src.read_text(encoding="utf-8")
            for key in ("WIN_USERNAME", "WIN_PASSWORD"):
                text = text.replace("{{" + key + "}}", ps_escape(values[key]))
            dst = oem_out / src.name[: -len(".template")]
            dst.write_text(text, encoding="utf-8")
            os.chmod(dst, stat.S_IRUSR | stat.S_IWUSR)
            written.append(dst)
        else:
            dst = oem_out / src.name
            shutil.copyfile(src, dst)
            written.append(dst)

    return written


def mask(value: str) -> str:
    if len(value) <= 2:
        return "*" * len(value)
    return value[0] + "*" * (len(value) - 2) + value[-1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        default="build/media",
        help="output directory (default: build/media)",
    )
    parser.add_argument(
        "--repo",
        default=str(Path(__file__).resolve().parent.parent),
        help="repository root (default: parent of scripts/)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="validate and print the resolved values without writing files",
    )
    parser.add_argument(
        "--image-index",
        default=os.environ.get("IMAGE_INDEX", "1"),
        help="WIM image index (default: $IMAGE_INDEX or 1)",
    )
    parser.add_argument(
        "--product-key",
        default=os.environ.get("PRODUCT_KEY", ""),
        help="optional generic product key used only for edition selection",
    )
    args = parser.parse_args()

    if not args.image_index.isdigit() or int(args.image_index) < 1:
        print("render: error: --image-index must be a positive integer", file=sys.stderr)
        return 2

    repo = Path(args.repo).resolve()
    values, _ = resolve(repo)
    validate(values)

    print("render: resolved configuration")
    print(f"  WIN_USERNAME   = {values['WIN_USERNAME']}")
    print(f"  WIN_PASSWORD   = {mask(values['WIN_PASSWORD'])}")
    print(f"  COMPUTER_NAME  = {values['COMPUTER_NAME']}")
    print(f"  TIMEZONE       = {values['TIMEZONE']}")
    print(f"  IMAGE_INDEX    = {args.image_index}")
    print(f"  PRODUCT_KEY    = {'<none>' if not args.product_key else '<set>'}")

    if values["WIN_USERNAME"] == BUILTIN["WIN_USERNAME"] and \
            values["WIN_PASSWORD"] == BUILTIN["WIN_PASSWORD"]:
        print(
            "render: WARNING: using the default credentials "
            "(User / oci-a1). Do not expose RDP/WinRM to the internet.",
            file=sys.stderr,
        )

    if args.check:
        print("render: check ok (no files written)")
        return 0

    out = Path(args.out)
    if not out.is_absolute():
        out = repo / out
    written = render_tree(repo, out, values, args.image_index, args.product_key)
    print(f"render: wrote {len(written)} file(s) to {out}")
    for path in written:
        print(f"  {path.relative_to(repo) if path.is_relative_to(repo) else path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
