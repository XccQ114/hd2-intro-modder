# SPDX-License-Identifier: CC-BY-NC-4.0
"""Unit tests for src/make-final-patch2.py - the packaging core.

The real base container and notice video are multi-megabyte game files, so these tests
build tiny synthetic stand-ins. That is legitimate here precisely because the packager
never *parses* the container: it copies the base blob, pokes u32 values at ten fixed
offsets, and concatenates three blobs with 16-byte alignment. Those two behaviours
(alignment/offsets, and the field writes) are what is asserted below.

The module is loaded by path because its filename contains dashes, so a normal
`import` statement cannot reach it. The `if __name__ == '__main__'` guard in the
module keeps main() from running at import time.
"""
import importlib.util
import os
import struct
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MODULE_PATH = os.path.join(ROOT, 'src', 'make-final-patch2.py')

_spec = importlib.util.spec_from_file_location('make_final_patch2', MODULE_PATH)
mfp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mfp)


# --------------------------------------------------------------------- helpers
BASE_SIZE = 0x0310      # covers the highest offset written (0x0308 + 4 bytes)
WEM_LEN = 1000
V1_LEN = 500
V2_LEN = 700


def make_wem(n=WEM_LEN):
    return b'RIFF' + struct.pack('<I', n - 8) + b'WAVE' + b'\x00' * (n - 12)


def make_bk2(n, fill):
    return b'KB2n' + bytes([fill]) * (n - 4)


@pytest.fixture
def paths(tmp_path):
    """Synthetic base / notice / video / wem plus an (initially absent) output dir."""
    base = tmp_path / 'base.patch_0'
    base.write_bytes(bytes(BASE_SIZE))
    notice = tmp_path / 'notice.stream'
    notice.write_bytes(make_bk2(V1_LEN, 0x0A))
    video = tmp_path / 'video.bk2'
    video.write_bytes(make_bk2(V2_LEN, 0x0B))
    wem = tmp_path / 'audio.wem'
    wem.write_bytes(make_wem())
    return {
        'base': str(base),
        'v1': str(notice),
        'v2': str(video),
        'wem': str(wem),
        'out': str(tmp_path / 'out'),
    }


def build_argv(paths, extra=None, with_wem=True):
    argv = ['make-final-patch2.py']
    if with_wem:
        argv += ['--wem', paths['wem']]
    argv += ['--v2', paths['v2'], '--v1', paths['v1'], '--base', paths['base'], '--out', paths['out']]
    if extra:
        argv += extra
    return argv


def run_ok(monkeypatch, paths, extra=None, with_wem=True):
    """Run main() in-process so coverage.py can observe it."""
    monkeypatch.setattr(sys, 'argv', build_argv(paths, extra, with_wem))
    mfp.main()


def run_exit(monkeypatch, paths, extra=None, with_wem=True):
    """Run main() expecting SystemExit; returns its exit code."""
    monkeypatch.setattr(sys, 'argv', build_argv(paths, extra, with_wem))
    with pytest.raises(SystemExit) as excinfo:
        mfp.main()
    return excinfo.value.code


# --------------------------------------------------------------------- pad16
@pytest.mark.parametrize('n,expected', [
    (0, 0), (1, 16), (15, 16), (16, 16), (17, 32), (31, 32), (32, 32), (1000, 1008),
])
def test_pad16_rounds_up_to_a_multiple_of_16(n, expected):
    assert mfp.pad16(n) == expected


# --------------------------------------------------------------------- happy path
def test_stream_is_wem_then_notice_then_video(monkeypatch, paths):
    run_ok(monkeypatch, paths)
    with open(os.path.join(paths['out'], '9ba626afa44a3aa3.patch_0.stream'), 'rb') as f:
        stream = f.read()

    v1_off = mfp.pad16(WEM_LEN)             # 1008
    v2_off = mfp.pad16(v1_off + V1_LEN)     # pad16(1508) = 1520

    assert stream[0:4] == b'RIFF'
    assert stream[v1_off:v1_off + 4] == b'KB2n'
    assert stream[v2_off:v2_off + 4] == b'KB2n'
    assert len(stream) == v2_off + V2_LEN
    # the gaps between segments must be zero padding, not stray data
    assert stream[WEM_LEN:v1_off] == b'\x00' * (v1_off - WEM_LEN)
    assert stream[v1_off + V1_LEN:v2_off] == b'\x00' * (v2_off - v1_off - V1_LEN)


def test_all_ten_container_fields_are_rewritten(monkeypatch, paths):
    run_ok(monkeypatch, paths)
    with open(os.path.join(paths['out'], '9ba626afa44a3aa3.patch_0'), 'rb') as f:
        patch = f.read()

    def u32(off):
        return struct.unpack_from('<I', patch, off)[0]

    v1_off = mfp.pad16(WEM_LEN)
    v2_off = mfp.pad16(v1_off + V1_LEN)

    assert u32(0x0104) == WEM_LEN, 'WAV size'
    assert u32(0x0308) == WEM_LEN, 'WAV size (copy)'
    for off in (0x0130, 0x0180, 0x01D0, 0x0220, 0x0270):
        assert u32(off) == v1_off, 'video1 offset ref at 0x%04X' % off
    assert u32(0x0294) == V1_LEN, 'video1 size'
    assert u32(0x02C0) == v2_off, 'video2 offset'
    assert u32(0x02E4) == V2_LEN, 'video2 size'


def test_container_length_is_preserved(monkeypatch, paths):
    run_ok(monkeypatch, paths)
    with open(os.path.join(paths['out'], '9ba626afa44a3aa3.patch_0'), 'rb') as f:
        patch = f.read()
    assert len(patch) == BASE_SIZE, 'only field values change, never the container length'


def test_num_option_selects_the_output_filenames(monkeypatch, paths):
    run_ok(monkeypatch, paths, ['--num', '3'])
    assert os.path.exists(os.path.join(paths['out'], '9ba626afa44a3aa3.patch_3'))
    assert os.path.exists(os.path.join(paths['out'], '9ba626afa44a3aa3.patch_3.stream'))


def test_output_directory_is_created_when_missing(monkeypatch, paths):
    assert not os.path.isdir(paths['out'])
    run_ok(monkeypatch, paths)
    assert os.path.isdir(paths['out'])


# --------------------------------------------------------------------- error paths
def test_omitting_wem_exits_1(monkeypatch, paths, capsys):
    assert run_exit(monkeypatch, paths, with_wem=False) == 1
    assert 'no wem audio provided' in capsys.readouterr().out


def test_missing_wem_file_exits_1(monkeypatch, paths):
    paths['wem'] = os.path.join(paths['out'], 'nope.wem')
    assert run_exit(monkeypatch, paths) == 1


def test_missing_video_exits_1(monkeypatch, paths, capsys):
    paths['v2'] = os.path.join(paths['out'], 'nope.bk2')
    assert run_exit(monkeypatch, paths) == 1
    assert 'v2 not found' in capsys.readouterr().out


def test_missing_notice_video_exits_1(monkeypatch, paths, capsys):
    paths['v1'] = os.path.join(paths['out'], 'nope.stream')
    assert run_exit(monkeypatch, paths) == 1
    assert 'vanilla notice' in capsys.readouterr().out


def test_missing_base_container_exits_1(monkeypatch, paths, capsys):
    paths['base'] = os.path.join(paths['out'], 'nope.patch')
    assert run_exit(monkeypatch, paths) == 1
    assert 'base container not found' in capsys.readouterr().out


def test_non_riff_wem_is_rejected(monkeypatch, paths):
    with open(paths['wem'], 'wb') as f:
        f.write(b'OggS' + b'\x00' * 100)
    with pytest.raises(AssertionError):
        run_ok(monkeypatch, paths)


def test_non_bink_video_is_rejected(monkeypatch, paths):
    with open(paths['v2'], 'wb') as f:
        f.write(b'RIFF' + b'\x00' * 100)
    with pytest.raises(AssertionError):
        run_ok(monkeypatch, paths)
