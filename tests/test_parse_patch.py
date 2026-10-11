# SPDX-License-Identifier: CC-BY-NC-4.0
"""Unit tests for src/parse-patch.py - the container inspector used while debugging.

The loader is exercised against containers built here on the fly, so the tests double
as executable documentation of the on-disk layout the tool expects:

    0x00  header          16 bytes of real data, padded out to 72
    0x48  type headers    32 bytes each  (<QQQII)
    0x..  entries         80 bytes each  (<QQQQQQQIIIIII)
"""
import importlib.util
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MODULE_PATH = os.path.join(ROOT, 'src', 'parse-patch.py')

_spec = importlib.util.spec_from_file_location('parse_patch', MODULE_PATH)
pfp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pfp)


HEADER_END = 72
TYPE_HEADER_SIZE = 32
ENTRY_SIZE = 80

BINK_VIDEO = 0x5EE65304478F8DB5


def build_container(num_types=1, num_files=1, magic=0xF0000011):
    """Assemble a minimal but structurally valid patch container."""
    size = HEADER_END + num_types * TYPE_HEADER_SIZE + num_files * ENTRY_SIZE + 64
    data = bytearray(size)
    struct.pack_into('<IIII', data, 0, magic, num_types, num_files, 0)

    off = HEADER_END
    for _ in range(num_types):
        struct.pack_into('<QQQII', data, off, 0, BINK_VIDEO, num_files, 0, 0)
        off += TYPE_HEADER_SIZE

    for i in range(num_files):
        struct.pack_into('<QQQQQQQIIIIII', data, off,
                         i + 1,            # file_id
                         BINK_VIDEO,       # type_id
                         0, 0, 0, 0, 0,    # toc_off / stream_off / gpu_off / u1 / u2
                         16, 0, 0,         # toc_size / stream_size / gpu_size
                         0, 0,             # u3 / u4
                         i)                # idx
        off += ENTRY_SIZE
    return bytes(data)


def test_valid_container_is_parsed(tmp_path, capsys):
    p = tmp_path / '9ba626afa44a3aa3.patch_0'
    p.write_bytes(build_container())

    entries = pfp.parse(str(p))
    out = capsys.readouterr().out

    assert 'magic=0xF0000011' in out
    assert 'num_types=1 num_files=1' in out
    assert 'type header[0]' in out
    assert len(entries) == 1
    assert entries[0][0] == 1, 'file_id written into the entry must come back out'


def test_multiple_types_and_entries(tmp_path, capsys):
    p = tmp_path / 'multi'
    p.write_bytes(build_container(num_types=3, num_files=3))

    entries = pfp.parse(str(p))
    out = capsys.readouterr().out

    assert 'num_types=3 num_files=3' in out
    assert len(entries) == 3
    assert [e[0] for e in entries] == [1, 2, 3]


def test_wrong_magic_is_reported_and_returns_none(tmp_path, capsys):
    p = tmp_path / 'bogus'
    p.write_bytes(build_container(magic=0xDEADBEEF))

    assert pfp.parse(str(p)) is None
    assert 'NOT DSAR/LEGACY container' in capsys.readouterr().out


def test_file_too_small_is_reported(tmp_path, capsys):
    p = tmp_path / 'tiny'
    p.write_bytes(b'\x00' * 10)

    assert pfp.parse(str(p)) is None
    assert 'too small' in capsys.readouterr().out


def test_file_name_is_stripped_from_the_path(tmp_path, capsys):
    p = tmp_path / 'some.patch_0'
    p.write_bytes(build_container())
    pfp.parse(str(p))
    assert '=== some.patch_0 ===' in capsys.readouterr().out


def test_known_type_ids():
    assert pfp.TYPES[0x5EE65304478F8DB5] == 'BINK_VIDEO'
    assert pfp.TYPES[0x504B55235D21440E] == 'WWISE_STREAM'
    assert pfp.TYPES[0x535A7BD3E650D799] == 'WWISE_BANK'
    assert pfp.TYPES[0xAF32095C82F2B070] == 'WWISE_DEP'
    assert pfp.TYPES[0x0D972BAB10B40FD3] == 'TEXT_BANK'
