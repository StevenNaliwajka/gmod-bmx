"""tools/rider/studio/fetch_model.py -- copy a player model's mesh out of a GMod install's
VPKs into .model/ for render.py. The files are Valve's, so they are fetched, not kept in
the repository.

    python3 fetch_model.py test-gmod:/opt/gmod/garrysmod     # over ssh (the dir holds garrysmod_dir.vpk)
    python3 fetch_model.py /path/to/GarrysMod/garrysmod       # a local install
    python3 fetch_model.py SRC models/player/group01/male_07  # another model (kleiner by default)
"""
import os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import vpk

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    model = sys.argv[2] if len(sys.argv) > 2 else 'models/player/kleiner'
    remote = ':' in src and not os.path.exists(src)
    host, gdir = src.split(':', 1) if remote else (None, src)

    def read(path, off=None, ln=None):
        if remote:
            if off is None:
                return subprocess.run(['ssh', host, 'cat', path], capture_output=True, check=True).stdout
            cmd = 'dd if=%s bs=65536 skip=%d count=%d iflag=skip_bytes,count_bytes 2>/dev/null' % (path, off, ln)
            return subprocess.run(['ssh', host, cmd], capture_output=True, check=True).stdout
        with open(path, 'rb') as f:
            if off is None:
                return f.read()
            f.seek(off)
            return f.read(ln)

    with tempfile.TemporaryDirectory() as tmp:
        dirvpk = os.path.join(tmp, 'garrysmod_dir.vpk')
        open(dirvpk, 'wb').write(read(gdir + '/garrysmod_dir.vpk'))
        entries, _, _ = vpk.read_dir(dirvpk)
    out = os.path.join(HERE, '.model')
    os.makedirs(out, exist_ok=True)
    for ext in ('.mdl', '.vvd', '.dx90.vtx'):
        name = model + ext
        if name not in entries:
            sys.exit('%s is not in %s/garrysmod_dir.vpk' % (name, gdir))
        arc, off, ln, pre = entries[name]
        data = pre + (read('%s/garrysmod_%03d.vpk' % (gdir, arc), off, ln) if ln else b'')
        open(os.path.join(out, os.path.basename(name)), 'wb').write(data)
        print('fetched', name, len(data), 'bytes')

if __name__ == '__main__':
    main()
