// ============================================================================
// TNCWatcher-StlPrep
//
// Prepares an STL for import into a Heidenhain control:
//   1. Reads binary or ASCII STL, validating that the file is COMPLETE
//      (binary STL size must equal 84 + 50*triangleCount - a truncated write
//      fails this deterministically, no timing guesswork needed).
//   2. Welds the triangle soup into shared vertices (STL has no topology).
//   3. Decimates to a triangle budget (default 19500, under the control's
//      20000 limit) using quadric error metric edge collapse
//      (Garland-Heckbert), which preserves shape far better than clustering.
//   4. For a FIXTURE, re-origins the mesh about the attach point supplied by
//      the post (v' = v - A). The control places a fixture by putting the
//      mesh's (0,0,0) onto its own fixture attach location, so this is
//      required, not cosmetic. Pure translation - no rotation, no mirroring.
//   5. Optionally shrinks the mesh about that (now origin) attach point so
//      every face moves inward by a set clearance, keeping DCM from tripping.
//      Geometry below the attach plane keeps its Z: pullstuds and bolt heads
//      have to stay where the machine expects them.
//   6. Writes a binary STL and prints a JSON report to stdout.
//
// Stock and part meshes get decimation ONLY - never re-origined, never scaled.
//
// Build with service\Build-StlPrep.cmd (in-box C# compiler, no SDK needed).
// C# 5 syntax only - no string interpolation, tuples, or out-var.
//
// Usage:
//   TNCWatcher-StlPrep.exe <input.stl> <output.stl> [options]
//     --max-tris N       Triangle budget (default 19500; 0 = no decimation)
//     --clearance MM     Shrink so each face moves inward MM (default 0 = none)
//     --attach x,y,z     Scale anchor. Default: bottom-centre of bounding box.
//     --quiet            Suppress the JSON report
// Exit codes: 0 ok, 1 bad usage, 2 unreadable/incomplete input, 3 write failure
// ============================================================================

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

// ---------------------------------------------------------------------------

struct Vec3
{
    public double X, Y, Z;
    public Vec3(double x, double y, double z) { X = x; Y = y; Z = z; }

    public static Vec3 operator -(Vec3 a, Vec3 b) { return new Vec3(a.X - b.X, a.Y - b.Y, a.Z - b.Z); }
    public static Vec3 operator +(Vec3 a, Vec3 b) { return new Vec3(a.X + b.X, a.Y + b.Y, a.Z + b.Z); }
    public static Vec3 operator *(Vec3 a, double s) { return new Vec3(a.X * s, a.Y * s, a.Z * s); }

    public Vec3 Cross(Vec3 b) { return new Vec3(Y * b.Z - Z * b.Y, Z * b.X - X * b.Z, X * b.Y - Y * b.X); }
    public double Dot(Vec3 b) { return X * b.X + Y * b.Y + Z * b.Z; }
    public double Length() { return Math.Sqrt(X * X + Y * Y + Z * Z); }

    public Vec3 Normalized()
    {
        double l = Length();
        if (l < 1e-20) return new Vec3(0, 0, 0);
        return new Vec3(X / l, Y / l, Z / l);
    }
}

// Symmetric 4x4 quadric, stored as its 10 unique terms.
struct Quadric
{
    public double A2, AB, AC, AD, B2, BC, BD, C2, CD, D2;

    // Quadric of the plane (a,b,c,d) with a^2+b^2+c^2 = 1, weighted by area.
    public static Quadric FromPlane(double a, double b, double c, double d, double w)
    {
        Quadric q;
        q.A2 = a * a * w; q.AB = a * b * w; q.AC = a * c * w; q.AD = a * d * w;
        q.B2 = b * b * w; q.BC = b * c * w; q.BD = b * d * w;
        q.C2 = c * c * w; q.CD = c * d * w;
        q.D2 = d * d * w;
        return q;
    }

    public static Quadric operator +(Quadric x, Quadric y)
    {
        Quadric q;
        q.A2 = x.A2 + y.A2; q.AB = x.AB + y.AB; q.AC = x.AC + y.AC; q.AD = x.AD + y.AD;
        q.B2 = x.B2 + y.B2; q.BC = x.BC + y.BC; q.BD = x.BD + y.BD;
        q.C2 = x.C2 + y.C2; q.CD = x.CD + y.CD;
        q.D2 = x.D2 + y.D2;
        return q;
    }

    // v^T Q v  - squared distance to the set of planes this quadric represents.
    public double Error(Vec3 v)
    {
        return A2 * v.X * v.X + 2 * AB * v.X * v.Y + 2 * AC * v.X * v.Z + 2 * AD * v.X
             + B2 * v.Y * v.Y + 2 * BC * v.Y * v.Z + 2 * BD * v.Y
             + C2 * v.Z * v.Z + 2 * CD * v.Z
             + D2;
    }

    // Position minimising Error(). Returns false if the system is singular.
    public bool Optimal(out Vec3 p)
    {
        double det = A2 * (B2 * C2 - BC * BC)
                   - AB * (AB * C2 - BC * AC)
                   + AC * (AB * BC - B2 * AC);

        if (Math.Abs(det) < 1e-12) { p = new Vec3(0, 0, 0); return false; }

        double inv = 1.0 / det;
        // Solve [A2 AB AC; AB B2 BC; AC BC C2] * p = -[AD; BD; CD]
        double x = -inv * (AD * (B2 * C2 - BC * BC) - BD * (AB * C2 - BC * AC) + CD * (AB * BC - B2 * AC));
        double y = -inv * (-AD * (AB * C2 - AC * BC) + BD * (A2 * C2 - AC * AC) - CD * (A2 * BC - AB * AC));
        double z = -inv * (AD * (AB * BC - AC * B2) - BD * (A2 * BC - AC * AB) + CD * (A2 * B2 - AB * AB));

        p = new Vec3(x, y, z);
        return true;
    }
}

// ---------------------------------------------------------------------------

// Writes a one-line status to a file so a caller can show signs of life while
// a very dense mesh is being processed. Overwrites in place, throttled, and
// never throws - progress reporting must not break the conversion.
static class Prog
{
    static string path;
    static DateTime last = DateTime.MinValue;

    public static void Init(string p) { path = p; }

    public static void Set(string text) { Write(text, false); }
    public static void SetNow(string text) { Write(text, true); }

    static void Write(string text, bool force)
    {
        if (path == null) return;
        if (!force && (DateTime.Now - last).TotalMilliseconds < 400) return;
        last = DateTime.Now;
        try { File.WriteAllText(path, text); } catch { }
    }
}

// Splits a welded mesh into connected components and discards the ones that
// cannot affect a collision check: sealed internal voids and stray specks.
//
// An in-process stock mesh carries a lot of geometry the machine never touches
// - cavities left by earlier operations, detached slivers from the mesher.
// Removing them BEFORE decimation spends the triangle budget on the outer
// surface that actually matters instead of on detail nothing can reach.
static class Shells
{
    public static Mesh Prune(Mesh m, double speckFraction, out int specks, out int voids)
    {
        specks = 0; voids = 0;
        int nv = m.Verts.Count, nt = m.TriangleCount;
        if (nt == 0) return m;

        int[] parent = new int[nv];
        for (int i = 0; i < nv; i++) parent[i] = i;
        for (int t = 0; t < nt; t++)
        {
            Union(parent, m.Tris[t * 3], m.Tris[t * 3 + 1]);
            Union(parent, m.Tris[t * 3 + 1], m.Tris[t * 3 + 2]);
        }

        Dictionary<int, int> idx = new Dictionary<int, int>();
        List<List<int>> comps = new List<List<int>>();
        for (int t = 0; t < nt; t++)
        {
            int r = Find(parent, m.Tris[t * 3]);
            int ci;
            if (!idx.TryGetValue(r, out ci)) { ci = comps.Count; idx[r] = ci; comps.Add(new List<int>()); }
            comps[ci].Add(t);
        }
        if (comps.Count <= 1) return m;

        int n = comps.Count;
        Vec3[] lo = new Vec3[n], hi = new Vec3[n];
        double[] diag = new double[n];
        for (int c = 0; c < n; c++)
        {
            Vec3 mn = new Vec3(double.MaxValue, double.MaxValue, double.MaxValue);
            Vec3 mx = new Vec3(double.MinValue, double.MinValue, double.MinValue);
            foreach (int t in comps[c])
                for (int k = 0; k < 3; k++)
                {
                    Vec3 q = m.Verts[m.Tris[t * 3 + k]];
                    if (q.X < mn.X) mn.X = q.X; if (q.X > mx.X) mx.X = q.X;
                    if (q.Y < mn.Y) mn.Y = q.Y; if (q.Y > mx.Y) mx.Y = q.Y;
                    if (q.Z < mn.Z) mn.Z = q.Z; if (q.Z > mx.Z) mx.Z = q.Z;
                }
            lo[c] = mn; hi[c] = mx; diag[c] = (mx - mn).Length();
        }

        Vec3 wmn, wmx; m.Bounds(out wmn, out wmx);
        double worldDiag = (wmx - wmn).Length();

        bool[] keep = new bool[n];
        for (int c = 0; c < n; c++) keep[c] = true;

        for (int c = 0; c < n; c++)
        {
            if (worldDiag > 0 && diag[c] < worldDiag * speckFraction) { keep[c] = false; specks++; continue; }
            for (int o = 0; o < n; o++)
            {
                if (o == c || diag[o] <= diag[c]) continue;
                if (lo[c].X > lo[o].X && hi[c].X < hi[o].X &&
                    lo[c].Y > lo[o].Y && hi[c].Y < hi[o].Y &&
                    lo[c].Z > lo[o].Z && hi[c].Z < hi[o].Z)
                { keep[c] = false; voids++; break; }
            }
        }

        Mesh outM = new Mesh();
        int[] remap = new int[nv];
        for (int i = 0; i < nv; i++) remap[i] = -1;
        for (int c = 0; c < n; c++)
        {
            if (!keep[c]) continue;
            foreach (int t in comps[c])
                for (int k = 0; k < 3; k++)
                {
                    int vi = m.Tris[t * 3 + k];
                    if (remap[vi] < 0) { remap[vi] = outM.Verts.Count; outM.Verts.Add(m.Verts[vi]); }
                    outM.Tris.Add(remap[vi]);
                }
        }
        return outM.TriangleCount > 0 ? outM : m;
    }

    static int Find(int[] p, int x) { while (p[x] != x) { p[x] = p[p[x]]; x = p[x]; } return x; }
    static void Union(int[] p, int a, int b) { int ra = Find(p, a), rb = Find(p, b); if (ra != rb) p[rb] = ra; }
}

// ---------------------------------------------------------------------------

// Watertightness / manifold check. The control needs a closed mesh, so this
// runs on the way in and again on the way out: it says whether the incoming
// export was already broken, and whether processing made anything worse.
//
//   boundary edges  - edges with a single face: actual holes
//   non-manifold    - edges with more than two faces: shells touching, or
//                     faces stacked on top of one another
static class Topo
{
    public class Report
    {
        public int Boundary, NonManifold, Degenerate, Triangles;
        // Watertight/closed means no boundary edges: the surface bounds a
        // volume. Non-manifold edges are a separate, lesser condition - two
        // shells meeting along a seam is still closed, and Fusion exports
        // arrive that way - so they are reported but do not clear this flag.
        public bool Closed { get { return Boundary == 0 && Degenerate == 0; } }
        public bool Manifold { get { return NonManifold == 0; } }
        public string Json()
        {
            return "{\"closed\":" + (Closed ? "true" : "false") +
                   ",\"manifold\":" + (Manifold ? "true" : "false") +
                   ",\"holes\":" + Boundary +
                   ",\"nonManifold\":" + NonManifold +
                   ",\"degenerate\":" + Degenerate + "}";
        }
        public string Text()
        {
            if (Closed && Manifold) return "watertight and manifold";
            if (Closed) return "closed (watertight), " + NonManifold + " non-manifold edge(s)";
            return "NOT closed - " + Boundary + " hole edge(s), " + NonManifold +
                   " non-manifold, " + Degenerate + " degenerate";
        }
    }

    public static Report Check(Mesh m)
    {
        Report r = new Report();
        r.Triangles = m.TriangleCount;
        Dictionary<long, int> edge = new Dictionary<long, int>();
        for (int t = 0; t < m.Tris.Count; t += 3)
        {
            int a = m.Tris[t], b = m.Tris[t + 1], c = m.Tris[t + 2];
            if (a == b || b == c || a == c) { r.Degenerate++; continue; }
            Bump(edge, a, b); Bump(edge, b, c); Bump(edge, c, a);
        }
        foreach (KeyValuePair<long, int> kv in edge)
        {
            if (kv.Value == 1) r.Boundary++;
            else if (kv.Value > 2) r.NonManifold++;
        }
        return r;
    }

    static void Bump(Dictionary<long, int> d, int a, int b)
    {
        int lo = Math.Min(a, b), hi = Math.Max(a, b);
        long k = ((long)lo << 32) | (uint)hi;
        int v; d.TryGetValue(k, out v); d[k] = v + 1;
    }
}

class Mesh
{
    public List<Vec3> Verts = new List<Vec3>();
    public List<int> Tris = new List<int>();   // flat: 3 indices per triangle

    public int TriangleCount { get { return Tris.Count / 3; } }

    public void Bounds(out Vec3 min, out Vec3 max)
    {
        if (Verts.Count == 0) { min = new Vec3(0, 0, 0); max = new Vec3(0, 0, 0); return; }
        double n = double.MaxValue, p = double.MinValue;
        min = new Vec3(n, n, n); max = new Vec3(p, p, p);
        for (int i = 0; i < Verts.Count; i++)
        {
            Vec3 v = Verts[i];
            if (v.X < min.X) min.X = v.X; if (v.X > max.X) max.X = v.X;
            if (v.Y < min.Y) min.Y = v.Y; if (v.Y > max.Y) max.Y = v.Y;
            if (v.Z < min.Z) min.Z = v.Z; if (v.Z > max.Z) max.Z = v.Z;
        }
    }
}

// ---------------------------------------------------------------------------

static class StlIO
{
    // Reads binary or ASCII STL. Throws IOException with a clear reason if the
    // file is incomplete - the caller treats that as "not finished writing yet".
    public static Mesh Read(string path)
    {
        byte[] data = File.ReadAllBytes(path);
        if (data.Length < 15) throw new IOException("File too small to be an STL (" + data.Length + " bytes)");

        // Binary STL: 80-byte header, uint32 count, 50 bytes per triangle.
        if (data.Length >= 84)
        {
            uint count = BitConverter.ToUInt32(data, 80);
            long expected = 84L + 50L * count;
            if (expected == data.Length) return ReadBinary(data, (int)count);

            // Size mismatch: either ASCII, or a binary file still being written.
            if (!LooksAscii(data))
            {
                throw new IOException("Incomplete binary STL: header declares " + count +
                                      " triangles (expect " + expected + " bytes) but file is " +
                                      data.Length + " bytes");
            }
        }

        if (LooksAscii(data)) return ReadAscii(data);
        throw new IOException("Unrecognised STL format");
    }

    static bool LooksAscii(byte[] d)
    {
        if (d.Length < 5) return false;
        string head = Encoding.ASCII.GetString(d, 0, Math.Min(80, d.Length)).TrimStart();
        return head.StartsWith("solid", StringComparison.OrdinalIgnoreCase);
    }

    static Mesh ReadBinary(byte[] d, int count)
    {
        Mesh m = new Mesh();
        m.Verts.Capacity = count * 3;
        m.Tris.Capacity = count * 3;
        int o = 84;
        for (int i = 0; i < count; i++)
        {
            o += 12; // skip the stored normal; recomputed from winding
            for (int k = 0; k < 3; k++)
            {
                double x = BitConverter.ToSingle(d, o); o += 4;
                double y = BitConverter.ToSingle(d, o); o += 4;
                double z = BitConverter.ToSingle(d, o); o += 4;
                m.Tris.Add(m.Verts.Count);
                m.Verts.Add(new Vec3(x, y, z));
            }
            o += 2; // attribute byte count
        }
        return m;
    }

    static Mesh ReadAscii(byte[] d)
    {
        Mesh m = new Mesh();
        string text = Encoding.ASCII.GetString(d);
        if (text.IndexOf("endsolid", StringComparison.OrdinalIgnoreCase) < 0)
            throw new IOException("Incomplete ASCII STL: no 'endsolid' terminator");

        char[] ws = new char[] { ' ', '\t', '\r', '\n' };
        string[] tok = text.Split(ws, StringSplitOptions.RemoveEmptyEntries);
        for (int i = 0; i < tok.Length; i++)
        {
            if (!tok[i].Equals("vertex", StringComparison.OrdinalIgnoreCase)) continue;
            if (i + 3 >= tok.Length) break;
            double x = double.Parse(tok[i + 1], CultureInfo.InvariantCulture);
            double y = double.Parse(tok[i + 2], CultureInfo.InvariantCulture);
            double z = double.Parse(tok[i + 3], CultureInfo.InvariantCulture);
            m.Tris.Add(m.Verts.Count);
            m.Verts.Add(new Vec3(x, y, z));
            i += 3;
        }
        if (m.Tris.Count % 3 != 0) throw new IOException("Incomplete ASCII STL: dangling triangle");
        return m;
    }

    // ASCII STL. Larger than binary (~4.6x) but line-based, which matters:
    // the TNC 640 rejects a long run of bytes with no line break during PUT
    // with "E20001714: Formatting error", even in /b binary mode. A 1.5MB
    // binary STL fails; the same 1.5MB with newlines every 80 bytes succeeds,
    // as does a 25MB NC program. So meshes go as text.
    public static void WriteAscii(string path, Mesh m)
    {
        string tmp = path + ".tmp";
        using (FileStream fs = new FileStream(tmp, FileMode.Create, FileAccess.Write))
        using (StreamWriter w = new StreamWriter(fs, new UTF8Encoding(false)))
        {
            w.NewLine = "\n";
            w.WriteLine("solid TNCWatcher");
            int nt = m.TriangleCount;
            for (int t = 0; t < nt; t++)
            {
                Vec3 a = m.Verts[m.Tris[t * 3]];
                Vec3 b = m.Verts[m.Tris[t * 3 + 1]];
                Vec3 c = m.Verts[m.Tris[t * 3 + 2]];
                Vec3 n = (b - a).Cross(c - a).Normalized();
                w.WriteLine("  facet normal " + A(n.X) + " " + A(n.Y) + " " + A(n.Z));
                w.WriteLine("    outer loop");
                w.WriteLine("      vertex " + A(a.X) + " " + A(a.Y) + " " + A(a.Z));
                w.WriteLine("      vertex " + A(b.X) + " " + A(b.Y) + " " + A(b.Z));
                w.WriteLine("      vertex " + A(c.X) + " " + A(c.Y) + " " + A(c.Z));
                w.WriteLine("    endloop");
                w.WriteLine("  endfacet");
            }
            w.WriteLine("endsolid TNCWatcher");
        }
        if (File.Exists(path)) File.Delete(path);
        File.Move(tmp, path);
    }

    static string A(double v)
    {
        return ((float)v).ToString("0.000000e+00", CultureInfo.InvariantCulture);
    }

    public static void WriteBinary(string path, Mesh m)
    {
        // Write to a temp file then move, so a reader never sees a partial STL.
        string tmp = path + ".tmp";
        using (FileStream fs = new FileStream(tmp, FileMode.Create, FileAccess.Write))
        using (BinaryWriter w = new BinaryWriter(fs))
        {
            byte[] header = new byte[80];
            byte[] tag = Encoding.ASCII.GetBytes("TNCWatcher-StlPrep");
            Array.Copy(tag, header, Math.Min(tag.Length, 80));
            w.Write(header);

            int nt = m.TriangleCount;
            w.Write((uint)nt);
            for (int t = 0; t < nt; t++)
            {
                Vec3 a = m.Verts[m.Tris[t * 3]];
                Vec3 b = m.Verts[m.Tris[t * 3 + 1]];
                Vec3 c = m.Verts[m.Tris[t * 3 + 2]];
                Vec3 n = (b - a).Cross(c - a).Normalized();
                w.Write((float)n.X); w.Write((float)n.Y); w.Write((float)n.Z);
                w.Write((float)a.X); w.Write((float)a.Y); w.Write((float)a.Z);
                w.Write((float)b.X); w.Write((float)b.Y); w.Write((float)b.Z);
                w.Write((float)c.X); w.Write((float)c.Y); w.Write((float)c.Z);
                w.Write((ushort)0);
            }
        }
        if (File.Exists(path)) File.Delete(path);
        File.Move(tmp, path);
    }
}

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

// Cuts a mesh at the attach plane and caps the hole flat. Fixture geometry
// below the attach point (pullstuds, retention knobs, bolt heads) sits inside
// the machine's own chuck/table model on the control, so DCM flags collisions
// against hardware that is really the clamping system itself. The cut removes
// everything below the plane and closes the openings so the mesh stays a
// closed volume.
//
// Requires a welded mesh (shared vertex indices) so that the intersection
// point of an edge is computed once and shared by both triangles on it -
// that is what keeps the cut seam free of cracks.
static class PlaneCut
{
    public static Mesh CutBelowZ(Mesh m, double planeZ, double eps,
                                 out int removedTris, out int capTris, out int capLoops,
                                 List<string> warn)
    {
        removedTris = 0; capTris = 0; capLoops = 0;

        // Work in a frame where the plane is exactly z = 0, and snap vertices
        // within eps onto it so slivers cannot form along the seam.
        List<Vec3> pos = new List<Vec3>(m.Verts.Count);
        for (int i = 0; i < m.Verts.Count; i++)
        {
            Vec3 v = m.Verts[i];
            double z = v.Z - planeZ;
            if (Math.Abs(z) < eps) z = 0;
            pos.Add(new Vec3(v.X, v.Y, z));
        }

        Mesh outM = new Mesh();
        outM.Verts.AddRange(pos);
        Dictionary<long, int> cutPoint = new Dictionary<long, int>();

        for (int t = 0; t < m.Tris.Count; t += 3)
        {
            int i0 = m.Tris[t], i1 = m.Tris[t + 1], i2 = m.Tris[t + 2];
            double z0 = outM.Verts[i0].Z, z1 = outM.Verts[i1].Z, z2 = outM.Verts[i2].Z;

            if (z0 == 0 && z1 == 0 && z2 == 0)
            {
                // Coplanar with the cut. A DOWN-facing triangle here is real
                // exterior bottom surface - keep it. An UP-facing one is the
                // ceiling of geometry that just got cut away (e.g. the top of
                // a pullstud); its volume is gone, so drop it - if a hole
                // results, the capping pass below closes it facing down.
                Vec3 pa = outM.Verts[i0], pb = outM.Verts[i1], pc = outM.Verts[i2];
                double nz = (pb.X - pa.X) * (pc.Y - pa.Y) - (pb.Y - pa.Y) * (pc.X - pa.X);
                if (nz > 0) { removedTris++; continue; }
                outM.Tris.Add(i0); outM.Tris.Add(i1); outM.Tris.Add(i2);
                continue;
            }
            if (z0 >= 0 && z1 >= 0 && z2 >= 0)
            {
                outM.Tris.Add(i0); outM.Tris.Add(i1); outM.Tris.Add(i2);
                continue;
            }
            if (z0 <= 0 && z1 <= 0 && z2 <= 0) { removedTris++; continue; }

            // Straddles the plane: Sutherland-Hodgman clip against z >= 0.
            int[] idx = new int[] { i0, i1, i2 };
            List<int> poly = new List<int>(4);
            for (int k = 0; k < 3; k++)
            {
                int a = idx[k], b = idx[(k + 1) % 3];
                double za = outM.Verts[a].Z, zb = outM.Verts[b].Z;
                if (za >= 0) poly.Add(a);
                if ((za > 0 && zb < 0) || (za < 0 && zb > 0))
                    poly.Add(CutIdx(outM, cutPoint, a, b));
            }
            removedTris++;   // original triangle replaced by its clipped part
            for (int k = 1; k + 1 < poly.Count; k++)
            {
                if (poly[0] == poly[k] || poly[k] == poly[k + 1] || poly[0] == poly[k + 1]) continue;
                outM.Tris.Add(poly[0]); outM.Tris.Add(poly[k]); outM.Tris.Add(poly[k + 1]);
            }
        }

        // ---- cap the openings ----
        // Every hole the cut created shows up as a boundary edge (used by
        // exactly one triangle) whose endpoints lie on the plane.
        Dictionary<long, int> use = new Dictionary<long, int>();
        Dictionary<long, long> dir = new Dictionary<long, long>();   // undirected key -> packed directed edge
        for (int t = 0; t < outM.Tris.Count; t += 3)
        {
            for (int k = 0; k < 3; k++)
            {
                int a = outM.Tris[t + k], b = outM.Tris[t + (k + 1) % 3];
                long key = UKey(a, b);
                int c; use.TryGetValue(key, out c); use[key] = c + 1;
                if (c == 0) dir[key] = ((long)a << 32) | (uint)b;
            }
        }

        Dictionary<int, int> succ = new Dictionary<int, int>();
        foreach (KeyValuePair<long, int> kv in use)
        {
            if (kv.Value != 1) continue;
            long d = dir[kv.Key];
            int a = (int)(d >> 32), b = (int)(d & 0xFFFFFFFFL);
            if (Math.Abs(outM.Verts[a].Z) > eps || Math.Abs(outM.Verts[b].Z) > eps) continue;
            // The cap must oppose the surface winding, so walk b -> a.
            if (!succ.ContainsKey(b)) succ[b] = a;
        }

        HashSet<int> visited = new HashSet<int>();
        foreach (int start in new List<int>(succ.Keys))
        {
            if (visited.Contains(start)) continue;
            List<int> loop = new List<int>();
            int cur = start;
            bool closed = false;
            while (succ.ContainsKey(cur) && !visited.Contains(cur))
            {
                visited.Add(cur);
                loop.Add(cur);
                cur = succ[cur];
                if (cur == start) { closed = true; break; }
            }
            if (!closed || loop.Count < 3)
            {
                if (loop.Count >= 3) warn.Add("plane cut: an open boundary chain of " + loop.Count + " edges could not be closed into a loop; that hole is left uncapped");
                continue;
            }

            capLoops++;
            int before = outM.Tris.Count;
            Triangulate(outM, loop, warn);
            capTris += (outM.Tris.Count - before) / 3;
        }

        // Compact: drop the vertices whose triangles were cut away, or they
        // linger in the bounds and in the clearance pass as phantom geometry
        // below the plane. Restore the original frame while copying.
        Mesh packed = new Mesh();
        int[] remap = new int[outM.Verts.Count];
        for (int i = 0; i < remap.Length; i++) remap[i] = -1;
        for (int t = 0; t < outM.Tris.Count; t++)
        {
            int vi = outM.Tris[t];
            if (remap[vi] < 0)
            {
                remap[vi] = packed.Verts.Count;
                Vec3 v = outM.Verts[vi];
                packed.Verts.Add(new Vec3(v.X, v.Y, v.Z + planeZ));
            }
            packed.Tris.Add(remap[vi]);
        }
        return packed;
    }

    static int CutIdx(Mesh m, Dictionary<long, int> cache, int a, int b)
    {
        long key = UKey(a, b);
        int idx;
        if (cache.TryGetValue(key, out idx)) return idx;
        int lo = Math.Min(a, b), hi = Math.Max(a, b);
        Vec3 va = m.Verts[lo], vb = m.Verts[hi];
        double t = va.Z / (va.Z - vb.Z);
        Vec3 p = new Vec3(va.X + (vb.X - va.X) * t, va.Y + (vb.Y - va.Y) * t, 0);
        idx = m.Verts.Count;
        m.Verts.Add(p);
        cache[key] = idx;
        return idx;
    }

    static long UKey(int a, int b)
    {
        int lo = Math.Min(a, b), hi = Math.Max(a, b);
        return ((long)lo << 32) | (uint)hi;
    }

    // Ear clipping in the XY plane; falls back to a centroid fan when no ear
    // can be found (degenerate rims), which still closes the hole.
    static void Triangulate(Mesh m, List<int> loop, List<string> warn)
    {
        List<int> v = new List<int>(loop);

        double area = 0;
        for (int i = 0; i < v.Count; i++)
        {
            Vec3 p = m.Verts[v[i]], q = m.Verts[v[(i + 1) % v.Count]];
            area += p.X * q.Y - q.X * p.Y;
        }
        // Emit with the cap facing DOWN (-Z, outward from the solid above):
        // a loop that is CCW in XY fans into +Z normals, so reverse it.
        if (area > 0) v.Reverse();

        int guard = v.Count * v.Count + 16;
        while (v.Count > 3 && guard-- > 0)
        {
            bool clipped = false;
            for (int i = 0; i < v.Count; i++)
            {
                int ia = v[(i + v.Count - 1) % v.Count], ib = v[i], ic = v[(i + 1) % v.Count];
                Vec3 a = m.Verts[ia], b = m.Verts[ib], c = m.Verts[ic];
                double cross = (b.X - a.X) * (c.Y - a.Y) - (b.Y - a.Y) * (c.X - a.X);
                if (cross >= -1e-12) continue;   // reflex or collinear for CW winding

                bool inside = false;
                for (int j = 0; j < v.Count; j++)
                {
                    if (v[j] == ia || v[j] == ib || v[j] == ic) continue;
                    if (PointInTri(m.Verts[v[j]], a, b, c)) { inside = true; break; }
                }
                if (inside) continue;

                m.Tris.Add(ia); m.Tris.Add(ib); m.Tris.Add(ic);
                v.RemoveAt(i);
                clipped = true;
                break;
            }
            if (!clipped) break;
        }

        if (v.Count == 3)
        {
            m.Tris.Add(v[0]); m.Tris.Add(v[1]); m.Tris.Add(v[2]);
        }
        else if (v.Count > 3)
        {
            // Centroid fan fallback: not pretty on concave rims, but closed.
            warn.Add("plane cut: ear clipping stalled on a " + loop.Count + "-edge rim; capped with a centroid fan");
            double cx = 0, cy = 0;
            for (int i = 0; i < v.Count; i++) { cx += m.Verts[v[i]].X; cy += m.Verts[v[i]].Y; }
            Vec3 centre = new Vec3(cx / v.Count, cy / v.Count, m.Verts[v[0]].Z);
            int ci = m.Verts.Count;
            m.Verts.Add(centre);
            for (int i = 0; i < v.Count; i++)
            {
                m.Tris.Add(ci); m.Tris.Add(v[i]); m.Tris.Add(v[(i + 1) % v.Count]);
            }
        }
    }

    static bool PointInTri(Vec3 p, Vec3 a, Vec3 b, Vec3 c)
    {
        double d1 = Sign(p, a, b), d2 = Sign(p, b, c), d3 = Sign(p, c, a);
        bool neg = (d1 < 0) || (d2 < 0) || (d3 < 0);
        bool pos = (d1 > 0) || (d2 > 0) || (d3 > 0);
        return !(neg && pos);
    }

    static double Sign(Vec3 p, Vec3 a, Vec3 b)
    {
        return (p.X - a.X) * (b.Y - a.Y) - (b.X - a.X) * (p.Y - a.Y);
    }
}

// Exact identity of a triangle regardless of winding. A plain hash is not
// enough here: a collision would discard a genuine triangle and tear a hole in
// the mesh.
struct TriKey : IEquatable<TriKey>
{
    readonly int a, b, c;
    public TriKey(int x, int y, int z)
    {
        int t;
        if (x > y) { t = x; x = y; y = t; }
        if (y > z) { t = y; y = z; z = t; }
        if (x > y) { t = x; x = y; y = t; }
        a = x; b = y; c = z;
    }
    public bool Equals(TriKey o) { return a == o.a && b == o.b && c == o.c; }
    public override bool Equals(object o) { return o is TriKey && Equals((TriKey)o); }
    public override int GetHashCode()
    {
        unchecked { int h = a; h = h * 397 ^ b; h = h * 397 ^ c; return h; }
    }
}

static class Weld
{
    // STL is a triangle soup: every triangle carries its own copy of each
    // corner. Edge collapse needs shared vertices, so merge coincident ones.
    public static Mesh Run(Mesh src, double tol) { return Run(src, tol, false); }

    public static Mesh Run(Mesh src, double tol, bool dedupe)
    {
        Mesh m = new Mesh();
        Dictionary<long, List<int>> buckets = new Dictionary<long, List<int>>();
        int[] remap = new int[src.Verts.Count];
        double inv = 1.0 / tol;

        for (int i = 0; i < src.Verts.Count; i++)
        {
            Vec3 v = src.Verts[i];
            long kx = (long)Math.Floor(v.X * inv);
            long ky = (long)Math.Floor(v.Y * inv);
            long kz = (long)Math.Floor(v.Z * inv);
            int found = -1;

            // Check the cell and its neighbours so points either side of a cell
            // boundary still merge.
            for (int dx = -1; dx <= 1 && found < 0; dx++)
                for (int dy = -1; dy <= 1 && found < 0; dy++)
                    for (int dz = -1; dz <= 1 && found < 0; dz++)
                    {
                        long key = Hash(kx + dx, ky + dy, kz + dz);
                        List<int> cell;
                        if (!buckets.TryGetValue(key, out cell)) continue;
                        for (int j = 0; j < cell.Count; j++)
                        {
                            Vec3 o = m.Verts[cell[j]];
                            if (Math.Abs(o.X - v.X) <= tol && Math.Abs(o.Y - v.Y) <= tol && Math.Abs(o.Z - v.Z) <= tol)
                            { found = cell[j]; break; }
                        }
                    }

            if (found < 0)
            {
                found = m.Verts.Count;
                m.Verts.Add(v);
                long key = Hash(kx, ky, kz);
                List<int> cell;
                if (!buckets.TryGetValue(key, out cell)) { cell = new List<int>(); buckets[key] = cell; }
                cell.Add(found);
            }
            remap[i] = found;
        }

        // Drop degenerate AND duplicate triangles. Welding at a coarse tolerance
        // merges distinct vertices, which stacks several triangles onto the same
        // corners; left alone those pile up into edges carrying 4, 6, 18 faces
        // and destroy watertightness.
        HashSet<TriKey> seenTri = dedupe ? new HashSet<TriKey>() : null;
        for (int t = 0; t < src.Tris.Count; t += 3)
        {
            int a = remap[src.Tris[t]], b = remap[src.Tris[t + 1]], c = remap[src.Tris[t + 2]];
            if (a == b || b == c || a == c) continue;   // collapsed to nothing

            if (dedupe && !seenTri.Add(new TriKey(a, b, c))) continue;   // same three corners already present

            m.Tris.Add(a); m.Tris.Add(b); m.Tris.Add(c);
        }
        return m;
    }

    static long Hash(long x, long y, long z)
    {
        unchecked { return x * 73856093L ^ y * 19349663L ^ z * 83492791L; }
    }
}

// ---------------------------------------------------------------------------

class Decimator
{
    Vec3[] pos;
    Quadric[] quad;
    bool[] vDead;
    int[] tri;            // flat, 3 per triangle
    bool[] tDead;
    HashSet<int>[] vTris; // incident triangles per vertex
    int liveTris;

    class Cand { public double Cost; public int A, B; public Vec3 P; }

    List<Cand> heap = new List<Cand>();

    public bool PreserveExtents = true;
    Vec3 clampLo, clampHi;

    public Mesh Run(Mesh src, int target, out double maxDeviation)
    {
        src.Bounds(out clampLo, out clampHi);
        Build(src);
        maxDeviation = 0;

        // Seed the heap with every unique edge.
        HashSet<long> seen = new HashSet<long>();
        for (int t = 0; t < tri.Length; t += 3)
        {
            AddEdgeOnce(seen, tri[t], tri[t + 1]);
            AddEdgeOnce(seen, tri[t + 1], tri[t + 2]);
            AddEdgeOnce(seen, tri[t + 2], tri[t]);
        }
        Heapify();

        int startTris = liveTris;
        int spins = 0;
        while (liveTris > target && heap.Count > 0)
        {
            if ((++spins & 1023) == 0 && startTris > target)
            {
                double pct = 100.0 * (startTris - liveTris) / (double)(startTris - target);
                if (pct > 99.9) pct = 99.9;
                Prog.Set("decimating " + pct.ToString("0") + "% (" + liveTris + " triangles left)");
            }

            Cand c = Pop();
            if (c == null) break;
            if (vDead[c.A] || vDead[c.B]) continue;
            if (!AreAdjacent(c.A, c.B)) continue;

            // Lazy revalidation: the incident quadrics may have changed since
            // this entry was pushed, so recompute and re-queue if it got worse.
            Vec3 p; double cost;
            Evaluate(c.A, c.B, out p, out cost);
            if (cost > c.Cost * 1.0001 + 1e-12) { Push(new Cand { Cost = cost, A = c.A, B = c.B, P = p }); continue; }

            if (!LinkConditionOk(c.A, c.B)) continue;
            if (WouldFlip(c.A, c.B, p)) continue;

            double dev = Math.Sqrt(Math.Max(0, cost));
            if (dev > maxDeviation) maxDeviation = dev;

            Collapse(c.A, c.B, p);
        }

        return Compact();
    }

    void Build(Mesh src)
    {
        pos = src.Verts.ToArray();
        tri = src.Tris.ToArray();
        vDead = new bool[pos.Length];
        tDead = new bool[tri.Length / 3];
        quad = new Quadric[pos.Length];
        liveTris = tri.Length / 3;

        vTris = new HashSet<int>[pos.Length];
        for (int i = 0; i < pos.Length; i++) vTris[i] = new HashSet<int>();

        for (int t = 0; t < tri.Length; t += 3)
        {
            int f = t / 3;
            vTris[tri[t]].Add(f); vTris[tri[t + 1]].Add(f); vTris[tri[t + 2]].Add(f);

            Vec3 a = pos[tri[t]], b = pos[tri[t + 1]], c = pos[tri[t + 2]];
            Vec3 cr = (b - a).Cross(c - a);
            double area2 = cr.Length();
            if (area2 < 1e-18) continue;
            Vec3 n = cr * (1.0 / area2);
            double d = -n.Dot(a);
            Quadric q = Quadric.FromPlane(n.X, n.Y, n.Z, d, area2);
            quad[tri[t]] = quad[tri[t]] + q;
            quad[tri[t + 1]] = quad[tri[t + 1]] + q;
            quad[tri[t + 2]] = quad[tri[t + 2]] + q;
        }

        // Pin the outer extents. Vertices sitting on the model's bounding faces
        // define the silhouette the machine actually interacts with, so give
        // them a heavy quadric for that face: decimation may slide them along
        // the face but cannot pull the outside dimensions in.
        if (PreserveExtents)
        {
            Vec3 bmn, bmx;
            {
                Mesh tmp = new Mesh();
                tmp.Verts.AddRange(pos);
                tmp.Tris.AddRange(tri);
                tmp.Bounds(out bmn, out bmx);
            }
            double span = (bmx - bmn).Length();
            double eps = Math.Max(1e-9, span * 1e-4);
            double w = 1e4;
            for (int i = 0; i < pos.Length; i++)
            {
                Vec3 v = pos[i];
                if (Math.Abs(v.X - bmn.X) < eps) quad[i] = quad[i] + Quadric.FromPlane(1, 0, 0, -bmn.X, w);
                if (Math.Abs(v.X - bmx.X) < eps) quad[i] = quad[i] + Quadric.FromPlane(1, 0, 0, -bmx.X, w);
                if (Math.Abs(v.Y - bmn.Y) < eps) quad[i] = quad[i] + Quadric.FromPlane(0, 1, 0, -bmn.Y, w);
                if (Math.Abs(v.Y - bmx.Y) < eps) quad[i] = quad[i] + Quadric.FromPlane(0, 1, 0, -bmx.Y, w);
                if (Math.Abs(v.Z - bmn.Z) < eps) quad[i] = quad[i] + Quadric.FromPlane(0, 0, 1, -bmn.Z, w);
                if (Math.Abs(v.Z - bmx.Z) < eps) quad[i] = quad[i] + Quadric.FromPlane(0, 0, 1, -bmx.Z, w);
            }
        }

        // Constrain open boundaries so the silhouette of an open mesh holds.
        Dictionary<long, int> edgeUse = new Dictionary<long, int>();
        for (int t = 0; t < tri.Length; t += 3)
        {
            Bump(edgeUse, tri[t], tri[t + 1]);
            Bump(edgeUse, tri[t + 1], tri[t + 2]);
            Bump(edgeUse, tri[t + 2], tri[t]);
        }
        foreach (KeyValuePair<long, int> kv in edgeUse)
        {
            if (kv.Value != 1) continue;               // interior edge
            int a = (int)(kv.Key >> 32);
            int b = (int)(kv.Key & 0xFFFFFFFFL);
            Vec3 dir = (pos[b] - pos[a]);
            double len = dir.Length();
            if (len < 1e-15) continue;
            // Plane through the edge, perpendicular to the surface, heavily weighted.
            Vec3 anyN = FaceNormalContaining(a, b);
            Vec3 n = dir.Normalized().Cross(anyN).Normalized();
            double d = -n.Dot(pos[a]);
            Quadric q = Quadric.FromPlane(n.X, n.Y, n.Z, d, len * 1000.0);
            quad[a] = quad[a] + q;
            quad[b] = quad[b] + q;
        }
    }

    Vec3 FaceNormalContaining(int a, int b)
    {
        foreach (int f in vTris[a])
        {
            if (tDead[f]) continue;
            int i0 = tri[f * 3], i1 = tri[f * 3 + 1], i2 = tri[f * 3 + 2];
            if (i0 != b && i1 != b && i2 != b) continue;
            Vec3 n = (pos[i1] - pos[i0]).Cross(pos[i2] - pos[i0]).Normalized();
            if (n.Length() > 0.5) return n;
        }
        return new Vec3(0, 0, 1);
    }

    static void Bump(Dictionary<long, int> d, int a, int b)
    {
        long k = Key(a, b);
        int v;
        d.TryGetValue(k, out v);
        d[k] = v + 1;
    }

    static long Key(int a, int b)
    {
        int lo = Math.Min(a, b), hi = Math.Max(a, b);
        return ((long)lo << 32) | (uint)hi;
    }

    void AddEdgeOnce(HashSet<long> seen, int a, int b)
    {
        if (!seen.Add(Key(a, b))) return;
        Vec3 p; double cost;
        Evaluate(a, b, out p, out cost);
        heap.Add(new Cand { Cost = cost, A = a, B = b, P = p });
    }

    void Evaluate(int a, int b, out Vec3 p, out double cost)
    {
        Quadric q = quad[a] + quad[b];
        Vec3 opt;
        if (q.Optimal(out opt))
        {
            // Never let a collapse push a vertex outside the original extents;
            // an unconstrained quadric optimum happily does, which inflates the
            // silhouette.
            opt.X = Math.Min(Math.Max(opt.X, clampLo.X), clampHi.X);
            opt.Y = Math.Min(Math.Max(opt.Y, clampLo.Y), clampHi.Y);
            opt.Z = Math.Min(Math.Max(opt.Z, clampLo.Z), clampHi.Z);
            p = opt; cost = q.Error(opt);
            if (cost < 0) cost = 0;
            return;
        }
        // Singular: pick the best of the two endpoints and the midpoint.
        Vec3 mid = (pos[a] + pos[b]) * 0.5;
        double ca = q.Error(pos[a]), cb = q.Error(pos[b]), cm = q.Error(mid);
        if (ca <= cb && ca <= cm) { p = pos[a]; cost = ca; }
        else if (cb <= cm) { p = pos[b]; cost = cb; }
        else { p = mid; cost = cm; }
        if (cost < 0) cost = 0;
    }

    bool AreAdjacent(int a, int b)
    {
        foreach (int f in vTris[a])
        {
            if (tDead[f]) continue;
            if (tri[f * 3] == b || tri[f * 3 + 1] == b || tri[f * 3 + 2] == b) return true;
        }
        return false;
    }


    // Link condition. Collapsing an edge is only topology-safe when the one-ring
    // neighbourhoods of its two endpoints meet in exactly the vertices opposite
    // that edge - two for an interior edge, one on a boundary. Any extra shared
    // neighbour means the collapse would weld two surface sheets together and
    // produce a non-manifold edge or a hole. Checking for a flipped normal, as
    // WouldFlip does, does not catch this.
    readonly HashSet<int> ringA = new HashSet<int>();
    readonly HashSet<int> ringSeen = new HashSet<int>();

    bool LinkConditionOk(int a, int b)
    {
        int sharedFaces = 0;
        ringA.Clear();
        foreach (int f in vTris[a])
        {
            if (tDead[f]) continue;
            int i0 = tri[f * 3], i1 = tri[f * 3 + 1], i2 = tri[f * 3 + 2];
            if (i0 == b || i1 == b || i2 == b) sharedFaces++;
            if (i0 != a) ringA.Add(i0);
            if (i1 != a) ringA.Add(i1);
            if (i2 != a) ringA.Add(i2);
        }

        int common = 0;
        ringSeen.Clear();
        foreach (int f in vTris[b])
        {
            if (tDead[f]) continue;
            for (int k = 0; k < 3; k++)
            {
                int v = tri[f * 3 + k];
                if (v == b || v == a) continue;
                if (ringA.Contains(v) && ringSeen.Add(v)) common++;
            }
        }
        return common == sharedFaces;
    }

    // Reject a collapse that would fold a triangle over on itself.
    bool WouldFlip(int a, int b, Vec3 p)
    {
        for (int pass = 0; pass < 2; pass++)
        {
            int v = (pass == 0) ? a : b;
            foreach (int f in vTris[v])
            {
                if (tDead[f]) continue;
                int i0 = tri[f * 3], i1 = tri[f * 3 + 1], i2 = tri[f * 3 + 2];
                // Triangles containing both endpoints vanish in the collapse.
                bool ha = (i0 == a || i1 == a || i2 == a);
                bool hb = (i0 == b || i1 == b || i2 == b);
                if (ha && hb) continue;

                Vec3 q0 = pos[i0], q1 = pos[i1], q2 = pos[i2];
                Vec3 before = (q1 - q0).Cross(q2 - q0);
                if (i0 == a || i0 == b) q0 = p;
                if (i1 == a || i1 == b) q1 = p;
                if (i2 == a || i2 == b) q2 = p;
                Vec3 after = (q1 - q0).Cross(q2 - q0);

                if (after.Length() < 1e-18) return true;                 // degenerate
                if (before.Normalized().Dot(after.Normalized()) < 0.2) return true; // flipped / near-flip
            }
        }
        return false;
    }

    void Collapse(int a, int b, Vec3 p)
    {
        pos[a] = p;
        quad[a] = quad[a] + quad[b];

        List<int> moved = new List<int>();
        foreach (int f in vTris[b])
        {
            if (tDead[f]) continue;
            int i0 = tri[f * 3], i1 = tri[f * 3 + 1], i2 = tri[f * 3 + 2];
            if (i0 == a || i1 == a || i2 == a)
            {
                tDead[f] = true;      // shared triangle collapses away
                liveTris--;
                continue;
            }
            if (i0 == b) tri[f * 3] = a;
            if (i1 == b) tri[f * 3 + 1] = a;
            if (i2 == b) tri[f * 3 + 2] = a;
            moved.Add(f);
        }
        for (int i = 0; i < moved.Count; i++) vTris[a].Add(moved[i]);
        vTris[b].Clear();
        vDead[b] = true;

        // Costs around the merged vertex are now stale - re-push its edges.
        HashSet<int> nbr = new HashSet<int>();
        foreach (int f in vTris[a])
        {
            if (tDead[f]) continue;
            for (int k = 0; k < 3; k++)
            {
                int v = tri[f * 3 + k];
                if (v != a && !vDead[v]) nbr.Add(v);
            }
        }
        foreach (int v in nbr)
        {
            Vec3 np; double nc;
            Evaluate(a, v, out np, out nc);
            Push(new Cand { Cost = nc, A = a, B = v, P = np });
        }
    }

    Mesh Compact()
    {
        Mesh m = new Mesh();
        int[] remap = new int[pos.Length];
        for (int i = 0; i < remap.Length; i++) remap[i] = -1;

        for (int f = 0; f < tDead.Length; f++)
        {
            if (tDead[f]) continue;
            int a = tri[f * 3], b = tri[f * 3 + 1], c = tri[f * 3 + 2];
            if (a == b || b == c || a == c) continue;
            if (remap[a] < 0) { remap[a] = m.Verts.Count; m.Verts.Add(pos[a]); }
            if (remap[b] < 0) { remap[b] = m.Verts.Count; m.Verts.Add(pos[b]); }
            if (remap[c] < 0) { remap[c] = m.Verts.Count; m.Verts.Add(pos[c]); }
            m.Tris.Add(remap[a]); m.Tris.Add(remap[b]); m.Tris.Add(remap[c]);
        }
        return m;
    }

    // ---- binary heap (min by Cost) ----
    void Heapify() { for (int i = heap.Count / 2 - 1; i >= 0; i--) SiftDown(i); }

    void Push(Cand c) { heap.Add(c); SiftUp(heap.Count - 1); }

    Cand Pop()
    {
        if (heap.Count == 0) return null;
        Cand top = heap[0];
        heap[0] = heap[heap.Count - 1];
        heap.RemoveAt(heap.Count - 1);
        if (heap.Count > 0) SiftDown(0);
        return top;
    }

    void SiftUp(int i)
    {
        while (i > 0)
        {
            int p = (i - 1) / 2;
            if (heap[p].Cost <= heap[i].Cost) break;
            Cand t = heap[p]; heap[p] = heap[i]; heap[i] = t;
            i = p;
        }
    }

    void SiftDown(int i)
    {
        while (true)
        {
            int l = 2 * i + 1, r = l + 1, s = i;
            if (l < heap.Count && heap[l].Cost < heap[s].Cost) s = l;
            if (r < heap.Count && heap[r].Cost < heap[s].Cost) s = r;
            if (s == i) break;
            Cand t = heap[s]; heap[s] = heap[i]; heap[i] = t;
            i = s;
        }
    }
}

// ---------------------------------------------------------------------------

static class Program
{
    static int Main(string[] args)
    {
        if (args.Length < 2) { Usage(); return 1; }

        string input = args[0];
        string output = args[1];
        int maxTris = 19500;
        double clearance = 0;
        bool haveAttach = false;
        bool autoAttach = false;
        Vec3 attach = new Vec3(0, 0, 0);
        bool quiet = false;
        bool translate = true;      // --attach re-origins the mesh (see below)
        bool probe = false;
        bool ascii = false;
        string progressFile = null;
        double coarse = 0.10;
        int topoCheckLimit = 400000;
        double speckFraction = 0.01;   // drop shells smaller than this fraction of the model diagonal
        bool pruneShells = true;
        bool cutBelowAttach = false;
        bool preserveExtents = true;   // fraction of the coarse target edge used as the starting weld tolerance; 0 disables
        string stlUnits = "mm";

        for (int i = 2; i < args.Length; i++)
        {
            string a = args[i];
            if (a == "--max-tris" && i + 1 < args.Length) { maxTris = int.Parse(args[++i], CultureInfo.InvariantCulture); }
            else if (a == "--clearance" && i + 1 < args.Length) { clearance = double.Parse(args[++i], CultureInfo.InvariantCulture); }
            else if (a == "--attach" && i + 1 < args.Length)
            {
                string av = args[++i];
                if (av.Equals("auto", StringComparison.OrdinalIgnoreCase)) { autoAttach = true; continue; }
                string[] p = av.Split(',');
                if (p.Length != 3) { Console.Error.WriteLine("--attach needs x,y,z"); return 1; }
                attach = new Vec3(double.Parse(p[0], CultureInfo.InvariantCulture),
                                  double.Parse(p[1], CultureInfo.InvariantCulture),
                                  double.Parse(p[2], CultureInfo.InvariantCulture));
                haveAttach = true;
            }
            else if (a == "--stl-units" && i + 1 < args.Length)
            {
                stlUnits = args[++i].ToLowerInvariant();
                if (stlUnits != "mm" && stlUnits != "in") { Console.Error.WriteLine("--stl-units must be mm or in"); return 1; }
            }
            else if (a == "--no-translate") translate = false;
            else if (a == "--probe") probe = true;
            else if (a == "--ascii") ascii = true;
            else if (a == "--progress-file" && i + 1 < args.Length) progressFile = args[++i];
            else if (a == "--coarse" && i + 1 < args.Length) coarse = double.Parse(args[++i], CultureInfo.InvariantCulture);
            else if (a == "--no-prune") pruneShells = false;
            else if (a == "--cut-below-attach") cutBelowAttach = true;
            else if (a == "--topo-limit" && i + 1 < args.Length) topoCheckLimit = int.Parse(args[++i], CultureInfo.InvariantCulture);
            else if (a == "--speck" && i + 1 < args.Length) speckFraction = double.Parse(args[++i], CultureInfo.InvariantCulture);
            else if (a == "--no-preserve-extents") preserveExtents = false;
            else if (a == "--quiet") quiet = true;
            else { Console.Error.WriteLine("Unknown option: " + a); Usage(); return 1; }
        }

        Prog.Init(progressFile);
        Prog.SetNow("reading");

        Mesh mesh;
        try { mesh = StlIO.Read(input); }
        catch (Exception ex) { Console.Error.WriteLine("READ FAILED: " + ex.Message); return 2; }

        int trisIn = mesh.TriangleCount;
        if (trisIn == 0) { Console.Error.WriteLine("READ FAILED: no triangles"); return 2; }

        Vec3 minIn, maxIn;
        mesh.Bounds(out minIn, out maxIn);

        // --probe: report the AS-READ bounds and stop. Used to check the STL
        // vertex frame against stockBounds_wcs in the post's JSON before any
        // fixture is trusted (that frame is documented as inferred-unverified).
        if (probe)
        {
            StringBuilder pb = new StringBuilder();
            pb.Append("{\"ok\":true,\"probe\":true");
            pb.Append(",\"trianglesIn\":").Append(trisIn);
            pb.Append(",\"bboxIn\":[").Append(F(minIn.X)).Append(",").Append(F(minIn.Y)).Append(",").Append(F(minIn.Z)).Append(",")
                                     .Append(F(maxIn.X)).Append(",").Append(F(maxIn.Y)).Append(",").Append(F(maxIn.Z)).Append("]}");
            Console.WriteLine(pb.ToString());
            return 0;
        }

        // The control places a fixture by putting the mesh's (0,0,0) onto its
        // fixture attach location, so the mesh must be re-origined about the
        // attach point: v' = v - A. Pure translation, no rotation or scaling.
        // Afterwards the attach point IS the origin, so the clearance scale
        // below simply anchors at (0,0,0).
        bool translated = false;
        if (haveAttach && translate)
        {
            for (int i = 0; i < mesh.Verts.Count; i++)
            {
                Vec3 v = mesh.Verts[i];
                mesh.Verts[i] = new Vec3(v.X - attach.X, v.Y - attach.Y, v.Z - attach.Z);
            }
            attach = new Vec3(0, 0, 0);
            translated = true;
        }

        // Clearance is always given in mm; convert if the mesh is in inches.
        // (frames.stlUnits in the post's JSON is the CAM document unit, which
        // is NOT always the NC unit.)
        double clearMesh = (stlUnits == "in") ? clearance / 25.4 : clearance;

        // Weld tolerance scaled to the model so it works for tiny and huge parts.
        Prog.SetNow("welding " + trisIn + " triangles");
        Mesh soup = mesh;
        double diag = (maxIn - minIn).Length();
        double weldTol = Math.Max(1e-6, diag * 1e-7);
        mesh = Weld.Run(soup, weldTol);

        // Quadric decimation cost grows superlinearly, so a huge export (1M+
        // triangles) would take many minutes. Welding at a coarser tolerance is
        // vertex clustering: cheap, and it thins the mesh before the expensive
        // pass. Only engages far above the target, and the tolerance is capped
        // at 0.1% of the bounding diagonal so the loss stays far below the
        // clearance we are about to apply.
        // Checking a 1.6M-triangle input costs real time and memory for a
        // description of a mesh we are about to replace, so it is skipped above
        // this size; the OUTPUT check always runs and is what the control sees.
        Topo.Report topoIn = (mesh.TriangleCount <= topoCheckLimit)
            ? Topo.Check(mesh) : null;

        // Throw away geometry that cannot matter before spending any budget on
        // it: sealed internal voids and stray specks.
        int speckShells = 0, voidShells = 0;
        if (pruneShells)
        {
            Prog.SetNow("pruning unreachable shells");
            int beforePrune = mesh.TriangleCount;
            mesh = Shells.Prune(mesh, speckFraction, out speckShells, out voidShells);
            if (mesh.TriangleCount != beforePrune) soup = mesh;   // coarse passes re-weld from the pruned mesh
        }

        // Cut away everything below the attach plane and cap the openings,
        // so mount features cannot collide with the machine's own clamp model.
        int cutRemoved = 0, capTrisN = 0, capLoopsN = 0;
        bool didCut = false;
        List<string> cutWarn = new List<string>();
        if (cutBelowAttach)
        {
            if (!haveAttach)
            {
                cutWarn.Add("--cut-below-attach needs an explicit --attach point; cut SKIPPED");
            }
            else
            {
                Prog.SetNow("cutting below the attach plane");
                Vec3 cmn, cmx; mesh.Bounds(out cmn, out cmx);
                double cutEps = Math.Max(1e-9, (cmx - cmn).Length() * 1e-6);
                int beforeCut = mesh.TriangleCount;
                mesh = PlaneCut.CutBelowZ(mesh, attach.Z, cutEps, out cutRemoved, out capTrisN, out capLoopsN, cutWarn);
                didCut = true;
                if (mesh.TriangleCount != beforeCut) soup = mesh;   // coarse passes re-weld from the cut mesh
            }
        }

        int coarsePasses = 0;
        if (maxTris > 0 && coarse > 0 && mesh.TriangleCount > maxTris * 8)
        {
            // Jump straight to an estimated tolerance rather than doubling up
            // from ~0. Each weld pass is a full pass over the soup, so on a
            // 1.66M-triangle in-process stock mesh a dozen of them dominates
            // the whole runtime.
            //
            // A mesh of N triangles spanning `diag` has edges of roughly
            // diag/sqrt(N), so aim at the edge length the coarse target implies
            // and start a little under it.
            int coarseTarget = maxTris * 8;
            double targetEdge = diag / Math.Sqrt((double)coarseTarget);
            double cap = diag * 5e-3;
            weldTol = Math.Max(weldTol, Math.Min(targetEdge * coarse, cap));
            Prog.SetNow("coarse weld (" + mesh.TriangleCount + " triangles)");
            mesh = Weld.Run(soup, weldTol, true);
            coarsePasses = 1;

            while (mesh.TriangleCount > coarseTarget && weldTol < cap && coarsePasses < 6)
            {
                weldTol = Math.Min(weldTol * 2.0, cap);
                Prog.SetNow("coarse weld pass " + (coarsePasses + 1));
                mesh = Weld.Run(soup, weldTol, true);
                coarsePasses++;
            }
        }
        int vertsWelded = mesh.Verts.Count;

        double deviation = 0;
        bool decimated = false;
        if (maxTris > 0 && mesh.TriangleCount > maxTris)
        {
            Prog.SetNow("decimating " + mesh.TriangleCount + " -> " + maxTris);
            Decimator d = new Decimator();
            d.PreserveExtents = preserveExtents;
            mesh = d.Run(mesh, maxTris, out deviation);
            decimated = true;
        }

        // Topology after reduction. Scaling below is affine and cannot change
        // connectivity, so this is the final topology.
        Topo.Report topoOut = Topo.Check(mesh);

        // ---- shrink about the attach point ----
        double sx = 1, sy = 1, sz = 1;
        int vertsBelowAnchor = 0;
        bool scaled = false;
        List<string> warn = new List<string>();
        foreach (string w in cutWarn) warn.Add(w);

        if (topoIn != null && !topoIn.Closed)
        {
            warn.Add("input mesh is " + topoIn.Text() + " - the control expects a closed mesh; fix the export if it is rejected");
        }
        else if (topoIn != null && !topoIn.Manifold)
        {
            warn.Add("input mesh is " + topoIn.Text() + " (closed, so usable, but the seams come from the export)");
        }
        if (topoIn != null && (topoOut.NonManifold > topoIn.NonManifold || topoOut.Boundary > topoIn.Boundary))
        {
            warn.Add("processing degraded topology: in=" + topoIn.Text() + ", out=" + topoOut.Text());
        }
        if (!topoOut.Closed)
        {
            warn.Add("output mesh is " + topoOut.Text() + " - the control expects a closed mesh." +
                     " Re-run with --coarse 0 to keep it closed (much slower on dense meshes).");
        }

        if (clearMesh > 0)
        {
            Vec3 mn, mx;
            mesh.Bounds(out mn, out mx);

            if (!haveAttach && !autoAttach)
            {
                // Guessing the anchor is unsafe: fixtures are often asymmetric,
                // and mount features (pullstuds, bolts) can sit BELOW the attach
                // plane, so the bounding box bottom is not the attach point. A
                // wrong anchor silently mis-shrinks the collision model, which
                // is worse than not shrinking at all - an unshrunk fixture just
                // trips DCM, which is loud and harmless. So refuse.
                warn.Add("no attach point supplied; scaling SKIPPED (pass --attach x,y,z, or --attach auto to accept the bounding-box guess)");
            }
            else
            {
                if (!haveAttach)
                {
                    attach = new Vec3((mn.X + mx.X) * 0.5, (mn.Y + mx.Y) * 0.5, mn.Z);
                    warn.Add("attach point GUESSED as bounding-box bottom centre; verify it matches the machine simulation attach");
                }

                sx = AxisScale(attach.X, mn.X, mx.X, clearMesh, "X", warn);
                sy = AxisScale(attach.Y, mn.Y, mx.Y, clearMesh, "Y", warn);

                double up = mx.Z - attach.Z;
                if (up <= clearMesh) warn.Add("Z: height above attach point (" + F(up) + ") <= clearance; Z left unscaled");
                else sz = 1.0 - clearMesh / up;

                // Geometry below the attach plane is the machine mount interface
                // (pullstuds, bolt heads, pallet skirt). Its Z is left EXACTLY as
                // modelled - that interface has to stay where the machine expects
                // it. XY still scales so the whole body shrinks about the anchor
                // axis.
                for (int i = 0; i < mesh.Verts.Count; i++)
                {
                    Vec3 v = mesh.Verts[i];
                    double dz = v.Z - attach.Z;
                    double nz;
                    if (dz < 0) { nz = v.Z; vertsBelowAnchor++; }   // clamp: keep mount features put
                    else nz = attach.Z + dz * sz;

                    mesh.Verts[i] = new Vec3(attach.X + (v.X - attach.X) * sx,
                                             attach.Y + (v.Y - attach.Y) * sy,
                                             nz);
                }
                scaled = true;

                if (vertsBelowAnchor > 0)
                    warn.Add(vertsBelowAnchor + " vertices sit below the attach plane (mount features); their Z was left unscaled");
            }
        }

        Prog.SetNow("writing " + mesh.TriangleCount + " triangles");
        try { if (ascii) StlIO.WriteAscii(output, mesh); else StlIO.WriteBinary(output, mesh); }
        catch (Exception ex) { Console.Error.WriteLine("WRITE FAILED: " + ex.Message); return 3; }

        if (!quiet)
        {
            Vec3 mn2, mx2;
            mesh.Bounds(out mn2, out mx2);
            StringBuilder sb = new StringBuilder();
            sb.Append("{");
            sb.Append("\"ok\":true");
            sb.Append(",\"trianglesIn\":").Append(trisIn);
            sb.Append(",\"trianglesOut\":").Append(mesh.TriangleCount);
            sb.Append(",\"vertsWelded\":").Append(vertsWelded);
            sb.Append(",\"weldTol\":").Append(F(weldTol));
            sb.Append(",\"coarsePasses\":").Append(coarsePasses);
            sb.Append(",\"coarse\":").Append(F(coarse));
            sb.Append(",\"topologyIn\":").Append(topoIn == null ? "null" : topoIn.Json());
            sb.Append(",\"topologyOut\":").Append(topoOut.Json());
            sb.Append(",\"cutBelowAttach\":").Append(didCut ? "true" : "false");
            sb.Append(",\"cutRemovedTris\":").Append(cutRemoved);
            sb.Append(",\"capTriangles\":").Append(capTrisN);
            sb.Append(",\"capLoops\":").Append(capLoopsN);
            sb.Append(",\"speckShells\":").Append(speckShells);
            sb.Append(",\"voidShells\":").Append(voidShells);
            sb.Append(",\"decimated\":").Append(decimated ? "true" : "false");
            sb.Append(",\"maxDeviation\":").Append(F(deviation));
            sb.Append(",\"translated\":").Append(translated ? "true" : "false");
            sb.Append(",\"stlUnits\":\"").Append(stlUnits).Append("\"");
            sb.Append(",\"format\":\"").Append(ascii ? "ascii" : "binary").Append("\"");
            sb.Append(",\"clearanceApplied\":").Append(F(scaled ? clearMesh : 0));
            sb.Append(",\"scaled\":").Append(scaled ? "true" : "false");
            sb.Append(",\"vertsBelowAnchor\":").Append(vertsBelowAnchor);
            sb.Append(",\"scale\":[").Append(F(sx)).Append(",").Append(F(sy)).Append(",").Append(F(sz)).Append("]");
            sb.Append(",\"attach\":[").Append(F(attach.X)).Append(",").Append(F(attach.Y)).Append(",").Append(F(attach.Z)).Append("]");
            sb.Append(",\"bboxIn\":[").Append(F(minIn.X)).Append(",").Append(F(minIn.Y)).Append(",").Append(F(minIn.Z)).Append(",")
                                     .Append(F(maxIn.X)).Append(",").Append(F(maxIn.Y)).Append(",").Append(F(maxIn.Z)).Append("]");
            sb.Append(",\"bboxOut\":[").Append(F(mn2.X)).Append(",").Append(F(mn2.Y)).Append(",").Append(F(mn2.Z)).Append(",")
                                      .Append(F(mx2.X)).Append(",").Append(F(mx2.Y)).Append(",").Append(F(mx2.Z)).Append("]");
            sb.Append(",\"warnings\":[");
            for (int i = 0; i < warn.Count; i++)
            {
                if (i > 0) sb.Append(",");
                sb.Append("\"").Append(warn[i].Replace("\\", "\\\\").Replace("\"", "\\\"")).Append("\"");
            }
            sb.Append("]}");
            Console.WriteLine(sb.ToString());
        }
        return 0;
    }

    // Scale factor guaranteeing AT LEAST `clear` inward movement on BOTH faces.
    //
    // Scaling about a point moves geometry proportionally to its distance from
    // that point: the far face moves most, the near face least. So the binding
    // constraint is the NEARER face - divide by the smaller half-distance. The
    // far face then over-shrinks, which is the unavoidable price of holding the
    // attach point fixed (needed to keep the fixture registered to machine
    // coordinates). A badly off-centre attach point makes that overshoot large,
    // so report it - the overshoot is real collision-model blindness.
    static double AxisScale(double anchor, double lo, double hi, double clear, string axis, List<string> warn)
    {
        double dLo = anchor - lo, dHi = hi - anchor;

        // A face at or inside `clear` of the anchor can never move `clear`
        // inward by scaling - it would have to cross the anchor.
        bool loStuck = dLo <= clear;
        bool hiStuck = dHi <= clear;
        if (loStuck && hiStuck)
        {
            warn.Add(axis + ": both faces within " + F(clear) + " of the attach point; axis left unscaled");
            return 1.0;
        }

        double d;
        if (loStuck)
        {
            d = dHi;
            warn.Add(axis + ": low face only " + F(dLo) + " from attach point; it cannot move " + F(clear) + " inward");
        }
        else if (hiStuck)
        {
            d = dLo;
            warn.Add(axis + ": high face only " + F(dHi) + " from attach point; it cannot move " + F(clear) + " inward");
        }
        else d = Math.Min(dLo, dHi);

        double s = 1.0 - clear / d;
        double moveLo = dLo * (1.0 - s), moveHi = dHi * (1.0 - s);
        double worst = Math.Max(moveLo, moveHi);
        if (worst > clear * 1.5 + 1e-9)
        {
            warn.Add(axis + ": attach point off-centre (" + F(dLo) + " vs " + F(dHi) + ") - faces move in " +
                     F(moveLo) + " / " + F(moveHi) + " instead of " + F(clear) +
                     "; that overshoot is unmonitored by DCM");
        }
        return s;
    }

    static string F(double v) { return v.ToString("0.######", CultureInfo.InvariantCulture); }

    static void Usage()
    {
        Console.Error.WriteLine("Usage: TNCWatcher-StlPrep.exe <input.stl> <output.stl> [options]");
        Console.Error.WriteLine("  --max-tris N     triangle budget (default 19500, 0 = no decimation)");
        Console.Error.WriteLine("  --clearance MM   shrink each face inward by MM (default 0 = no scaling)");
        Console.Error.WriteLine("  --attach x,y,z   fixture attach point, in the INPUT mesh's coordinates.");
        Console.Error.WriteLine("                   Mesh is re-origined so this lands at (0,0,0), which is");
        Console.Error.WriteLine("                   where the control expects it, and scaling anchors there.");
        Console.Error.WriteLine("  --attach auto    accept a bounding-box bottom-centre guess (unsafe if asymmetric)");
        Console.Error.WriteLine("  --no-translate   keep the mesh where it is; only anchor scaling at --attach");
        Console.Error.WriteLine("  --stl-units U    mm|in - unit of the mesh vertices (default mm). --clearance");
        Console.Error.WriteLine("                   is always mm and is converted to match.");
        Console.Error.WriteLine("  --probe          report as-read bounds only; write nothing");
        Console.Error.WriteLine("  --cut-below-attach  remove everything below the attach plane and cap the hole");
        Console.Error.WriteLine("  --progress-file F  write a one-line status to F while working");
        Console.Error.WriteLine("  --ascii          write ASCII STL instead of binary. Required for the TNC 640:");
        Console.Error.WriteLine("                   it rejects long runs of bytes with no line break on PUT.");
        Console.Error.WriteLine("  --quiet          suppress the JSON report");
    }
}
