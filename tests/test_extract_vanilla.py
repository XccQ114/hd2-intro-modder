# SPDX-License-Identifier: CC-BY-NC-4.0
"""Unit tests for tools/extract-vanilla.py - the vanilla notice rebuilder.

The game's real bundles are gigabytes and are not redistributable, so these tests
build tiny synthetic ones that follow the same on-disk layout the module documents:

    bundles.nxa / bundles.NN.nxa
        0x08  u32 chunk count
        0x20  32-byte chunk headers (<QQIIBB6x): uncompressed offset, compressed
              offset, uncompressed size, compressed size, compression type, flags
        ...   payload at the header's compressed offset

    bundles.nxa, once decompressed
        0x10  u32 package count
        0x18  0x18-byte package record: u64 size, u32 name offset, u32 item count,
              u32 item table offset
        item record (0x10 bytes): u64 archive offset, u32 uncompressed offset, and
              the bundle number in the byte at +0x0F

The LZ4 decoder is exercised with hand-built blocks (literal-only, long literal runs,
overlapping matches) so the tests need no lz4 tooling and cover the pure-Python path
that ships to users.
"""
import importlib.util
import os
import struct

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MODULE_PATH = os.path.join(ROOT, 'tools', 'extract-vanilla.py')

_spec = importlib.util.spec_from_file_location('extract_vanilla', MODULE_PATH)
ev = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ev)


CHUNK = ev.CHUNK_HEADER_SIZE          # 0x20


# --------------------------------------------------------------------- builders
def chunk_header(unc_off, comp_off, unc_size, comp_size,
                 comp_type=ev.UNCOMPRESSED, chunk_type=0):
    return struct.pack('<QQIIBB6x', unc_off, comp_off, unc_size, comp_size,
                       comp_type, chunk_type)


def bundle_head(num_chunks):
    """Bundle/DSAR prefix: chunk count at 0x08, chunk table starts at 0x20."""
    head = b'\x00' * 8 + struct.pack('<I', num_chunks)
    return head + b'\x00' * (CHUNK - len(head))


def dsar(payload, comp_type=ev.UNCOMPRESSED):
    """One-chunk DSAR container holding `payload` (optionally lz4-compressed)."""
    body = payload
    return (bundle_head(1)
            + chunk_header(0, 2 * CHUNK, len(payload), len(body), comp_type)
            + body)


def lz4_literal(data):
    """Minimal LZ4 block encoder: a single literal-only sequence (data < 15 bytes)."""
    return bytes([len(data) << 4]) + data


def bundle(chunks):
    """Bundle file holding [(uncompressed_offset, flags, data), ...], uncompressed."""
    data_off = CHUNK + CHUNK * len(chunks)
    headers, payloads, off = b'', b'', data_off
    for (unc_off, flags, data) in chunks:
        headers += chunk_header(unc_off, off, len(data), len(data), ev.UNCOMPRESSED, flags)
        payloads += data
        off += len(data)
    return bundle_head(len(chunks)) + headers + payloads


def index_multi(packages, bundle_number=0):
    """Decompressed bundles.nxa for [(name, size, [(archive_off, unc_off), ...]), ...]."""
    names = []
    names_len = 0
    total_items = 0
    for (name, _size, items) in packages:
        entry = name.encode('utf-8') + b'\x00'
        names.append(entry)
        names_len += len(entry)
        total_items += len(items)

    name_off = 0x18 + 0x18 * len(packages)
    items_off = name_off + names_len

    buf = bytearray(items_off + 0x10 * total_items)
    struct.pack_into('<II', buf, 0x10, len(packages), 0)

    cur_name, cur_item = name_off, items_off
    for i, (name, size, items) in enumerate(packages):
        struct.pack_into('<QIII', buf, 0x18 + 0x18 * i, size, cur_name, len(items), cur_item)
        buf[cur_name:cur_name + len(names[i])] = names[i]
        cur_name += len(names[i])
        for (archive_offset, uncompressed_offset) in items:
            struct.pack_into('<QI', buf, cur_item, archive_offset, uncompressed_offset)
            buf[cur_item + ev.BUNDLE_INDEX_OFFSET] = bundle_number
            cur_item += 0x10
    return bytes(buf)


def write_game_dir(tmp_path, packages=(('pkg', 16, ((0, 0), (8, 8))),), chunks=None):
    """Lay out `bundles.nxa` + `bundles.00.nxa`; returns the directory."""
    if chunks is None:
        chunks = [(0, ev.CHUNK_START, b'ABCDEFGH'), (8, ev.CHUNK_START, b'IJKLMNOP')]
    (tmp_path / 'bundles.nxa').write_bytes(dsar(index_multi(list(packages))))
    (tmp_path / 'bundles.00.nxa').write_bytes(bundle(chunks))
    return tmp_path


@pytest.fixture
def game(tmp_path):
    return write_game_dir(tmp_path)


# --------------------------------------------------------------------- LZ4 blocks
def test_literal_only_block():
    assert ev._lz4_block_decompress(bytes([0x50]) + b'hello', 5) == b'hello'


def test_long_literal_run_uses_extension_bytes():
    data = b'0123456789abcdefghij'                     # 20 bytes -> nibble 15 + one byte
    assert ev._lz4_block_decompress(bytes([0xF0, 0x05]) + data, 20) == data


def test_non_overlapping_match_is_copied():
    block = bytes([0x40]) + b'abcd' + struct.pack('<H', 4)
    assert ev._lz4_block_decompress(block, 8) == b'abcdabcd'


def test_overlapping_match_repeats_its_pattern():
    block = bytes([0x15]) + b'a' + struct.pack('<H', 1)   # lit 'a', offset 1, 9-byte match
    assert ev._lz4_block_decompress(block, 10) == b'a' * 10


def test_match_length_extension_bytes_are_honoured():
    # token 0x1F: one literal, match nibble 15 -> extra byte 20 -> match 15+20+4 = 39
    block = bytes([0x1F]) + b'a' + struct.pack('<H', 1) + bytes([0x14])
    assert ev._lz4_block_decompress(block, 40) == b'a' * 40


def test_zero_match_offset_is_rejected():
    block = bytes([0x10]) + b'a' + struct.pack('<H', 0)
    with pytest.raises(ValueError, match='zero match offset'):
        ev._lz4_block_decompress(block, None)


def test_match_offset_beyond_output_is_rejected():
    block = bytes([0x10]) + b'a' + struct.pack('<H', 5)
    with pytest.raises(ValueError, match='beyond decoded output'):
        ev._lz4_block_decompress(block, None)


def test_decoded_size_mismatch_is_rejected():
    with pytest.raises(ValueError, match='were expected'):
        ev._lz4_block_decompress(bytes([0x50]) + b'hello', 4)


def test_truncated_match_offset_raises_index_error():
    """Truncated input is a caller error, not a silently short result."""
    with pytest.raises(IndexError):
        ev._lz4_block_decompress(bytes([0x10, 0x41, 0x00]), None)


def test_lz4_uses_pure_python_when_the_c_module_is_absent(monkeypatch):
    monkeypatch.setattr(ev, 'lz4_block', None)
    assert ev._lz4(bytes([0x50]) + b'hello', 5) == b'hello'


def test_lz4_prefers_the_c_module_when_present(monkeypatch):
    calls = []

    class FakeLz4(object):
        def decompress(self, data, uncompressed_size=None):
            calls.append((data, uncompressed_size))
            return b'from-c-module'

    monkeypatch.setattr(ev, 'lz4_block', FakeLz4())
    assert ev._lz4(b'raw', 123) == b'from-c-module'
    assert calls == [(b'raw', 123)]


# --------------------------------------------------------------------- DSAR + scan
def test_decompress_dsar_handles_an_uncompressed_chunk(tmp_path):
    f = tmp_path / 'bundles.nxa'
    f.write_bytes(dsar(b'RAWPAYLOAD'))
    assert ev.BundleIndex._decompress_dsar(str(f)) == b'RAWPAYLOAD'


def test_decompress_dsar_handles_a_compressed_chunk(tmp_path):
    payload = b'ABCDEFGH'
    block = lz4_literal(payload)
    f = tmp_path / 'bundles.nxa'
    f.write_bytes(bundle_head(1)
                  + chunk_header(0, 2 * CHUNK, len(payload), len(block), ev.COMPRESSED)
                  + block)
    assert ev.BundleIndex._decompress_dsar(str(f)) == payload


def test_is_bundle_candidate_filters_non_bundles(tmp_path):
    keep = tmp_path / 'bundles.00.nxa'
    keep.write_bytes(b'\x00')
    assert ev._is_bundle_candidate(str(keep), 'bundles.00.nxa') is True
    assert ev._is_bundle_candidate(str(tmp_path / 'x.txt'), 'x.txt') is False
    assert ev._is_bundle_candidate(str(tmp_path / 'x.patch_0'), 'x.patch_0') is False
    assert ev._is_bundle_candidate(str(tmp_path), 'subdir') is False


def test_chunk_offsets_empty_when_the_table_is_incomplete(tmp_path):
    bad = tmp_path / 'bundles.00.nxa'
    bad.write_bytes(b'\x00' * 8 + struct.pack('<I', 4))      # claims 4 chunks, has none
    assert ev._chunk_offsets(str(bad)) == {}


def test_chunk_offsets_maps_uncompressed_offsets(tmp_path):
    f = tmp_path / 'bundles.00.nxa'
    f.write_bytes(bundle([(0, ev.CHUNK_START, b'aa'), (2, ev.CHUNK_START, b'bb')]))
    assert ev._chunk_offsets(str(f)) == {0: 0, 2: 1}


# --------------------------------------------------------------------- index build
def test_build_reads_the_package_table(game):
    index = ev.BundleIndex(str(game)).build()
    assert index.packages['pkg'] == [(0, 0, 0), (0, 8, 8)]
    assert index.sizes['pkg'] == 16


def test_missing_index_raises_file_not_found(tmp_path):
    with pytest.raises(FileNotFoundError, match='bundles.nxa not found'):
        ev.BundleIndex(str(tmp_path)).build()


def test_reconstruct_stitches_chunks_across_resource_boundaries(game):
    index = ev.BundleIndex(str(game)).build()
    assert index.reconstruct('pkg') == b'ABCDEFGHIJKLMNOP'


def test_reconstruct_accepts_a_path_and_returns_none_when_unknown(game):
    index = ev.BundleIndex(str(game)).build()
    assert index.reconstruct('does-not-exist') is None
    assert index.reconstruct('C:/somewhere/pkg') == b'ABCDEFGHIJKLMNOP'


def test_reconstruct_reports_progress(game):
    seen = []
    index = ev.BundleIndex(str(game)).build()
    index.reconstruct('pkg', progress=lambda name, done, total: seen.append((name, done, total)))
    assert seen == [('pkg', 1, 2), ('pkg', 2, 2)]


def test_reconstruct_falls_back_to_the_nearest_previous_chunk(tmp_path):
    """An offset inside a chunk resolves to that whole chunk, not to nothing."""
    game = write_game_dir(tmp_path, packages=(('pkg', 8, ((0, 1),)),),
                          chunks=[(0, ev.CHUNK_START, b'ABCDEFGH')])
    index = ev.BundleIndex(str(game)).build()
    assert index.reconstruct('pkg') == b'ABCDEFGH'


# --------------------------------------------------------------------- main
def test_main_without_arguments_prints_usage(capsys):
    assert ev.main(['only-one']) == 2
    assert 'Usage: python' in capsys.readouterr().out


def test_main_rejects_a_missing_data_dir(tmp_path):
    assert ev.main([str(tmp_path / 'nope'), 'pkg', str(tmp_path / 'out')]) == 1


def test_main_reports_an_unknown_package(game, tmp_path, capsys):
    out = tmp_path / 'out'
    assert ev.main([str(game), 'not-here', str(out)]) == 1
    assert 'was not found in the bundles' in capsys.readouterr().out


def test_main_extracts_the_package_and_its_siblings(tmp_path, capsys):
    game = write_game_dir(tmp_path, packages=(
        ('pkg', 8, ((0, 0),)),
        ('pkg.stream', 8, ((0, 0),)),
        ('pkg.gpu_resources', 8, ((0, 8),)),
    ))
    out = tmp_path / 'out'
    assert ev.main([str(game), 'pkg', str(out)]) == 0
    assert (out / 'pkg').read_bytes() == b'ABCDEFGH'
    assert (out / 'pkg.stream').read_bytes() == b'ABCDEFGH'
    assert (out / 'pkg.gpu_resources').read_bytes() == b'IJKLMNOP'
    assert 'extracted pkg' in capsys.readouterr().out


def test_extract_one_returns_minus_one_on_rebuild_error(monkeypatch, game, tmp_path):
    index = ev.BundleIndex(str(game)).build()

    def boom(name):
        raise ValueError('corrupt block')

    monkeypatch.setattr(index, 'reconstruct', boom)
    assert ev._extract_one(index, 'pkg', str(tmp_path)) == -1
    assert ev._extract_siblings(index, 'pkg', str(tmp_path)) == -1


def test_extract_one_returns_zero_for_a_missing_package(game, tmp_path):
    index = ev.BundleIndex(str(game)).build()
    assert ev._extract_one(index, 'nope', str(tmp_path)) == 0
