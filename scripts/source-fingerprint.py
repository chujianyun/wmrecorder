#!/usr/bin/env python3
"""Hash application sources and build configuration, excluding personal settings."""
import hashlib
from pathlib import Path
root = Path(__file__).resolve().parent.parent
paths = sorted(root.glob('Sources/**/*.swift')) + [root / 'Package.swift', root / 'scripts/build.sh', root / 'scripts/source-fingerprint.py']
hash_value = hashlib.sha256()
for path in paths:
    hash_value.update(str(path.relative_to(root)).encode())
    hash_value.update(b'\0')
    hash_value.update(path.read_bytes())
print(hash_value.hexdigest())
