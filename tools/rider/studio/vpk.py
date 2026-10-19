"""tools/rider/studio/vpk.py -- read a VPK (v1/v2) directory file: path -> (archive, offset,
length, preload bytes). fetch_model.py uses it to pull a model out of GMod's own VPKs."""
import struct, sys
def read_dir(path):
    f = open(path, 'rb'); data = f.read()
    sig, ver, tree = struct.unpack_from('<III', data, 0)
    assert sig == 0x55aa1234, hex(sig)
    hdr = 28 if ver == 2 else 12
    p = hdr
    def cstr():
        nonlocal p
        e = data.index(b'\0', p); s = data[p:e].decode('latin1'); p = e + 1; return s
    out = {}
    while True:
        ext = cstr()
        if not ext: break
        while True:
            d = cstr()
            if not d: break
            while True:
                n = cstr()
                if not n: break
                crc, pre, arc, off, ln, term = struct.unpack_from('<IHHIIH', data, p); p += 18
                preload = data[p:p+pre]; p += pre
                full = (d + '/' if d != ' ' else '') + n + '.' + ext
                out[full.lower()] = (arc, off, ln, preload)
    return out, hdr + tree, data
if __name__ == '__main__':
    out, base, _ = read_dir(sys.argv[1])
    for k, v in out.items():
        if any(s in k for s in sys.argv[2:]): print(k, v[0], v[1], v[2], len(v[3]))
