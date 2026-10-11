# SPDX-License-Identifier: CC-BY-NC-4.0
"""extract-vanilla.py - rebuild one Helldivers 2 package out of the game's bundle files.

Derived from `tool_slim_full.py` of the HD2-Mod Dev Kit (author XccQ114,
https://github.com/XccQ114), trimmed to the single job this project needs:
pull one package - plus its `.stream` / `.gpu_resources` siblings - out of
`bundles.*.nxa` and write it into an output folder.

Why this exists
---------------
The vanilla intro "notice" video (`assets\\83cc35d311ee2648.stream`, 10.6 MB) is
*Helldivers 2 game data* and is therefore **not redistributed** with this project.
It is rebuilt from the player's own installation instead, which keeps the published
package free of game assets.

How it works
------------
`bundles.nxa` is a small DSAR archive holding the *index* of every package: which
bundle file each package lives in, at which uncompressed offset, and how large it
is. The individual bundles are chunked; each 0x20-byte chunk header says where the
chunk sits (compressed and uncompressed), how big it is, and whether it is lz4
compressed. Rebuilding a package means walking its entries, reading and
(optionally) decompressing each chunk, and stitching them back together.

Usage
-----
    python tools\\extract-vanilla.py <game data dir> <package name> [<output dir>]

Example
-------
    python tools\\extract-vanilla.py "D:\\steam\\steamapps\\common\\Helldivers 2\\data" 83cc35d311ee2648 assets

Requires the `lz4` module (``pip install lz4``) - only when a chunk is actually
compressed, but the import happens up front, so it is effectively a requirement of
this script.
"""

import os
import struct
import sys

try:
    from lz4 import block as lz4_block
except ImportError:  # pragma: no cover - depends on the user's environment
    lz4_block = None


# chunk header flags
CHUNK_CONTINUE = 0x04
CHUNK_START = 0x02

# compression types
UNCOMPRESSED = 0x00
COMPRESSED = 0x03

CHUNK_HEADER_SIZE = 0x20

# package names we may be asked for, plus their siblings
SIBLING_SUFFIXES = ("", ".stream", ".gpu_resources")


def _read_int(f):
    return int.from_bytes(f.read(4), "little")


def _read_long(f):
    return int.from_bytes(f.read(8), "little")


class BundleIndex:
    """Maps every package name to the bundle file and offset it lives at."""

    def __init__(self, data_dir):
        self.data_dir = data_dir
        # bundle file name -> { uncompressed_offset: chunk_number }
        self.bundle_offsets = {}
        # package name -> list of (bundle_index, uncompressed_start_offset, archive_offset)
        self.packages = {}
        # package name -> total size in bytes
        self.sizes = {}

    # ---------------------------------------------------------------- building
    def build(self):
        index_path = os.path.join(self.data_dir, "bundles.nxa")
        if not os.path.isfile(index_path):
            raise FileNotFoundError(
                "bundles.nxa not found in %s - is that really the Helldivers 2 data folder?"
                % self.data_dir
            )
        contents = self._decompress_dsar(index_path)

        num_bundles = int.from_bytes(contents[0x0C:0x10], "little")
        num_packages = int.from_bytes(contents[0x10:0x14], "little")

        self._index_bundle_chunks()

        for n in range(num_packages):
            loc = 0x18 + n * 0x18
            size = int.from_bytes(contents[loc:loc + 8], "little")
            name_offset = int.from_bytes(contents[loc + 8:loc + 12], "little")
            end = name_offset
            while end < len(contents) and contents[end] != 0:
                end += 1
            name = contents[name_offset:end].decode("utf-8", "replace")

            items_count = int.from_bytes(contents[loc + 12:loc + 16], "little")
            items_offset = int.from_bytes(contents[loc + 16:loc + 20], "little")

            entries = self.packages.setdefault(name, [])
            self.sizes[name] = size
            for i in range(items_count):
                base = items_offset + 0x10 * i
                archive_offset = int.from_bytes(contents[base:base + 8], "little")
                uncompressed_offset = int.from_bytes(contents[base + 8:base + 12], "little")
                bundle_index = contents[base + 0x0F]
                entries.append((bundle_index, uncompressed_offset, archive_offset))
        return self

    def _index_bundle_chunks(self):
        for filename in os.listdir(self.data_dir):
            full = os.path.join(self.data_dir, filename)
            if os.path.isdir(full):
                continue
            if ".patch" in filename:
                continue
            if os.path.splitext(filename)[1] not in ("", ".stream", ".nxa", ".gpu_resources"):
                continue
            try:
                with open(full, "rb") as bundle:
                    bundle.seek(8)
                    num_chunks = _read_int(bundle)
                    bundle.seek(CHUNK_HEADER_SIZE)
                    raw = bundle.read(CHUNK_HEADER_SIZE * num_chunks)
            except OSError:
                continue
            if not num_chunks or len(raw) < CHUNK_HEADER_SIZE * num_chunks:
                self.bundle_offsets[filename] = {}
                continue
            # each chunk header is 32 bytes: u64 uncompressed offset, then 24 bytes of
            # other fields we do not need here - so walk it as "Q then skip 24".
            offsets = struct.unpack("<" + "Q24x" * num_chunks, raw)
            self.bundle_offsets[filename] = {offset: j for j, offset in enumerate(offsets)}

    @staticmethod
    def _decompress_dsar(path):
        with open(path, "rb") as f:
            f.seek(8)
            num_chunks = _read_int(f)
            parts = []
            for i in range(num_chunks):
                f.seek(CHUNK_HEADER_SIZE + i * CHUNK_HEADER_SIZE)
                (_unc_off, comp_off, unc_size, comp_size, comp_type, _chunk_type) = struct.unpack(
                    "<QQIIBB6x", f.read(CHUNK_HEADER_SIZE)
                )
                f.seek(comp_off)
                data = f.read(comp_size)
                if comp_type == COMPRESSED:
                    data = _lz4(data, unc_size)
                parts.append(data)
        return b"".join(parts)

    # ---------------------------------------------------------------- reading
    def _read_resource(self, bundle_path, uncompressed_offset):
        """Read one resource, following it across as many chunks as it spans."""
        with open(bundle_path, "rb") as bundle:
            bundle.seek(8)
            num_chunks = _read_int(bundle)
            mapping = self.bundle_offsets.get(os.path.basename(bundle_path), {})
            chunk_num = mapping.get(uncompressed_offset)
            if chunk_num is None:
                # fall back to the nearest chunk that starts at or before the offset
                candidates = [k for k in mapping if k <= uncompressed_offset]
                if not candidates:
                    return b""
                chunk_num = mapping[max(candidates)]

            parts = []
            while True:
                bundle.seek(CHUNK_HEADER_SIZE + CHUNK_HEADER_SIZE * chunk_num)
                (_unc_off, comp_off, unc_size, comp_size, comp_type, chunk_type) = struct.unpack(
                    "<QQIIBB6x", bundle.read(CHUNK_HEADER_SIZE)
                )
                if (chunk_type & CHUNK_START) and parts:
                    return b"".join(parts)
                bundle.seek(comp_off)
                data = bundle.read(comp_size)
                if comp_type == COMPRESSED:
                    data = _lz4(data, unc_size)
                parts.append(data)
                if chunk_num >= num_chunks - 1:
                    return b"".join(parts)
                chunk_num += 1

    def reconstruct(self, package_name, progress=None):
        """Rebuild a package byte-for-byte as it appears in the game's data folder."""
        name = os.path.basename(package_name)
        entries = self.packages.get(name)
        if not entries:
            return None
        size = self.sizes[name]
        out = bytearray(size)
        for i, (bundle_index, start_offset, archive_offset) in enumerate(entries):
            try:
                item_size = entries[i + 1][2] - archive_offset
            except IndexError:
                item_size = size - archive_offset
            if item_size <= 0:
                continue
            bundle_path = os.path.join(self.data_dir, "bundles.%02d.nxa" % bundle_index)
            collected = bytearray()
            while len(collected) < item_size:
                piece = self._read_resource(bundle_path, start_offset + len(collected))
                if not piece:
                    break
                collected += piece
            out[archive_offset:archive_offset + len(collected)] = collected
            if progress:
                progress(name, i + 1, len(entries))
        return bytes(out)


def _lz4(data, uncompressed_size):
    if lz4_block is None:
        raise RuntimeError(
            "this package is lz4-compressed and the 'lz4' module is missing.\n"
            "Install it with:  python -m pip install lz4"
        )
    return lz4_block.decompress(data, uncompressed_size=uncompressed_size)


def _resolve_python_hint():
    return "python -m pip install lz4"


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[-1])
        print()
        print("Usage: python tools\\extract-vanilla.py <game data dir> <package name> [<output dir>]")
        print("Example:")
        print('  python tools\\extract-vanilla.py "D:\\steam\\steamapps\\common\\Helldivers 2\\data" 83cc35d311ee2648 assets')
        return 2

    data_dir = argv[0]
    package = argv[1]
    out_dir = argv[2] if len(argv) > 2 else "."

    if not os.path.isdir(data_dir):
        print("ERROR: game data folder not found: %s" % data_dir)
        return 1

    try:
        index = BundleIndex(data_dir).build()
    except FileNotFoundError as exc:
        print("ERROR: %s" % exc)
        return 1
    except RuntimeError as exc:
        print("ERROR: %s" % exc)
        return 1

    os.makedirs(out_dir, exist_ok=True)
    written = 0
    for suffix in SIBLING_SUFFIXES:
        name = package + suffix
        if name not in index.packages:
            continue
        try:
            data = index.reconstruct(name)
        except RuntimeError as exc:
            print("ERROR: %s" % exc)
            print("       hint: %s" % _resolve_python_hint())
            return 1
        if not data:
            continue
        target = os.path.join(out_dir, name)
        with open(target, "wb") as f:
            f.write(data)
        print("extracted %-42s %12d bytes" % (name, len(data)))
        written += 1

    if written == 0:
        print("ERROR: package '%s' was not found in the bundles." % package)
        print("       The game may have been updated and renamed it; supply the file manually.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
