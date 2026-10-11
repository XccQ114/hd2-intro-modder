# SPDX-License-Identifier: CC-BY-NC-4.0
# parse-patch.py - parse hd2-audio-modder style patch containers (TocHeader)
import struct, sys

# entry type IDs
TYPES = {
    0x504B55235D21440E: 'WWISE_STREAM',   # audio stream = WAV region
    0x535A7BD3E650D799: 'WWISE_BANK',     # SoundBank data
    0xAF32095C82F2B070: 'WWISE_DEP',      # dependency (path string)
    0x0D972BAB10B40FD3: 'TEXT_BANK',      # text
    0x5EE65304478F8DB5: 'BINK_VIDEO',     # video
}

def parse(path):
    b = open(path, 'rb').read()
    if len(b) < 72: print('too small'); return
    magic, num_types, num_files, unknown = struct.unpack_from('<IIII', b, 0)
    print('=== %s ===' % path.split('\\')[-1])
    print('magic=0x%X num_types=%d num_files=%d unknown=%d size=%d' % (magic, num_types, num_files, unknown, len(b)))
    if magic != 0xF0000011: print('  NOT DSAR/LEGACY container!'); return
    off = 72
    type_headers = []
    for t in range(num_types):
        v0, entry_type, num_entries, h16, h64 = struct.unpack_from('<QQQII', b, off)
        type_headers.append((entry_type, num_entries))
        print('  type header[%d]: type=0x%X entries=%d' % (t, entry_type, num_entries))
        off += 32
    entries = []
    for i in range(num_files):
        e = struct.unpack_from('<QQQQQQQIIIIII', b, off)
        entries.append(e)
        off += 80
    print('  entries (file_id, type_id, toc_off, stream_off, gpu_off, u1, u2, toc_size, stream_size, gpu_size, u3, u4, idx):')
    for i, e in enumerate(entries):
        print('  [%d] id=0x%X type=0x%X toc_off=0x%X stream_off=0x%X toc_size=%d stream_size=%d idx=%d' % (
            i, e[0], e[1], e[2], e[3], e[7], e[8], e[12]))
    # toc data area
    print('  toc_data area starts at 0x%X:' % off)
    for i, e in enumerate(entries):
        td = e[7]
        tdo = e[2]
        print('  entry[%d] toc_data @0x%X (%d bytes): %s' % (i, tdo, td, ' '.join('%02X' % x for x in b[tdo:tdo+min(td,16)])))
    return entries

if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] in ('-h', '--help'):
        print('usage: python parse-patch.py <patch_file> [<patch_file> ...]')
        print('parse hd2-audio-modder style patch containers (TocHeader), e.g.:')
        print('  python parse-patch.py data\\9ba626afa44a3aa3.patch_0')
        sys.exit(1)
    for p in sys.argv[1:]:
        parse(p)
        print()
