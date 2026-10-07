# Decode HL2/GMod textures straight out of a server's VPKs, for tools/city/preview.py
# and for choosing facade panels. Run it ON a Garry's Mod server (it reads /opt/gmod):
#
#   python3 texdump.py sheet.png COLS CELL 'materials/building_template/*'   contact sheet
#   python3 -c 'import runpy; runpy.run_path("texdump.py", run_name="lib")["dump"]("texdump", ["materials/building_template/*", ...])'
#
# dump() writes one PNG per material plus index.txt (vmt, vtf, size, file).
# DXT1/DXT3/DXT5 and the plain RGB(A) formats; alpha is dropped.
import struct,sys,os,zlib,re,fnmatch
VPKS=['/opt/gmod/sourceengine/hl2_textures','/opt/gmod/sourceengine/hl2_misc','/opt/gmod/sourceengine/content_hl2','/opt/gmod/garrysmod/garrysmod']
idx={}
for base in VPKS:
  p=base+'_dir.vpk'; d=open(p,'rb').read()
  sig,ver,treesz=struct.unpack_from('<III',d,0); hdr=12 if ver==1 else 28
  o=hdr
  def rs(o):
    e=d.index(b'\0',o); return d[o:e].decode('latin1'),e+1
  while True:
    ext,o=rs(o)
    if not ext: break
    while True:
      path,o=rs(o)
      if not path: break
      while True:
        name,o=rs(o)
        if not name: break
        crc,pre,arch,off,ln,term=struct.unpack_from('<IHHIIH',d,o); o+=18
        predata=d[o:o+pre]; o+=pre
        idx.setdefault(f'{path}/{name}.{ext}'.lower(),(base,arch,off,ln,predata,hdr+treesz))
def read(name):
  base,arch,off,ln,pre,dataoff=idx[name.lower()]
  if arch==0x7fff:
    with open(base+'_dir.vpk','rb') as f: f.seek(dataoff+off); return pre+f.read(ln)
  with open('%s_%03d.vpk'%(base,arch),'rb') as f: f.seek(off); return pre+f.read(ln)
def vmt_base(vmt):
  t=read(vmt).decode('latin1')
  m=re.search(r'"?\$basetexture"?\s+"?([^"\s]+)"?',t,re.I)
  if m: return 'materials/'+m.group(1).replace('\\','/').lower()+'.vtf'
  m=re.search(r'"?include"?\s+"?([^"\s]+)"?',t,re.I)
  if m: return vmt_base(m.group(1).lower())
def c565(c): return ((c>>11&31)*255//31,(c>>5&63)*255//63,(c&31)*255//31)
def dxt(data,w,h,fmt):
  out=bytearray(w*h*3); bs=8 if fmt==13 else 16; o=0
  for by in range(0,h,4):
    for bx in range(0,w,4):
      if fmt!=13: o+=8
      c0,c1,bits=struct.unpack_from('<HHI',data,o); o+=8
      a=c565(c0); b=c565(c1)
      if c0>c1 or fmt!=13: pal=[a,b,tuple((2*a[i]+b[i])//3 for i in range(3)),tuple((a[i]+2*b[i])//3 for i in range(3))]
      else: pal=[a,b,tuple((a[i]+b[i])//2 for i in range(3)),(0,0,0)]
      for py in range(4):
        for px in range(4):
          x=bx+px;y=by+py
          if x<w and y<h:
            c=pal[(bits>>(2*(py*4+px)))&3]; j=(y*w+x)*3; out[j:j+3]=bytes(c)
  return out
def vtf(name,maxdim):
  b=read(name)
  hs=struct.unpack_from('<I',b,12)[0]; w,h=struct.unpack_from('<HH',b,16); frames=struct.unpack_from('<H',b,24)[0]
  fmt=struct.unpack_from('<i',b,52)[0]; mips=b[56]; lfmt=struct.unpack_from('<i',b,57)[0]; lw,lh=b[61],b[62]
  ver=struct.unpack_from('<II',b,4)
  def sz(w,h,f):
    if f==13: return max(1,(w+3)//4)*max(1,(h+3)//4)*8
    if f in(14,15): return max(1,(w+3)//4)*max(1,(h+3)//4)*16
    return w*h*{2:3,3:3,0:4,12:4,16:4}.get(f,4)
  data_off=hs
  if ver[1]>=3:
    nres=struct.unpack_from('<I',b,68)[0]
    for i in range(nres):
      tag,flags,val=struct.unpack_from('<3sBI',b,80+8*i)
      if tag==b'\x30\x00\x00': data_off=val
  else:
    data_off=hs+(sz(lw,lh,13) if lfmt==13 else 0)
  # mips stored smallest->largest
  sizes=[(max(1,w>>m),max(1,h>>m)) for m in range(mips)]
  o=data_off
  for m in range(mips-1,-1,-1):
    mw,mh=sizes[m]; s=sz(mw,mh,fmt)*frames
    nxt=sizes[m-1] if m>0 else None
    if m==0 or max(nxt)>maxdim:
      chunk=b[o:o+sz(mw,mh,fmt)]
      if fmt in(13,14,15): return mw,mh,dxt(chunk,mw,mh,fmt),(w,h)
      px=bytearray(mw*mh*3); bpp=sz(1,1,fmt)
      for i in range(mw*mh):
        p=chunk[i*bpp:i*bpp+bpp]
        if fmt in(3,12,16): px[i*3:i*3+3]=bytes((p[2],p[1],p[0]))
        else: px[i*3:i*3+3]=p[:3]
      return mw,mh,px,(w,h)
    o+=s
def png(path,w,h,rgb):
  raw=b''.join(b'\0'+bytes(rgb[y*w*3:(y+1)*w*3]) for y in range(h))
  ch=lambda t,d: struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
  open(path,'wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,6))+ch(b'IEND',b''))
if __name__=='__main__':
  out,cols,cell=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]); pats=sys.argv[4:]
  names=sorted(set(n for n in idx if n.endswith('.vmt') and any(fnmatch.fnmatch(n,p) for p in pats)))
  items=[]
  for n in names:
    try:
      t=vmt_base(n)
      if t and t in idx: items.append((n,vtf(t,cell)))
    except Exception as e: print('ERR',n,e,file=sys.stderr)
  rows=(len(items)+cols-1)//cols; W=cols*cell; H=rows*cell
  img=bytearray(W*H*3)
  lab=[]
  for k,(n,(w,h,px,full)) in enumerate(items):
    cx=(k%cols)*cell; cy=(k//cols)*cell
    for y in range(cell):
      sy=y*h//cell
      for x in range(cell):
        sx=x*w//cell; j=(sy*w+sx)*3; i=((cy+y)*W+cx+x)*3; img[i:i+3]=px[j:j+3]
    lab.append(f'{k}: {n} {full[0]}x{full[1]}')
  png(out,W,H,img); open(out+'.txt','w').write('\n'.join(lab)); print('\n'.join(lab))

def dump(outdir,pats,maxdim=256):
  os.makedirs(outdir,exist_ok=True)
  names=sorted(set(n for n in idx if n.endswith('.vmt') and any(fnmatch.fnmatch(n,p) for p in pats)))
  with open(outdir+'/index.txt','w') as f:
    for n in names:
      try:
        t=vmt_base(n)
        if t and t in idx:
          w,h,px,full=vtf(t,maxdim); fn=n.replace('materials/','').replace('/','__')[:-4]+'.png'
          png(outdir+'/'+fn,w,h,px); f.write(f'{n}\t{t}\t{full[0]}x{full[1]}\t{fn}\n')
      except Exception as e: print('ERR',n,e,file=sys.stderr)
