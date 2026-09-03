# STL prep pipeline (TNCWatcher-StlPrep.exe)

Converts Fusion-exported STOCK/PART/FIXTURE meshes to what the TNC 640
accepts: ≤ 20,000 triangles (budget 19,500), **closed** (watertight), ASCII
STL (see E20001714 in CRITICAL-CONSTRAINTS.md).

## Stage order

1. **Read** — binary or ASCII; completeness check for binary is exact:
   `size == 84 + 50*count`.
2. **Translate** — `v' = v − attach` so the attach point IS the origin
   (the control places the mesh's (0,0,0) on the fixture attach location).
3. **Fine weld** — spatial-hash merge of coincident soup vertices,
   `tol = max(1e-6, diag*1e-7)`.
4. **Shell prune** — union-find components; drop specks (< 1% of diagonal)
   and sealed internal voids (bbox fully inside a larger shell).
5. **Plane cut** (`--cut-below-attach`, FIXTURE only) — clip below z=0, cap
   the openings (Sutherland-Hodgman + shared cut-point cache + ear-clip caps
   facing −Z), compact orphan vertices.
6. **Coarse pre-weld** — only when input > 8× budget (156k tris). Vertex
   clustering to thin the mesh before QEM. Tolerance starts at
   `targetEdge * coarse` and doubles per pass, capped by BOTH `diag*5e-3`
   and `--weld-cap` (absolute mm, default 0.35).
7. **Hole repair** (`--no-repair` to disable) — boundary edges chained
   reverse-direction (fill opposes surface winding, no normal guess needed),
   Eulerian cycle extraction (consumes edges, splits sub-cycles at pinch
   vertices), each loop ear-clipped in its Newell best-fit plane, centroid-fan
   fallback and for rims > 256 edges. Runs before decimation and again after
   if needed.
8. **QEM decimation** — Garland–Heckbert quadrics with:
   - link condition (topology safety),
   - `WouldFlip` normal check,
   - extent pinning (bounding-face quadrics, weight 1e4),
   - bbox clamp on the optimal placement,
   - open-boundary edge constraints,
   - **non-manifold edge vertices frozen** (`vNoCollapse`) — collapsing a
     3+-face edge kills all its faces at once and tears holes,
   - flat struct-array min-heap with **stamp invalidation**: a collapse bumps
     the survivor's stamp; stale heap entries are dropped O(1) on pop. A
     vertex's quadric only changes when it survives a collapse, so matching
     stamps mean the stored cost is exact (placement recomputed on accept).
9. **Topology check out** — always runs; report `topologyOut`.
10. **Clearance scale** (FIXTURE) — anchor at attach; per-axis factor from the
    **min** half-distance so every face moves at least `clearance` inward;
    z below attach clamped (mount features keep Z).
11. **Write** — ASCII (control requirement) or binary; atomic tmp+move is the
    watcher's job.

## Topology vocabulary

- **Closed (watertight)** = zero boundary edges and zero degenerate tris.
  This is what the control needs.
- **Manifold** = zero edges with 3+ faces. Fusion exports routinely arrive
  closed but non-manifold (shell seams); the control has accepted these.

## Why the coarse weld is dangerous

Vertex clustering cannot preserve closure at high reduction ratios: merging
opposite walls of thin machined features (scallops, webs) stacks triangles,
and the dedupe that removes the stacks leaves boundary edges and non-manifold
fins with **inconsistent winding** — those rims do not chain into loops, so
even hole repair cannot fully close them. Mitigations, in order of value:

1. `--weld-cap 0.35` keeps the tolerance below typical scallop size.
2. Non-manifold pinning stops the decimator from tearing what survives.
3. Hole repair closes what is chainable.
4. `--coarse 0` avoids the problem entirely (slower; see measurements in the
   watcher's config comments).

Fixtures and parts never take the coarse path (they are under 8× budget);
only dense in-process stock does.

## Fixture frame

- Attach point comes from the sidecar JSON
  (`fixtureAttachPoint_inFixtureFrame_stlUnits`) — **never** inferred from the
  bounding box (fixtures are asymmetric; pullstuds extend below the attach
  plane). Missing attach = warn and ship unscaled/uncut, never block.
- STL vertex frame = setup WCS. Verified on a real bundle: stock bounds match
  `stockBounds_wcs` within 0.013mm (the FCS hypothesis was off by 101.2mm).
- Frame mismatch check warns and uploads anyway (multi-WCS setups are normal).

## Report (stdout JSON)

Keys the watcher consumes: `topologyIn/topologyOut` (null in when over
`--topo-limit`, default 400k), `trianglesIn/Out`, `maxDeviation`, `warnings`,
`holesFilled`, `fillTriangles`, `weldCap`, `coarsePasses`, `scaled`,
`cutBelowAttach`, `capLoops`. Progress goes to `--progress-file` (echoed to
the log by `Invoke-StlPrep` every `$StlProgressIntervalSeconds`).

## Testing

- `service/stl-test.py` — full unit suite (85 assertions), generates its own
  solids. The hand-built solids MUST be valid: grid-aligned generator + BFS
  winding unification; T-junctions and miswound edges invalidate cap tests.
- `service/stl-bundle-test.ps1`, `stl-settle-test.ps1`, `stl-timing-test.ps1`
  — watcher-level harnesses. They stub `Send-FileToMachine`,
  `New-RemoteDirectory` and `Remove-RemoteFile` (**critical**: prevents real
  deletes on the control) and redirect the config json.
- `service/stl-watertight.py`, `stl-quality.py`, `stl-bundle-make.py` —
  independent verification tools; repo copies are canonical.
- Real-world regression file: the 1.26M-triangle in-process stock at
  `WatchFolder\Processed\Lang Calibration\Op2 Partial\STOCK.stl` (63MB) —
  the mesh that exposed the coarse-weld tearing.
