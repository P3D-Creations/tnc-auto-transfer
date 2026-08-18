import struct, math, os, json, sys
D=os.path.join(os.path.dirname(os.path.abspath(__file__)),"bundle")
def w(path,tris):
    with open(path,"wb") as f:
        f.write(b"x".ljust(80,b"\0")); f.write(struct.pack("<I",len(tris)))
        for (a,b,c) in tris:
            f.write(struct.pack("<3f",0,0,0))
            for p in (a,b,c): f.write(struct.pack("<3f",*p))
            f.write(struct.pack("<H",0))
def box(x0,y0,z0,x1,y1,z1):
    v=[(x0,y0,z0),(x1,y0,z0),(x1,y1,z0),(x0,y1,z0),(x0,y0,z1),(x1,y0,z1),(x1,y1,z1),(x0,y1,z1)]
    q=[(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)]
    t=[]
    for (a,b,c,d) in q: t.append((v[a],v[b],v[c])); t.append((v[a],v[c],v[d]))
    return t
def sphere(r,nu,nv,cz=0):
    t=[]
    for i in range(nu):
        for j in range(nv):
            th0=2*math.pi*i/nu; th1=2*math.pi*(i+1)/nu
            ph0=math.pi*j/nv;   ph1=math.pi*(j+1)/nv
            P=lambda th,ph:(r*math.sin(ph)*math.cos(th),r*math.sin(ph)*math.sin(th),cz+r*math.cos(ph))
            a,b,c,d=P(th0,ph0),P(th1,ph0),P(th1,ph1),P(th0,ph1)
            t.append((a,b,c)); t.append((a,c,d))
    return t
prog = os.path.join(D,"OP1.h")
open(prog,"w").write("BEGIN PGM OP1 MM\nEND PGM OP1 MM\n")
# Stock in setup-WCS: -150..0 x, -150..0 y, -13.7..0 z
w(os.path.join(D,"STOCK.stl"), box(-150,-150,-13.7, 0,0,0))
w(os.path.join(D,"PART.stl"),  sphere(40,120,60,cz=-6))          # 14400 tris
# Fixture in setup-WCS, attach at (-75,-75,-166.71); pullstud below it
fx = box(-150,-150,-166.71, 0,0,-13.7) + box(-85,-85,-186.71, -65,-65,-166.71)
w(os.path.join(D,"FIXTURE.stl"), fx)
meta = {
 "schema":"p3d.kern.fixture-stl-meta","schemaVersion":1,
 "generated":{"utc":"2026-08-17T23:21:36.150Z","post":"Kern Micro - P3D"},
 "program":{"programName":"UNNAMED","ncFile":"OP1.h","outputFolder":"<save folder>\OP1","fileStem":"OP1","ncUnits":"mm"},
 "machine":{"present":True,"vendor":"Kern","model":"Micro Vario"},
 "wcs":{"firstSectionWorkOffset":2,"workOffsetsUsed":[2],"attachPointFromSectionIndex":0},
 "frames":{"stlVertexFrame":"setup-WCS","stlVertexFrameConfidence":"inferred-unverified",
           "stlUnits":"mm","camDocumentUnits":"mm","ncUnits":"mm"},
 "fixtureAttachPoint_inFixtureFrame":          {"units":"mm","x":-75.0,"y":-75.0,"z":-166.71},
 "fixtureAttachPoint_inFixtureFrame_stlUnits": {"units":"mm","x":-75.0,"y":-75.0,"z":-166.71},
 "fixtureAttachPoint_inFixtureFrame_mm":       {"units":"mm","x":-75.0,"y":-75.0,"z":-166.71},
 "stockBounds_wcs":{"lower":{"units":"mm","x":-150.0,"y":-150.0,"z":-13.7},
                    "upper":{"units":"mm","x":0.0,"y":0.0,"z":0.0}},
 "exports":[{"role":"STOCK","file":"STOCK.stl","sourceAvailable":True,"written":True},
            {"role":"PART","file":"PART.stl","sourceAvailable":True,"written":True},
            {"role":"FIXTURE","file":"FIXTURE.stl","sourceAvailable":True,"written":True}],
 "warnings":[]
}
if len(sys.argv)>1 and sys.argv[1]=="badframe":
    meta["stockBounds_wcs"]["lower"]["x"]=-999.0     # force a frame mismatch
if len(sys.argv)>1 and sys.argv[1]=="noattach":
    meta["fixtureAttachPoint_inFixtureFrame_stlUnits"]=None
open(os.path.join(D,"FIXTURE.json"),"w").write(json.dumps(meta,indent=1))
print("bundle written to", D)
