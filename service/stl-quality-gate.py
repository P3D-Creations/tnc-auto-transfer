# Deep STL quality gate, modeled on what a strict importer (the TNC 640's
# fixture/DCM "quality requirements" check) can reject that a simple
# closed/manifold test misses:
#
#   1. triangle budget (20,000 for ASCII on the TNC 640)
#   2. closed (no boundary edges) and manifold (no 3+-face edges)
#   3. CONSISTENT ORIENTATION: every shared edge traversed once in each
#      direction (edge-use counting alone cannot see two neighbours wound
#      the same way)
#   4. degenerate triangles at float32 precision (STL is float32 on disk:
#      a triangle that is fine in doubles can collapse when written)
#   5. duplicate triangles (same three vertices, either winding)
#   6. stored facet normal agrees with the winding (ASCII only)
#   7. self-intersections: triangle pairs that penetrate each other
#      (grid-accelerated exact test, shared-vertex contacts excluded)
#
# Usage: python stl-quality-gate.py file.stl [file2.stl ...] [--no-selfint]

import sys, struct, math
from collections import defaultdict

def read_stl(path):
    data = open(path, "rb").read()
    if len(data) >= 84:
        n = struct.unpack("<I", data[80:84])[0]
        if len(data) == 84 + 50 * n and not data[:5].lower().startswith(b"solid"):
            return _read_bin(data, n), None
        if len(data) == 84 + 50 * n:
            return _read_bin(data, n), None
    return _read_ascii(data)

def _read_bin(data, n):
    tris = []
    o = 84
    for _ in range(n):
        o += 12
        t = []
        for _ in range(3):
            t.append(struct.unpack("<3f", data[o:o+12])); o += 12
        o += 2
        tris.append((t, None))
    return tris

def _read_ascii(data):
    tris = []
    normals = []
    cur = []
    norm = None
    for line in data.decode("utf-8", "replace").splitlines():
        w = line.split()
        if not w: continue
        if w[0] == "facet" and len(w) >= 5:
            norm = (float(w[2]), float(w[3]), float(w[4]))
        elif w[0] == "vertex":
            cur.append((float(w[1]), float(w[2]), float(w[3])))
            if len(cur) == 3:
                tris.append((cur, norm)); cur = []
    return tris, True

def f32(v): return struct.unpack("<f", struct.pack("<f", v))[0]

def sub(a,b): return (a[0]-b[0], a[1]-b[1], a[2]-b[2])
def cross(a,b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def dot(a,b): return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]
def norm3(a):
    l = math.sqrt(dot(a,a))
    return (a[0]/l, a[1]/l, a[2]/l) if l > 0 else (0.0,0.0,0.0)

def tri_tri_intersect(p, q):
    # Exact-ish Moller test: do triangles p and q properly intersect?
    # Touching at shared vertices/edges is excluded by the caller.
    n1 = cross(sub(p[1],p[0]), sub(p[2],p[0]))
    d1 = -dot(n1, p[0])
    dq = [dot(n1, v) + d1 for v in q]
    eps = 1e-9 * max(1.0, max(abs(x) for v in p+q for x in v))
    if all(d > eps for d in dq) or all(d < -eps for d in dq): return False
    n2 = cross(sub(q[1],q[0]), sub(q[2],q[0]))
    d2 = -dot(n2, q[0])
    dp = [dot(n2, v) + d2 for v in p]
    if all(d > eps for d in dp) or all(d < -eps for d in dp): return False
    if all(abs(d) <= eps for d in dq):
        return False   # coplanar: treated as contact, not penetration
    # interval overlap on the intersection line
    D = cross(n1, n2)
    ax = max(range(3), key=lambda i: abs(D[i]))
    def interval(tv, td):
        pts = []
        for i in range(3):
            j = (i+1) % 3
            a, b = td[i], td[j]
            if (a > eps and b < -eps) or (a < -eps and b > eps):
                t = a / (a - b)
                pts.append(tv[i][ax] + t * (tv[j][ax] - tv[i][ax]))
            elif abs(a) <= eps:
                pts.append(tv[i][ax])
        if len(pts) < 2: return None
        return min(pts), max(pts)
    i1 = interval(p, dp); i2 = interval(q, dq)
    if not i1 or not i2: return False
    lo = max(i1[0], i2[0]); hi = min(i1[1], i2[1])
    span = max(i1[1]-i1[0], i2[1]-i2[0], 1e-12)
    return (hi - lo) > 1e-6 * span + eps

def check(path, do_selfint=True):
    tris_raw, is_ascii = read_stl(path)
    print("== %s ==" % path)
    print("  triangles: %d%s" % (len(tris_raw), " (over 20000 ASCII limit!)" if len(tris_raw) > 20000 else ""))

    # weld exactly at float32 (what the control sees)
    vid = {}
    verts = []
    tris = []
    degen32 = 0
    for t, _ in tris_raw:
        ids = []
        for v in t:
            kv = (f32(v[0]), f32(v[1]), f32(v[2]))
            i = vid.get(kv)
            if i is None:
                i = len(verts); vid[kv] = i; verts.append(kv)
            ids.append(i)
        if ids[0] == ids[1] or ids[1] == ids[2] or ids[0] == ids[2]:
            degen32 += 1; continue
        a, b, c = (verts[i] for i in ids)
        if dot(cross(sub(b,a), sub(c,a)), cross(sub(b,a), sub(c,a))) == 0.0:
            degen32 += 1; continue
        tris.append(tuple(ids))
    print("  degenerate@float32: %d" % degen32)

    dup = defaultdict(int)
    for t in tris: dup[tuple(sorted(t))] += 1
    dups = sum(c - 1 for c in dup.values() if c > 1)
    print("  duplicate triangles: %d" % dups)

    edges = defaultdict(int)       # directed
    for a, b, c in tris:
        for e in ((a,b),(b,c),(c,a)): edges[e] += 1
    boundary = nonmanifold = misoriented = 0
    seen = set()
    misedges = []
    for (a, b), n in edges.items():
        if (b, a) in seen or (a, b) in seen: continue
        seen.add((a, b))
        m = edges.get((b, a), 0)
        tot = n + m
        if tot == 1: boundary += 1
        elif tot > 2: nonmanifold += 1
        elif n != 1 or m != 1:
            misoriented += 1   # two faces, same direction
            if len(misedges) < 10: misedges.append((a, b))
    print("  boundary edges: %d" % boundary)
    print("  non-manifold edges: %d" % nonmanifold)
    print("  MISORIENTED shared edges (same winding both sides): %d" % misoriented)
    for a, b in misedges:
        print("    %r -> %r" % (verts[a], verts[b]))

    # connected components (separate shells / floating bodies)
    parent = list(range(len(verts)))
    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]; x = parent[x]
        return x
    for a, b, c in tris:
        ra, rb, rc = find(a), find(b), find(c)
        parent[rb] = ra; parent[find(rc)] = find(ra)
    comp = defaultdict(int)
    for t in tris: comp[find(t[0])] += 1
    sizes = sorted(comp.values(), reverse=True)
    print("  shells (separate bodies): %d  sizes: %s" % (len(sizes), sizes[:12]))

    if is_ascii:
        badnorm = 0
        for t, sn in tris_raw:
            if sn is None: continue
            g = norm3(cross(sub(t[1],t[0]), sub(t[2],t[0])))
            if g == (0.0,0.0,0.0): continue
            if dot(g, sn) < 0.9 and math.sqrt(dot(sn,sn)) > 0.5:
                badnorm += 1
        print("  facet normals disagreeing with winding: %d" % badnorm)

    if do_selfint:
        # grid-accelerated triangle-triangle intersection
        lo = [min(v[i] for v in verts) for i in range(3)]
        hi = [max(v[i] for v in verts) for i in range(3)]
        diag = math.sqrt(sum((hi[i]-lo[i])**2 for i in range(3)))
        ncell = max(1, int((len(tris) / 4.0) ** (1.0/3.0)))
        cell = [max((hi[i]-lo[i]) / ncell, diag*1e-9, 1e-12) for i in range(3)]
        grid = defaultdict(list)
        boxes = []
        for ti, t in enumerate(tris):
            pv = [verts[i] for i in t]
            bl = [min(v[i] for v in pv) for i in range(3)]
            bh = [max(v[i] for v in pv) for i in range(3)]
            boxes.append((bl, bh))
            r = [range(int((bl[i]-lo[i])/cell[i]), int((bh[i]-lo[i])/cell[i])+1) for i in range(3)]
            for x in r[0]:
                for y in r[1]:
                    for z in r[2]:
                        grid[(x,y,z)].append(ti)
        hits = []
        tested = set()
        for cellts in grid.values():
            for ii in range(len(cellts)):
                for jj in range(ii+1, len(cellts)):
                    i, j = cellts[ii], cellts[jj]
                    if i > j: i, j = j, i
                    if (i, j) in tested: continue
                    tested.add((i, j))
                    if set(tris[i]) & set(tris[j]): continue   # adjacency contact
                    bi, bj = boxes[i], boxes[j]
                    if any(bi[1][k] < bj[0][k] or bj[1][k] < bi[0][k] for k in range(3)): continue
                    pv = [verts[v] for v in tris[i]]
                    qv = [verts[v] for v in tris[j]]
                    if tri_tri_intersect(pv, qv):
                        hits.append((i, j))
                        if len(hits) >= 50: break
                if len(hits) >= 50: break
            if len(hits) >= 50: break
        print("  self-intersections: %d%s" % (len(hits), " (stopped at 50)" if len(hits) >= 50 else ""))
        for i, j in hits[:8]:
            print("    tri %d vs tri %d" % (i, j))
            for v in tris[i]: print("      A %r" % (verts[v],))
            for v in tris[j]: print("      B %r" % (verts[v],))
    print()

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    selfint = "--no-selfint" not in sys.argv
    for p in args:
        check(p, selfint)
