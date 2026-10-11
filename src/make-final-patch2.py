# SPDX-License-Identifier: CC-BY-NC-4.0
# make-final-patch2.py - package: wem(audio) + video1(notice) + video2(new video) -> patch_N + .stream
#
# Usage (run from anywhere inside the package):
#   python src\make-final-patch2.py --wem <audio.wem> --v2 <video2.bk2>
#        [--v1 <video1.stream>] [--base <base container>] [--out <out dir>] [--num <N>]
#
# Options:
#   --wem   required: Wwise-converted wem audio (replaces WAV region). Stops if missing.
#   --v2    required: new intro video (.bk2, bink2c /V6344, flags=0x40012)
#   --v1    optional: video1 (vanilla notice). Default: assets\83cc35d311ee2648.stream
#   --base  optional: base container. Default: assets\9ba626afa44a3aa3.patch_0 (7-entry)
#   --out   optional: output dir (default: current dir)
#   --num   optional: patch number N, default 0 (writes 9ba626afa44a3aa3.patch_N / .patch_N.stream)
#
# How: use the base container, update the key fields, reassemble the stream as
#      "wem + pad16 + video1 + pad16 + video2".
import struct, os, sys, argparse

# ---- locate package root (this file lives in <package>\src\) ----
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
KIT_ROOT   = os.path.abspath(os.path.join(SCRIPT_DIR, '..'))

# default assets (overridable via --v1/--base)
DEFAULT_V1    = os.path.join(KIT_ROOT, 'assets', '83cc35d311ee2648.stream')
DEFAULT_BASE  = os.path.join(KIT_ROOT, 'assets', '9ba626afa44a3aa3.patch_0')

def pad16(n):
    return (n + 15) & ~15

def main():
    ap = argparse.ArgumentParser(description='HD2 intro media pack packager')
    ap.add_argument('--wem',  default=None, help='Wwise wem audio (replaces WAV region); stops if missing')
    ap.add_argument('--v2',   required=True, help='new intro video .bk2 (bink2c /V6344, flags=0x40012)')
    ap.add_argument('--v1',   default=DEFAULT_V1, help='video1 (vanilla notice)')
    ap.add_argument('--base', default=DEFAULT_BASE, help='base container (7-entry)')
    ap.add_argument('--out',  default='.', help='output dir (default: current dir)')
    ap.add_argument('--num',  type=int, default=0, help='patch number (default 0)')
    args = ap.parse_args()

    if args.wem is None or not os.path.exists(args.wem):
        print('ERROR: no wem audio provided.')
        print('  Provide a valid wem, or build one from the video audio track:')
        print('    1) BinkExtractAudio.exe <video.bk2> <audio.wav>  (extract BINK track to PCM WAV)')
        print('    2) WwiseConsole converts the WAV to wem (Vorbis).')
        sys.exit(1)
    if not os.path.exists(args.v2):    print('ERROR: v2 not found: ' + args.v2);    sys.exit(1)
    if not os.path.exists(args.v1):
        print('ERROR: video1 (vanilla notice) not found: ' + args.v1)
        print('Hint: use --v1 to point at your file.')
        sys.exit(1)
    if not os.path.exists(args.base):
        print('ERROR: base container not found: ' + args.base)
        print('Hint: use --base to point at a 7-entry container.')
        sys.exit(1)

    os.makedirs(args.out, exist_ok=True)
    base_patch = open(args.base, 'rb').read()
    wem = open(args.wem, 'rb').read()
    v1  = open(args.v1, 'rb').read()
    v2  = open(args.v2, 'rb').read()

    assert wem[0:4] == b'RIFF', 'wem must be RIFF (Wwise vorbis)'
    assert v1[0:4] == b'KB2n' and v2[0:4] == b'KB2n', 'video must be BINK2 (KB2n)'

    # layout: WAV(wem) + pad16 + video1 + pad16 + video2
    wav_len = len(wem)
    v1_off = pad16(wav_len)
    v2_off = pad16(v1_off + len(v1))
    new_stream = wem + bytes(v1_off - wav_len) + v1 + bytes(v2_off - (v1_off + len(v1))) + v2

    print('wem(WAV): %d (0x%X)' % (wav_len, wav_len))
    print('video1 offset: 0x%X, size %d' % (v1_off, len(v1)))
    print('video2 offset: 0x%X, size %d' % (v2_off, len(v2)))
    print('stream: %d' % len(new_stream))

    b = bytearray(base_patch)
    def set32(off, val, tag):
        old = struct.unpack_from('<I', b, off)[0]
        struct.pack_into('<I', b, off, val)
        print('  %s 0x%04X: 0x%08X -> 0x%08X' % (tag, off, old, val))
    set32(0x0104, wav_len, 'WAV size')
    set32(0x0308, wav_len, 'WAV size (copy)')
    for off in (0x0130, 0x0180, 0x01D0, 0x0220, 0x0270):
        set32(off, v1_off, 'video1 offset ref')
    set32(0x0294, len(v1), 'video1 size')
    set32(0x02C0, v2_off, 'video2 offset')
    set32(0x02E4, len(v2), 'video2 size')

    out_patch  = os.path.join(args.out, '9ba626afa44a3aa3.patch_%d' % args.num)
    out_stream = out_patch + '.stream'
    open(out_patch,  'wb').write(bytes(b))
    open(out_stream, 'wb').write(new_stream)
    print('WROTE: %s (%d)' % (out_patch,  len(b)))
    print('WROTE: %s (%d)' % (out_stream, len(new_stream)))

    # verify
    s = open(out_stream, 'rb').read()
    assert s[0:4] == b'RIFF'
    assert s[v1_off:v1_off+4] == b'KB2n', 'v1 magic'
    assert s[v2_off:v2_off+4] == b'KB2n', 'v2 magic'
    p = open(out_patch, 'rb').read()
    assert struct.unpack_from('<I', p, 0x02C0)[0] == v2_off
    assert struct.unpack_from('<I', p, 0x02E4)[0] == len(v2)
    assert struct.unpack_from('<I', p, 0x0294)[0] == len(v1)
    assert struct.unpack_from('<I', p, 0x0104)[0] == wav_len
    print('OK all checks passed')

if __name__ == '__main__':
    main()
