"""tools/rider/studio/mdl.py -- just enough of Source's model format (MDL v48, VVD, the
dx90 VTX) to skin a player model: the bones (name, parent, the bind pose's model-to-bone
matrix), LOD 0's vertices with their bone weights, and the first body's triangles."""
import struct, numpy as np

def cstr(d, o):
    e = d.index(b'\0', o); return d[o:e].decode('latin1')

def load(base):
    m = open(base + '.mdl', 'rb').read()
    numbones, boneindex = struct.unpack_from('<ii', m, 156)
    bones = []
    for i in range(numbones):
        o = boneindex + i * 216
        nameidx, parent = struct.unpack_from('<ii', m, o)
        name = cstr(m, o + nameidx)
        p2b = np.array(struct.unpack_from('<12f', m, o + 96)).reshape(3, 4)
        bones.append((name, parent, p2b))
    numbp, bpidx = struct.unpack_from('<ii', m, 232)
    # models: (bodypart, model) -> (vertexindex, [(meshvertexoffset, material)])
    models = []
    for bp in range(numbp):
        bo = bpidx + bp * 16
        _, nummodels, _, modelindex = struct.unpack_from('<iiii', m, bo)
        mods = []
        for mi in range(nummodels):
            mo = bo + modelindex + mi * 148
            name = m[mo:mo+64].split(b'\0')[0].decode('latin1')
            nummeshes, meshindex, numverts, vertexindex = struct.unpack_from('<iiii', m, mo + 72)
            meshes = []
            for k in range(nummeshes):
                me = mo + meshindex + k * 116
                mat, _, mnv, voff = struct.unpack_from('<iiii', m, me)
                meshes.append((voff, mat))
            mods.append((name, vertexindex // 48, numverts, meshes))
        models.append(mods)
    # VVD
    v = open(base + '.vvd', 'rb').read()
    numLODs = struct.unpack_from('<i', v, 12)[0]
    nlv = struct.unpack_from('<8i', v, 16)
    numFixups, fixStart, vStart, tStart = struct.unpack_from('<iiii', v, 48)
    nall = (tStart - vStart) // 48
    raw = np.frombuffer(v, dtype=np.uint8, count=nall * 48, offset=vStart).reshape(nall, 48)
    if numFixups > 0:
        idx = []
        for f in range(numFixups):
            lod, src, n = struct.unpack_from('<iii', v, fixStart + f * 12)
            if lod >= 0: idx.extend(range(src, src + n))
        raw = raw[np.array(idx)]
    w = raw[:, 0:12].copy().view('<f4').reshape(-1, 3)
    bi = raw[:, 12:15].astype(np.int32)
    nb = raw[:, 15].astype(np.int32)
    pos = raw[:, 16:28].copy().view('<f4').reshape(-1, 3)
    nrm = raw[:, 28:40].copy().view('<f4').reshape(-1, 3)
    # zero the unused weights
    for k in range(3):
        w[nb <= k, k] = 0
    # VTX
    t = open(base + '.dx90.vtx', 'rb').read()
    nbody, bodyoff = struct.unpack_from('<ii', t, 28)
    tris = []; tmat = []
    for bp in range(nbody):
        bo = bodyoff + bp * 8
        nmod, modoff = struct.unpack_from('<ii', t, bo)
        for mi in range(min(nmod, 1)):           # body part's first model (the default body)
            mo = bo + modoff + mi * 8
            nlod, lodoff = struct.unpack_from('<ii', t, mo)
            lo = mo + lodoff                     # LOD 0
            nmesh, meshoff = struct.unpack_from('<ii', t, lo)
            _, vbase, _, meshes = models[bp][mi]
            for k in range(nmesh):
                me = lo + meshoff + k * 9
                nsg, sgoff = struct.unpack_from('<ii', t, me)
                mvoff, mat = meshes[k]
                for g in range(nsg):
                    so = me + sgoff + g * 25
                    nv, voff, ni, ioff, ns, soff = struct.unpack_from('<iiiiii', t, so)
                    verts = np.array([struct.unpack_from('<H', t, so + voff + j * 9 + 4)[0] for j in range(nv)])
                    ind = np.frombuffer(t, dtype='<u2', count=ni, offset=so + ioff)
                    gv = vbase + mvoff + verts[ind]
                    tris.append(gv.reshape(-1, 3)); tmat.append(np.full(len(gv) // 3, mat))
    tris = np.concatenate(tris); tmat = np.concatenate(tmat)
    return dict(bones=bones, pos=pos, nrm=nrm, w=w, bi=bi, tris=tris, tmat=tmat)

if __name__ == '__main__':
    import sys
    M = load(sys.argv[1])
    print(len(M['bones']), 'bones', len(M['pos']), 'verts', len(M['tris']), 'tris')
    print([b[0] for b in M['bones']][:12])
    print('bbox', M['pos'].min(0), M['pos'].max(0), 'weights sum', M['w'].sum(1).min(), M['w'].sum(1).max())
    print('max index', M['tris'].max(), 'mats', np.unique(M['tmat']))
