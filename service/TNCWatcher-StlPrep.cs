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

static class Weld
{
    // STL is a triangle soup: every triangle carries its own copy of each
    // corner. Edge collapse needs shared vertices, so merge coincident ones.
    public static Mesh Run(Mesh src, double tol)
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

        for (int t = 0; t < src.Tris.Count; t += 3)
        {
            int a = remap[src.Tris[t]], b = remap[src.Tris[t + 1]], c = remap[src.Tris[t + 2]];
            if (a == b || b == c || a == c) continue;   // collapsed to nothing
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

    public Mesh Run(Mesh src, int target, out double maxDeviation)
    {
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

        while (liveTris > target && heap.Count > 0)
        {
            Cand c = Pop();
            if (c == null) break;
            if (vDead[c.A] || vDead[c.B]) continue;
            if (!AreAdjacent(c.A, c.B)) continue;

            // Lazy revalidation: the incident quadrics may have changed since
            // this entry was pushed, so recompute and re-queue if it got worse.
            Vec3 p; double cost;
            Evaluate(c.A, c.B, out p, out cost);
            if (cost > c.Cost * 1.0001 + 1e-12) { Push(new Cand { Cost = cost, A = c.A, B = c.B, P = p }); continue; }

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
            else if (a == "--quiet") quiet = true;
            else { Console.Error.WriteLine("Unknown option: " + a); Usage(); return 1; }
        }

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
        int coarsePasses = 0;
        if (maxTris > 0)
        {
            double cap = diag * 1e-3;
            while (mesh.TriangleCount > maxTris * 8 && weldTol < cap && coarsePasses < 12)
            {
                weldTol = Math.Min(weldTol * 2.0, cap);
                mesh = Weld.Run(soup, weldTol);
                coarsePasses++;
            }
        }
        int vertsWelded = mesh.Verts.Count;

        double deviation = 0;
        bool decimated = false;
        if (maxTris > 0 && mesh.TriangleCount > maxTris)
        {
            Decimator d = new Decimator();
            mesh = d.Run(mesh, maxTris, out deviation);
            decimated = true;
        }

        // ---- shrink about the attach point ----
        double sx = 1, sy = 1, sz = 1;
        int vertsBelowAnchor = 0;
        bool scaled = false;
        List<string> warn = new List<string>();
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
        Console.Error.WriteLine("  --ascii          write ASCII STL instead of binary. Required for the TNC 640:");
        Console.Error.WriteLine("                   it rejects long runs of bytes with no line break on PUT.");
        Console.Error.WriteLine("  --quiet          suppress the JSON report");
    }
}
