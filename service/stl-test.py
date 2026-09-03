import struct, math, os, subprocess, json, sys

D = os.path.dirname(os.path.abspath(__file__))
EXE = r"N:\Electronics and Software Projects\tnc-auto-transfer\TNCWatcher-StlPrep.exe"

def write_binary_stl(path, tris):
    with open(path, "wb") as f:
        f.write(b"test".ljust(80, b"\0"))
        f.write(struct.pack("<I", len(tris)))
        for (a, b, c) in tris:
            u = [b[i]-a[i] for i in range(3)]
            v = [c[i]-a[i] for i in range(3)]
            n = [u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]]
            L = math.sqrt(sum(x*x for x in n)) or 1.0
            n = [x/L for x in n]
            f.write(struct.pack("<3f", *n))
            for p in (a, b, c):
                f.write(struct.pack("<3f", *p))
            f.write(struct.pack("<H", 0))

def read_binary_stl(path):
    with open(path, "rb") as f:
        d = f.read()
    n = struct.unpack("<I", d[80:84])[0]
    assert len(d) == 84 + 50*n, "size mismatch %d vs %d" % (len(d), 84+50*n)
    tris = []
    o = 84
    for _ in range(n):
        o += 12
        pts = []
        for _ in range(3):
            pts.append(struct.unpack("<3f", d[o:o+12])); o += 12
        o += 2
        tris.append(pts)
    return tris

def bbox(tris):
    xs = [p[0] for t in tris for p in t]
    ys = [p[1] for t in tris for p in t]
    zs = [p[2] for t in tris for p in t]
    return (min(xs), min(ys), min(zs), max(xs), max(ys), max(zs))

def box(x0, y0, z0, x1, y1, z1):
    v = [(x0,y0,z0),(x1,y0,z0),(x1,y1,z0),(x0,y1,z0),
         (x0,y0,z1),(x1,y0,z1),(x1,y1,z1),(x0,y1,z1)]
    q = [(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)]
    t = []
    for (a,b,c,d) in q:
        t.append((v[a],v[b],v[c])); t.append((v[a],v[c],v[d]))
    return t

def sphere(r, nu, nv):
    t = []
    for i in range(nu):
        for j in range(nv):
            th0 = 2*math.pi*i/nu;      th1 = 2*math.pi*(i+1)/nu
            ph0 = math.pi*j/nv;        ph1 = math.pi*(j+1)/nv
            def P(th, ph):
                return (r*math.sin(ph)*math.cos(th), r*math.sin(ph)*math.sin(th), r*math.cos(ph))
            a,b,c,d = P(th0,ph0), P(th1,ph0), P(th1,ph1), P(th0,ph1)
            t.append((a,b,c)); t.append((a,c,d))
    return t

def run(args):
    p = subprocess.run([EXE] + args, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()

fails = []
def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (("  -- " + detail) if detail and not cond else ""))
    if not cond: fails.append(name)

print("== TEST 1: fixture scaling, attach at bottom centre ==")
src = os.path.join(D, "box.stl"); out = os.path.join(D, "box_out.stl")
write_binary_stl(src, box(-50,-40,0, 50,40,50))
rc, so, se = run([src, out, "--clearance", "1.5", "--attach", "0,0,0"])
check("exit 0", rc == 0, se)
r = json.loads(so)
bb = bbox(read_binary_stl(out))
print("   bbox out:", [round(x,4) for x in bb])
check("X faces in 1.5 each", abs(bb[0]+48.5) < 1e-3 and abs(bb[3]-48.5) < 1e-3, str(bb))
check("Y faces in 1.5 each", abs(bb[1]+38.5) < 1e-3 and abs(bb[4]-38.5) < 1e-3, str(bb))
check("top down 1.5",       abs(bb[5]-48.5) < 1e-3, str(bb))
check("bottom ANCHORED",    abs(bb[2]-0.0)  < 1e-6, str(bb))
check("no decimation (12 tris)", r["trianglesOut"] == 12, so)

print("== TEST 2: no attach supplied -> FAIL SAFE, scaling skipped ==")
rc, so, se = run([src, out, "--clearance", "1.5"])
r = json.loads(so); bb = bbox(read_binary_stl(out))
check("exit 0", rc == 0, se)
check("scaling skipped", r["scaled"] is False, so)
check("warns no attach", any("no attach point supplied" in w for w in r["warnings"]), so)
check("geometry untouched", abs(bb[3]-50) < 1e-6 and abs(bb[5]-50) < 1e-6, str(bb))

print("== TEST 2b: --attach auto opts in to the guess ==")
rc, so, se = run([src, out, "--clearance", "1.5", "--attach", "auto"])
r = json.loads(so); bb = bbox(read_binary_stl(out))
check("exit 0", rc == 0, se)
check("scaled", r["scaled"] is True, so)
check("warns it GUESSED", any("GUESSED" in w for w in r["warnings"]), so)
check("bottom anchored", abs(bb[2]) < 1e-6, str(bb))

print("== TEST 3: off-centre anchor warns + guarantees >= clearance (no-translate) ==")
rc, so, se = run([src, out, "--clearance", "1.5", "--attach", "-30,0,0", "--no-translate"])
r = json.loads(so); bb = bbox(read_binary_stl(out))
check("exit 0", rc == 0, se)
check("warns off-centre", any("off-centre" in w for w in r["warnings"]), so)
check("far face >= 1.5 in", (50 - bb[3]) >= 1.5 - 1e-6, "moved %.4f" % (50-bb[3]))
check("near face >= 1.5 in", (bb[0] - (-50)) >= 1.5 - 1e-6, "moved %.4f" % (bb[0]+50))

print("== TEST 4: decimation 40k -> <=19500 ==")
sp = os.path.join(D, "sphere.stl"); spo = os.path.join(D, "sphere_out.stl")
st = sphere(25.0, 200, 100)
write_binary_stl(sp, st)
print("   input triangles:", len(st))
rc, so, se = run([sp, spo, "--max-tris", "19500"])
check("exit 0", rc == 0, se)
r = json.loads(so)
print("   report:", so[:220])
check("under budget", r["trianglesOut"] <= 19500, so)
check("actually decimated", r["decimated"] is True, so)
bb = bbox(read_binary_stl(spo))
rad = max(abs(bb[0]), abs(bb[3]), abs(bb[1]), abs(bb[4]), abs(bb[2]), abs(bb[5]))
check("radius preserved ~25 (+/-0.5)", abs(rad - 25.0) < 0.5, "radius %.4f" % rad)
check("deviation small (<0.5mm)", r["maxDeviation"] < 0.5, str(r["maxDeviation"]))

print("== TEST 5: truncated binary STL rejected ==")
tr = os.path.join(D, "trunc.stl")
with open(sp, "rb") as f: d = f.read()
with open(tr, "wb") as f: f.write(d[:len(d)//2])
rc, so, se = run([tr, os.path.join(D, "trunc_out.stl")])
check("exit code 2", rc == 2, "rc=%d" % rc)
check("says incomplete", "Incomplete" in se, se)

print("== TEST 6: ASCII STL read ==")
asc = os.path.join(D, "ascii.stl")
with open(asc, "w") as f:
    f.write("solid t\n")
    for (a,b,c) in box(0,0,0, 10,10,10):
        f.write(" facet normal 0 0 0\n  outer loop\n")
        for p in (a,b,c): f.write("   vertex %f %f %f\n" % p)
        f.write("  endloop\n endfacet\n")
    f.write("endsolid t\n")
rc, so, se = run([asc, os.path.join(D, "ascii_out.stl"), "--clearance", "1", "--attach", "5,5,0"])
check("exit 0", rc == 0, se)
bb = bbox(read_binary_stl(os.path.join(D, "ascii_out.stl")))
check("ascii scaled, bottom anchored", abs(bb[2]) < 1e-6 and abs(bb[5]-9.0) < 1e-3, str(bb))

print("== TEST 7: combined decimate + scale (fixture path) ==")
rc, so, se = run([sp, spo, "--max-tris", "19500", "--clearance", "1.5", "--attach", "0,0,-25", "--no-translate"])
check("exit 0", rc == 0, se)
r = json.loads(so); bb = bbox(read_binary_stl(spo))
check("under budget", r["trianglesOut"] <= 19500, so)
check("anchor Z held (-25)", abs(bb[2] + 25.0) < 0.05, str(bb))
check("top pulled down ~1.5", abs((25.0 - bb[5]) - 1.5) < 0.15, "moved %.4f" % (25.0-bb[5]))

print("== TEST 8: pallet - pullstud BELOW attach plane must not move in Z ==")
# Body 0..60 in Z, pullstud from -20..0 (below the attach plane at z=0).
pal = box(-50,-50,0, 50,50,60) + box(-8,-8,-20, 8,8,0)
ps = os.path.join(D, "pallet.stl"); pso = os.path.join(D, "pallet_out.stl")
write_binary_stl(ps, pal)
rc, so, se = run([ps, pso, "--clearance", "1.5", "--attach", "0,0,0"])
check("exit 0", rc == 0, se)
r = json.loads(so); bb = bbox(read_binary_stl(pso))
print("   bbox out:", [round(x,4) for x in bb], " warnings:", r["warnings"])
check("pullstud tip Z UNCHANGED (-20)", abs(bb[2] + 20.0) < 1e-6, "got %.6f" % bb[2])
check("body top down 1.5", abs(bb[5] - 58.5) < 1e-3, str(bb))
check("sides in 1.5", abs(bb[3] - 48.5) < 1e-3, str(bb))
check("reports verts below anchor", r["vertsBelowAnchor"] > 0, so)
check("warns about mount features", any("below the attach plane" in w for w in r["warnings"]), so)

print("== TEST 9: asymmetric fixture, attach off bbox centre in X and Y ==")
# Body spans X -20..120, Y -10..90; attach at (0,0,0) - well off centre.
asym = box(-20,-10,0, 120,90,40)
af = os.path.join(D, "asym.stl"); afo = os.path.join(D, "asym_out.stl")
write_binary_stl(af, asym)
rc, so, se = run([af, afo, "--clearance", "1.5", "--attach", "0,0,0"])
check("exit 0", rc == 0, se)
r = json.loads(so); bb = bbox(read_binary_stl(afo))
print("   bbox out:", [round(x,4) for x in bb])
check("X low face in >=1.5",  (bb[0] - (-20)) >= 1.5 - 1e-6, "moved %.4f" % (bb[0]+20))
check("X high face in >=1.5", (120 - bb[3]) >= 1.5 - 1e-6, "moved %.4f" % (120-bb[3]))
check("Y low face in >=1.5",  (bb[1] - (-10)) >= 1.5 - 1e-6, "moved %.4f" % (bb[1]+10))
check("Y high face in >=1.5", (90 - bb[4]) >= 1.5 - 1e-6, "moved %.4f" % (90-bb[4]))
check("warns about overshoot", any("off-centre" in w for w in r["warnings"]), so)

print("== TEST 10: --attach re-origins the mesh (control expects attach at 0,0,0) ==")
# Fixture sitting in setup-WCS coords; attach point is NOT at the bbox bottom.
fx = box(-75,-75,-166.71, 25,25,-13.7)
fp = os.path.join(D, "fix.stl"); fpo = os.path.join(D, "fix_out.stl")
write_binary_stl(fp, fx)
A = (-75.0, -75.0, -166.71)
rc, so, se = run([fp, fpo, "--attach", "%f,%f,%f" % A, "--max-tris", "0"])
check("exit 0", rc == 0, se)
r = json.loads(so); bb = bbox(read_binary_stl(fpo))
print("   bbox out:", [round(x,4) for x in bb])
check("translated flag", r["translated"] is True, so)
check("attach now at origin", abs(bb[0]) < 1e-3 and abs(bb[1]) < 1e-3 and abs(bb[2]) < 1e-3, str(bb))
# Doc's worked assertion: stock underside 13.7mm below WCS0 -> 153.01mm above attach
check("fixture top = 153.01 above origin", abs(bb[5] - 153.01) < 0.01, "got %.4f" % bb[5])

print("== TEST 11: translate + clearance, mount features below attach hold Z ==")
# Same fixture plus a pullstud reaching below the attach plane.
fx2 = fx + box(-80,-80,-186.71, -70,-70,-166.71)
write_binary_stl(fp, fx2)
rc, so, se = run([fp, fpo, "--attach", "%f,%f,%f" % A, "--clearance", "1.5", "--max-tris", "0"])
check("exit 0", rc == 0, se)
r = json.loads(so); bb = bbox(read_binary_stl(fpo))
print("   bbox out:", [round(x,4) for x in bb], " scale:", r["scale"])
check("pullstud tip Z held (-20)", abs(bb[2] + 20.0) < 1e-3, "got %.6f" % bb[2])
check("top pulled down 1.5", abs(bb[5] - (153.01 - 1.5)) < 0.01, "got %.4f" % bb[5])
check("reports verts below anchor", r["vertsBelowAnchor"] > 0, so)

print("== TEST 12: inch mesh - clearance given in mm is converted ==")
inch = box(-2,-2,0, 2,2,2)          # 4x4x2 inch block
ip = os.path.join(D, "inch.stl"); ipo = os.path.join(D, "inch_out.stl")
write_binary_stl(ip, inch)
rc, so, se = run([ip, ipo, "--attach", "0,0,0", "--clearance", "1.5", "--stl-units", "in", "--max-tris", "0"])
check("exit 0", rc == 0, se)
r = json.loads(so); bb = bbox(read_binary_stl(ipo))
exp = 2.0 - 1.5/25.4
check("faces in 1.5mm = 0.059in", abs(bb[3] - exp) < 1e-4, "got %.6f want %.6f" % (bb[3], exp))
check("top in 1.5mm", abs(bb[5] - (2.0 - 1.5/25.4)) < 1e-4, str(bb))
check("reports stlUnits in", r["stlUnits"] == "in", so)

print("== TEST 13: --probe reports as-read bounds, writes nothing ==")
probe_out = os.path.join(D, "should_not_exist.stl")
if os.path.exists(probe_out): os.remove(probe_out)
rc, so, se = run([fp, probe_out, "--probe"])
check("exit 0", rc == 0, se)
r = json.loads(so)
check("probe flag", r.get("probe") is True, so)
check("no file written", not os.path.exists(probe_out), "file appeared")
check("bounds as-read (un-translated)", abs(r["bboxIn"][0] - (-80)) < 1e-3, str(r["bboxIn"]))

print("== TEST 14: --no-translate keeps mesh in place ==")
rc, so, se = run([fp, fpo, "--attach", "%f,%f,%f" % A, "--no-translate", "--max-tris", "0"])
r = json.loads(so); bb = bbox(read_binary_stl(fpo))
check("exit 0", rc == 0, se)
check("not translated", r["translated"] is False, so)
check("still in WCS coords", abs(bb[0] - (-80)) < 1e-3, str(bb))

print("== TEST 15: --cut-below-attach removes below-plane geometry and caps ==")
# closed box piercing the attach plane: -20 below, +10 above
st15 = os.path.join(D, "cut15.stl"); st15o = os.path.join(D, "cut15_out.stl")
write_binary_stl(st15, box(-15,-15,-20, 15,15,10))
rc, so, se = run([st15, st15o, "--attach", "0,0,0", "--cut-below-attach", "--max-tris", "0"])
check("exit 0", rc == 0, se)
r = json.loads(so); bb = bbox(read_binary_stl(st15o))
check("cut ran", r["cutBelowAttach"] is True, so)
check("one cap loop", r["capLoops"] == 1, so)
check("nothing below plane", abs(bb[2]) < 1e-6, str(bb))
check("top preserved (+10)", abs(bb[5] - 10) < 1e-6, str(bb))
check("output closed", r["topologyOut"]["closed"] is True and r["topologyOut"]["holes"] == 0, so)

print("== TEST 16: cut without an attach point is refused, geometry untouched ==")
rc, so, se = run([st15, st15o, "--cut-below-attach", "--max-tris", "0"])
check("exit 0", rc == 0, se)
r = json.loads(so); bb = bbox(read_binary_stl(st15o))
check("cut skipped", r["cutBelowAttach"] is False, so)
check("warns about missing attach", any("cut SKIPPED" in w for w in r["warnings"]), so)
check("below-plane geometry kept", abs(bb[2] + 20) < 1e-6, str(bb))

print("== TEST 17: cut composes with clearance - bottom 0, sides/top shrunk ==")
rc, so, se = run([st15, st15o, "--attach", "0,0,0", "--cut-below-attach", "--clearance", "1.5", "--max-tris", "0"])
check("exit 0", rc == 0, se)
r = json.loads(so); bb = bbox(read_binary_stl(st15o))
check("bottom exactly 0", abs(bb[2]) < 1e-6, str(bb))
check("sides in 1.5", abs(bb[0] + 13.5) < 1e-3 and abs(bb[3] - 13.5) < 1e-3, str(bb))
check("top down 1.5", abs(bb[5] - 8.5) < 1e-3, str(bb))
check("still closed", r["topologyOut"]["closed"] is True, so)

print("== TEST 18: hole repair closes an open mesh by default ==")
# box with two triangles removed: a hole in the top face and one in a side
st18 = os.path.join(D, "rep18.stl"); st18o = os.path.join(D, "rep18_out.stl")
t18 = box(-10,-10,0, 10,10,20)
del t18[3]   # top face triangle
del t18[6]   # side face triangle
write_binary_stl(st18, t18)
rc, so, se = run([st18, st18o, "--max-tris", "0"])
check("exit 0", rc == 0, se)
r = json.loads(so)
check("input open", r["topologyIn"]["closed"] is False, so)
check("repair filled loops", r["holesFilled"] >= 1, so)
check("output closed", r["topologyOut"]["closed"] is True and r["topologyOut"]["holes"] == 0, so)
check("bbox unchanged", bbox(read_binary_stl(st18o)) == (-10.0,-10.0,0.0,10.0,10.0,20.0), so)

print("== TEST 19: --no-repair leaves the export's holes alone and warns ==")
rc, so, se = run([st18, st18o, "--max-tris", "0", "--no-repair"])
check("exit 0", rc == 0, se)
r = json.loads(so)
check("nothing filled", r["holesFilled"] == 0, so)
check("output still open", r["topologyOut"]["closed"] is False, so)
check("warns not closed", any("NOT closed" in w for w in r["warnings"]), so)

print()
print("FAILURES: " + (", ".join(fails) if fails else "none"))
sys.exit(1 if fails else 0)
