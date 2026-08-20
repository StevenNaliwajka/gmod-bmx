#!/usr/bin/env python3
"""Pack this addon into a .gma without needing a Garry's Mod install.

WHY NOT JUST USE gmad. The real `gmad_linux` binary ships inside the Garry's Mod
Dedicated Server depot, so using it in CI means a ~2 GB SteamCMD download on
every release build to run a program that writes a header and concatenates some
files. The GMA container format is small, stable and published, so it is
cheaper to write it out directly.

FORMAT (version 3), all little-endian:

    char[4]   "GMAD"
    uint8     format version (3)
    uint64    steamid    (unused by the loader, written 0)
    uint64    unix timestamp
    cstring   required-content entries, terminated by an empty string
    cstring   addon title
    cstring   addon description   -- a JSON blob, see below
    cstring   addon author
    int32     addon version       (unused by the loader, written 1)

    repeated file index entries, in order:
        uint32    1-based file number
        cstring   path, lowercased, forward slashes
        int64     size in bytes
        uint32    CRC32 of the file's contents
    uint32    0                   -- ends the index

    every file's contents, concatenated, in index order
    uint32    CRC32 of everything written above

The "description" field is a JSON object carrying the real description plus the
addon type and tags, which is how modern gmad stores addon.json.

VERIFY BEFORE YOUR FIRST WORKSHOP PUBLISH. This implements the published format
and produces a file the loader accepts, but a mount failure on a real server is
a much more expensive way to find a byte-order mistake than:

    gmad_linux extract -file bmx.gma -out /tmp/check

Usage:
    tools/gmad.py [-o bmx.gma] [--root .]
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import struct
import sys
import time
import zlib

# Garry's Mod refuses to mount a file whose extension is not on this list, so
# packing one is not a harmless extra: it makes the whole addon fail to load.
# Taken from gmad's own whitelist, trimmed to what a Lua addon can legally ship.
WHITELIST = [
    "lua/*.lua",
    "scenes/*.vcd",
    "particles/*.pcf",
    "resource/fonts/*.ttf",
    "scripts/vehicles/*.txt",
    "resource/localization/*/*.properties",
    "maps/*.bsp", "maps/*.nav", "maps/*.ain",
    "maps/thumb/*.png",
    "sound/*.wav", "sound/*.mp3", "sound/*.ogg",
    "materials/*.vmt", "materials/*.vtf", "materials/*.png",
    "materials/*.jpg", "materials/*.jpeg",
    "models/*.mdl", "models/*.vtx", "models/*.phy", "models/*.ani",
    "models/*.vvd",
    "gamemodes/*/*.txt", "gamemodes/*/*/*.lua",
    "data_static/*.txt", "data_static/*.dat",
]


def allowed(path: str) -> bool:
    return any(fnmatch.fnmatch(path, pat) for pat in WHITELIST)


def cstring(s: str) -> bytes:
    return s.encode("utf-8") + b"\0"


def collect(root: str, ignore: list[str]) -> list[str]:
    """Every packable file, as lowercase forward-slash paths relative to root."""
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", ".github")]
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/").lower()

            if any(fnmatch.fnmatch(rel, pat.lower()) for pat in ignore):
                continue
            if not allowed(rel):
                continue
            out.append(rel)

    # Sorted so the same tree always produces byte-identical output. A
    # reproducible build is worth the one line it costs.
    return sorted(out)


def build(root: str, out_path: str) -> None:
    meta_path = os.path.join(root, "addon.json")
    if not os.path.isfile(meta_path):
        sys.exit("no addon.json at " + root)

    with open(meta_path, "r", encoding="utf-8") as fh:
        meta = json.load(fh)

    title = meta.get("title", "addon")
    ignore = meta.get("ignore", [])

    files = collect(root, ignore)
    if not files:
        sys.exit("nothing to pack: no whitelisted files found under " + root)

    description = json.dumps({
        "description": meta.get("description", title),
        "type":        meta.get("type", "entity"),
        "tags":        meta.get("tags", []),
    })

    buf = bytearray()
    buf += b"GMAD"
    buf += struct.pack("<B", 3)
    buf += struct.pack("<q", 0)                     # steamid, unused
    buf += struct.pack("<q", int(time.time()))
    buf += b"\0"                                    # no required content
    buf += cstring(title)
    buf += cstring(description)
    buf += cstring(meta.get("author", "unknown"))
    buf += struct.pack("<i", 1)                     # addon version, unused

    blobs = []
    for i, rel in enumerate(files, start=1):
        with open(os.path.join(root, rel), "rb") as fh:
            data = fh.read()
        blobs.append(data)

        buf += struct.pack("<I", i)
        buf += cstring(rel)
        buf += struct.pack("<q", len(data))
        buf += struct.pack("<I", zlib.crc32(data) & 0xFFFFFFFF)

    buf += struct.pack("<I", 0)                     # end of index
    for data in blobs:
        buf += data
    buf += struct.pack("<I", zlib.crc32(bytes(buf)) & 0xFFFFFFFF)

    with open(out_path, "wb") as fh:
        fh.write(buf)

    total = sum(len(b) for b in blobs)
    print(f"{out_path}: {len(files)} files, {total} bytes of content, "
          f"{len(buf)} bytes total")
    for rel in files:
        print("   ", rel)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--out", default="bmx.gma")
    ap.add_argument("--root", default=os.path.join(os.path.dirname(__file__), ".."))
    args = ap.parse_args()
    build(os.path.abspath(args.root), args.out)


if __name__ == "__main__":
    main()
