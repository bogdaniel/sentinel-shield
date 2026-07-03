#!/usr/bin/env python3
"""Regenerate the malicious archive fixtures for tests/prod/241.

Usage: python3 generate.py <output-dir>

These fixtures are intentionally unsafe ZIP archives, each isolating one attack, so
scripts/lib/archive-safety.sh can be proven to reject them. See README.md.
"""
import os
import stat
import sys
import zipfile


def symlink(z, name, target):
    zi = zipfile.ZipInfo(name)
    zi.external_attr = (stat.S_IFLNK | 0o777) << 16
    zi.create_system = 3
    z.writestr(zi, target)


def main(d):
    with zipfile.ZipFile(f"{d}/traversal.zip", "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("reports/good.txt", "ok\n")
        z.writestr("../escape.txt", "pwned\n")
    with zipfile.ZipFile(f"{d}/absolute.zip", "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("reports/good.txt", "ok\n")
        z.writestr("/tmp/abs.txt", "pwned\n")
    with zipfile.ZipFile(f"{d}/symlink-escape.zip", "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("reports/good.txt", "ok\n")
        symlink(z, "reports/link", "../../../../etc/passwd")
    with zipfile.ZipFile(f"{d}/duplicate-path.zip", "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("reports/dup.txt", "first\n")
        z.writestr("reports/dup.txt", "second\n")
    with zipfile.ZipFile(f"{d}/oversize.zip", "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("reports/big.bin", "\0" * 1048576)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    main(out)
