import struct, math, random, sys, os
def read(p):
    d=open(p,'rb').read()
    tris=[]
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
def bbox(tris):
    xs=[p[0] for t in tris for p in t]; ys=[p[1] for t in tris for p in t]; zs=[p[2] for t in tris for p in t]
    return (min(xs),min(ys),min(zs),max(xs),max(ys),max(zs))
def pt_tri_d2(p,a,b,c):
    ax,ay,az=a; bx,by,bz=b; cx,cy,cz=c; px,py,pz=p
    abx,aby,abz=bx-ax,by-ay,bz-az; acx,acy,acz=cx-ax,cy-ay,cz-az
    apx,apy,apz=px-ax,py-ay,pz-az
    d1=abx*apx+aby*apy+abz*apz; d2=acx*apx+acy*apy+acz*apz
    if d1<=0 and d2<=0: return apx*apx+apy*apy+apz*apz
    bpx,bpy,bpz=px-bx,py-by,pz-bz
    d3=abx*bpx+aby*bpy+abz*bpz; d4=acx*bpx+acy*bpy+acz*bpz
    if d3>=0 and d4<=d3: return bpx*bpx+bpy*bpy+bpz*bpz
    cpx,cpy,cpz=px-cx,py-cy,pz-cz
    d5=abx*cpx+aby*cpy+abz*cpz; d6=acx*cpx+acy*cpy+acz*cpz
    if d6>=0 and d5<=d6: return cpx*cpx+cpy*cpy+cpz*cpz
    vc=d1*d4-d3*d2
    if vc<=0 and d1>=0 and d3<=0:
        t=d1/(d1-d3) if (d1-d3)!=0 else 0
        qx,qy,qz=ax+abx*t-px,ay+aby*t-py,az+abz*t-pz; return qx*qx+qy*qy+qz*qz
    vb=d5*d2-d1*d6
    if vb<=0 and d2>=0 and d6<=0:
        t=d2/(d2-d6) if (d2-d6)!=0 else 0
        qx,qy,qz=ax+acx*t-px,ay+acy*t-py,az+acz*t-pz; return qx*qx+qy*qy+qz*qz
    va=d3*d6-d5*d4
    if va<=0 and (d4-d3)>=0 and (d5-d6)>=0:
        t=(d4-d3)/((d4-d3)+(d5-d6)) if ((d4-d3)+(d5-d6))!=0 else 0
        qx=bx+(cx-bx)*t-px; qy=by+(cy-by)*t-py; qz=bz+(cz-bz)*t-pz; return qx*qx+qy*qy+qz*qz
    den=va+vb+vc
    if den==0: return apx*apx+apy*apy+apz*apz
    v=vb/den; w=vc/den
    qx=ax+abx*v+acx*w-px; qy=ay+aby*v+acy*w-py; qz=az+abz*v+acz*w-pz
    return qx*qx+qy*qy+qz*qz
def grid_index(tris,cell):
    g={}
    for i,(a,b,c) in enumerate(tris):
        lo=[min(a[k],b[k],c[k]) for k in range(3)]; hi=[max(a[k],b[k],c[k]) for k in range(3)]
        for ix in range(int(math.floor(lo[0]/cell)),int(math.floor(hi[0]/cell))+1):
            for iy in range(int(math.floor(lo[1]/cell)),int(math.floor(hi[1]/cell))+1):
                for iz in range(int(math.floor(lo[2]/cell)),int(math.floor(hi[2]/cell))+1):
                    g.setdefault((ix,iy,iz),[]).append(i)
    return g
def deviation(ref,test,nsamp=3000,seed=7):
    random.seed(seed)
    bb=bbox(ref); diag=math.dist(bb[0:3],bb[3:6]); cell=diag/60.0
    g=grid_index(ref,cell)
    ds=[]
    for _ in range(nsamp):
        a,b,c=test[random.randrange(len(test))]
        u,v=random.random(),random.random()
        if u+v>1: u,v=1-u,1-v
        p=tuple(a[k]+(b[k]-a[k])*u+(c[k]-a[k])*v for k in range(3))
        best=float('inf'); r=1
        while True:
            base=[int(math.floor(p[k]/cell)) for k in range(3)]
            cand=set()
            for ix in range(base[0]-r,base[0]+r+1):
                for iy in range(base[1]-r,base[1]+r+1):
                    for iz in range(base[2]-r,base[2]+r+1):
                        cand.update(g.get((ix,iy,iz),()))
            for i in cand:
                d2=pt_tri_d2(p,*ref[i])
                if d2<best: best=d2
            if cand and math.sqrt(best)<=r*cell: break
            r+=1
            if r>6: break
        ds.append(math.sqrt(best))
    ds.sort()
    return ds[-1], ds[int(len(ds)*0.95)], sum(ds)/len(ds)
if __name__=="__main__":
    ref=read(sys.argv[1]); test=read(sys.argv[2])
    mx,p95,mean=deviation(ref,test)
    rb=bbox(ref); tb=bbox(test)
    bd=max(abs(tb[i]-rb[i]) for i in range(6))
    grow=max(max(rb[i]-tb[i] for i in range(3)), max(tb[i+3]-rb[i+3] for i in range(3)))
    print("tris=%d  surf_dev max=%.3f p95=%.3f mean=%.3f  bbox_delta=%.3f  bbox_growth=%.3f"
          % (len(test),mx,p95,mean,bd,grow))
