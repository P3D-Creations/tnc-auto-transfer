import struct, sys, os
from collections import defaultdict
def read(p):
    d=open(p,'rb').read(); tris=[]
    if d[:5]==b'solid' and b'facet' in d[:2000]:
        cur=[]
        for line in d.split(b'\n'):
            t=line.strip()
            if t.startswith(b'vertex'):
                _,x,y,z=t.split(); cur.append((float(x),float(y),float(z)))
                if len(cur)==3: tris.append(tuple(cur)); cur=[]
        return tris
    n=struct.unpack("<I",d[80:84])[0]; o=84
    for _ in range(n):
        o+=12; ps=[]
        for _ in range(3):
            ps.append(struct.unpack("<3f",d[o:o+12])); o+=12
        o+=2; tris.append(tuple(ps))
    return tris
def check(p):
    tris=read(p)
    vid={}; F=[]
    for t in tris:
        f=[]
        for v in t:
            k=(round(v[0],6),round(v[1],6),round(v[2],6))
            if k not in vid: vid[k]=len(vid)
            f.append(vid[k])
        F.append(f)
    degen=sum(1 for f in F if len(set(f))<3)
    half=defaultdict(int); undir=defaultdict(int)
    for f in F:
        if len(set(f))<3: continue
        for i in range(3):
            a,b=f[i],f[(i+1)%3]
            half[(a,b)]+=1
            undir[(min(a,b),max(a,b))]+=1
    boundary=sum(1 for e,c in undir.items() if c==1)      # hole edges
    nonman  =sum(1 for e,c in undir.items() if c>2)       # >2 faces on an edge
    flipped =sum(1 for e,c in half.items() if c>1)        # same direction twice = bad winding
    wt = (boundary==0 and nonman==0 and flipped==0 and degen==0)
    print("%-26s tris=%-7d verts=%-7d  watertight=%-5s  holes=%-5d nonmanifold=%-4d badwind=%-4d degen=%d"
          % (os.path.basename(p), len(tris), len(vid), wt, boundary, nonman, flipped, degen))
    return wt
for p in sys.argv[1:]: check(p)
