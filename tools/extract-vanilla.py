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

Layout of the decompressed index (`bundles.nxa`) - see the constants below:
    0x10  u32  number of package records
    0x18  package record (0x18 bytes each): u64 size, u32 name offset,
          u32 item count, u32 item table offset
    item record (0x10 bytes each): u64 archive offset, u32 uncompressed offset,
          and the bundle number in the high byte of the record (offset 0x0F)

Usage
-----
    python tools\\extract-vanilla.py <game data dir> <package name> [<output dir>]

Example
-------
    python tools\\extract-vanilla.py "D:\\steam\\steamapps\\common\\Helldivers 2\\data" 83cc35d311ee2648 assets

Requires nothing beyond the Python standard library: if the optional `lz4` module is
installed it is used for speed, otherwise a built-in pure-Python LZ4 block decoder
takes over.
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

# index layout inside the decompressed `bundles.nxa`
PACKAGE_COUNT_OFFSET = 0x10
PACKAGE_TABLE_OFFSET = 0x18
PACKAGE_RECORD_SIZE = 0x18
ITEM_RECORD_SIZE = 0x10
BUNDLE_INDEX_OFFSET = 0x0F

# file suffixes that may hold bundle chunks
BUNDLE_SUFFIXES = ("", ".stream", ".nxa", ".gpu_resources")


def _read_int(f):
    return int.from_bytes(f.read(4), "little")


def _chunk_count(f):
    """Number of chunks recorded in a bundle or DSAR header."""
    f.seek(8)
    return _read_int(f)


def _read_chunk_header(f, chunk_num):
    """Unpack one 32-byte chunk header: u64 unc_off, u64 comp_off, sizes, then types."""
    f.seek(CHUNK_HEADER_SIZE + CHUNK_HEADER_SIZE * chunk_num)
    (_unc_off, comp_off, unc_size, comp_size, comp_type, chunk_type) = struct.unpack(
        "<QQIIBB6x", f.read(CHUNK_HEADER_SIZE)
    )
    return (comp_off, unc_size, comp_size, comp_type, chunk_type)


def _chunk_payload(f, comp_off, comp_size, comp_type, unc_size):
    f.seek(comp_off)
    data = f.read(comp_size)
    if comp_type == COMPRESSED:
        return _lz4(data, unc_size)
    return data


def _is_run_start(chunk_type, parts):
    """True when this chunk begins a new resource (i.e. the previous one ended)."""
    return bool(chunk_type & CHUNK_START) and bool(parts)


def _read_chunk_run(f, chunk_num, num_chunks):
    """Collect chunks from chunk_num on, stopping at the next resource start."""
    parts = []
    while True:
        (comp_off, unc_size, comp_size, comp_type, chunk_type) = _read_chunk_header(f, chunk_num)
        if _is_run_start(chunk_type, parts):
            return b"".join(parts)
        parts.append(_chunk_payload(f, comp_off, comp_size, comp_type, unc_size))
        if chunk_num >= num_chunks - 1:
            return b"".join(parts)
        chunk_num += 1


def _package_name(contents, loc):
    name_offset = int.from_bytes(contents[loc + 8:loc + 12], "little")
    end = name_offset
    while end < len(contents) and contents[end] != 0:
        end += 1
    return contents[name_offset:end].decode("utf-8", "replace")


def _package_item(contents, items_offset, i):
    base = items_offset + ITEM_RECORD_SIZE * i
    archive_offset = int.from_bytes(contents[base:base + 8], "little")
    uncompressed_offset = int.from_bytes(contents[base + 8:base + 12], "little")
    return (contents[base + BUNDLE_INDEX_OFFSET], uncompressed_offset, archive_offset)


def _is_bundle_candidate(full, filename):
    if os.path.isdir(full):
        return False
    if ".patch" in filename:
        return False
    return os.path.splitext(filename)[1] in BUNDLE_SUFFIXES


def _chunk_offsets(path):
    """{uncompressed chunk offset: chunk number} for one bundle, or None on I/O error."""
    try:
        with open(path, "rb") as bundle:
            num_chunks = _chunk_count(bundle)
            bundle.seek(CHUNK_HEADER_SIZE)
            raw = bundle.read(CHUNK_HEADER_SIZE * num_chunks)
    except OSError:
        return None
    if not num_chunks or len(raw) < CHUNK_HEADER_SIZE * num_chunks:
        return {}
    # each chunk header is 32 bytes: u64 uncompressed offset, then 24 bytes of
    # other fields we do not need here - so walk it as "Q then skip 24".
    offsets = struct.unpack("<" + "Q24x" * num_chunks, raw)
    return {offset: j for j, offset in enumerate(offsets)}


def _item_size(entries, i, size, archive_offset):
    """Size of entry i: the gap to the next entry, or the rest of the package."""
    try:
        return entries[i + 1][2] - archive_offset
    except IndexError:
        return size - archive_offset


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
        contents = self._load_index()
        num_packages = int.from_bytes(
            contents[PACKAGE_COUNT_OFFSET:PACKAGE_COUNT_OFFSET + 4], "little"
        )
        self._index_bundle_chunks()
        for n in range(num_packages):
            self._add_package(contents, n)
        return self

    def _load_index(self):
        index_path = os.path.join(self.data_dir, "bundles.nxa")
        if not os.path.isfile(index_path):
            raise FileNotFoundError(
                "bundles.nxa not found in %s - is that really the Helldivers 2 data folder?"
                % self.data_dir
            )
        return self._decompress_dsar(index_path)

    def _add_package(self, contents, n):
        loc = PACKAGE_TABLE_OFFSET + n * PACKAGE_RECORD_SIZE
        name = _package_name(contents, loc)
        size = int.from_bytes(contents[loc:loc + 8], "little")
        items_count = int.from_bytes(contents[loc + 12:loc + 16], "little")
        items_offset = int.from_bytes(contents[loc + 16:loc + 20], "little")
        entries = self.packages.setdefault(name, [])
        self.sizes[name] = size
        for i in range(items_count):
            entries.append(_package_item(contents, items_offset, i))

    def _index_bundle_chunks(self):
        for filename in os.listdir(self.data_dir):
            full = os.path.join(self.data_dir, filename)
            if not _is_bundle_candidate(full, filename):
                continue
            offsets = _chunk_offsets(full)
            if offsets is not None:
                self.bundle_offsets[filename] = offsets

    @staticmethod
    def _decompress_dsar(path):
        with open(path, "rb") as f:
            num_chunks = _chunk_count(f)
            parts = []
            for i in range(num_chunks):
                (comp_off, unc_size, comp_size, comp_type, _chunk_type) = _read_chunk_header(f, i)
                parts.append(_chunk_payload(f, comp_off, comp_size, comp_type, unc_size))
        return b"".join(parts)

    # ---------------------------------------------------------------- reading
    def _read_resource(self, bundle_path, uncompressed_offset):
        """Read one resource, following it across as many chunks as it spans."""
        with open(bundle_path, "rb") as bundle:
            chunk_num = self._chunk_for(bundle_path, uncompressed_offset)
            if chunk_num is None:
                return b""
            return _read_chunk_run(bundle, chunk_num, _chunk_count(bundle))

    def _chunk_for(self, bundle_path, uncompressed_offset):
        mapping = self.bundle_offsets.get(os.path.basename(bundle_path), {})
        chunk_num = mapping.get(uncompressed_offset)
        if chunk_num is not None:
            return chunk_num
        # fall back to the nearest chunk that starts at or before the offset
        candidates = [k for k in mapping if k <= uncompressed_offset]
        if not candidates:
            return None
        return mapping[max(candidates)]

    def _collect_item(self, bundle_path, start_offset, item_size):
        collected = bytearray()
        while len(collected) < item_size:
            piece = self._read_resource(bundle_path, start_offset + len(collected))
            if not piece:
                break
            collected += piece
        return collected

    def _reconstruct_item(self, out, entries, i, size):
        (bundle_index, start_offset, archive_offset) = entries[i]
        item_size = _item_size(entries, i, size, archive_offset)
        if item_size <= 0:
            return
        bundle_path = os.path.join(self.data_dir, "bundles.%02d.nxa" % bundle_index)
        collected = self._collect_item(bundle_path, start_offset, item_size)
        out[archive_offset:archive_offset + len(collected)] = collected

    def reconstruct(self, package_name, progress=None):
        """Rebuild a package byte-for-byte as it appears in the game's data folder."""
        name = os.path.basename(package_name)
        entries = self.packages.get(name)
        if not entries:
            return None
        size = self.sizes[name]
        out = bytearray(size)
        for i in range(len(entries)):
            self._reconstruct_item(out, entries, i, size)
            if progress:
                progress(name, i + 1, len(entries))
        return bytes(out)


def _lz4(data, uncompressed_size):
    """Decompress one LZ4 block.

    The `lz4` C module is used when it happens to be installed; otherwise a
    pure-Python decoder takes over. That keeps this tool working on a stock
    Python with no extra packages and no network access at all.
    """
    if lz4_block is not None:
        return lz4_block.decompress(data, uncompressed_size=uncompressed_size)
    return _lz4_block_decompress(data, uncompressed_size)


def _read_extended_length(src, i, length):
    """Read one LZ4 length nibble plus its 255-continuation bytes."""
    if length != 15:
        return (length, i)
    while True:
        extra = src[i]
        i += 1
        length += extra
        if extra != 255:
            return (length, i)


def _read_match_offset(src, i):
    offset = src[i] | (src[i + 1] << 8)
    if offset == 0:
        raise ValueError("corrupt lz4 block: zero match offset")
    return (offset, i + 2)


def _copy_match(dst, offset, match_len):
    """Append one LZ4 match copy; its source may overlap the bytes being written."""
    start = len(dst) - offset
    if start < 0:
        raise ValueError("corrupt lz4 block: match offset beyond decoded output")
    if offset >= match_len:
        dst += bytes(dst[start:start + match_len])
        return
    # Overlapping match: the source pattern repeats, so grow an immutable copy.
    # (A bytearray must not be extended from itself - CPython raises
    # "BufferError: Existing exports of data: object cannot be re-sized".)
    piece = bytes(dst[start:])
    while len(piece) < match_len:
        piece = piece + piece
    dst += piece[:match_len]


def _check_decoded_size(dst, uncompressed_size):
    if uncompressed_size is not None and len(dst) != uncompressed_size:
        raise ValueError(
            "lz4 block decoded to %d bytes but %d were expected" % (len(dst), uncompressed_size)
        )


def _lz4_block_decompress(src, uncompressed_size):
    """Pure-Python LZ4 block decoder.

    Block format (https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md):
    a sequence of tokens. Each token is (literal_length << 4) | match_length, and a
    nibble of 15 means "read extra bytes, adding each, until one is < 255". After the
    literals comes a 2-byte little-endian match offset, then a match copy of
    (match_length + 4) bytes. The final sequence carries literals only.

    Matches may overlap their own output (offset < match length), which is how LZ4
    encodes runs - handled by repeating the available bytes.
    """
    dst = bytearray()
    i = 0
    n = len(src)
    while i < n:
        token = src[i]
        i += 1

        (lit_len, i) = _read_extended_length(src, i, token >> 4)
        dst += src[i:i + lit_len]
        i += lit_len

        if i >= n:                      # final sequence holds literals only
            break

        (offset, i) = _read_match_offset(src, i)
        (match_len, i) = _read_extended_length(src, i, token & 0x0F)
        _copy_match(dst, offset, match_len + 4)

    _check_decoded_size(dst, uncompressed_size)
    return bytes(dst)


def _print_usage():
    print(__doc__.strip().splitlines()[-1])
    print()
    print("Usage: python tools\\extract-vanilla.py <game data dir> <package name> [<output dir>]")
    print("Example:")
    print('  python tools\\extract-vanilla.py "D:\\steam\\steamapps\\common\\Helldivers 2\\data" 83cc35d311ee2648 assets')


def _build_index(data_dir):
    try:
        return BundleIndex(data_dir).build()
    except FileNotFoundError as exc:
        print("ERROR: %s" % exc)
        return None
    except RuntimeError as exc:
        print("ERROR: %s" % exc)
        return None


def _prepare(argv):
    """Validate the command line; returns (exit_code, data_dir, package, out_dir).

    exit_code is None when the arguments are usable.
    """
    if len(argv) < 3:
        _print_usage()
        return (2, None, None, None)
    if not os.path.isdir(argv[0]):
        print("ERROR: game data folder not found: %s" % argv[0])
        return (1, None, None, None)
    return (None, argv[0], argv[1], argv[2])


def _report_missing_package(package):
    print("ERROR: package '%s' was not found in the bundles." % package)
    print("       The game may have been updated and renamed it; supply the file manually.")


def _extract_one(index, name, out_dir):
    """Write one package; returns 1 on success, 0 when absent, -1 on rebuild error."""
    if name not in index.packages:
        return 0
    try:
        data = index.reconstruct(name)
    except (ValueError, RuntimeError) as exc:
        print("ERROR: failed to rebuild %s: %s" % (name, exc))
        return -1
    if not data:
        return 0
    target = os.path.join(out_dir, name)
    with open(target, "wb") as f:
        f.write(data)
    print("extracted %-42s %12d bytes" % (name, len(data)))
    return 1


def _extract_siblings(index, package, out_dir):
    """Extract <package> plus its .stream/.gpu_resources siblings; -1 on rebuild error."""
    written = 0
    for suffix in SIBLING_SUFFIXES:
        result = _extract_one(index, package + suffix, out_dir)
        if result < 0:
            return -1
        written += result
    return written


def main(argv):
    (code, data_dir, package, out_dir) = _prepare(argv)
    if code is not None:
        return code
    index = _build_index(data_dir)
    if index is None:
        return 1
    os.makedirs(out_dir, exist_ok=True)
    written = _extract_siblings(index, package, out_dir)
    if written > 0:
        return 0
    if written == 0:
        _report_missing_package(package)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
