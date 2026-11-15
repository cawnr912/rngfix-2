"""Generate surf_rngfix_edgebug.vmf, a test box for the edge fix and rngfix_subtick 8 (multi-bump edge prediction).

Run:  python make_edgebug_test.py   (writes the .vmf next to this script)

How it works
  You walk off the start platform onto a long 48 degree surf ramp (not walkable, so you just slide; let go of
  every key once you leave the platform). It drops 6000 units, so you leave its lip at about 2000 u/s
  horizontal, about 20 units a tick at 102.4 tick, and fall onto a field of edge shapes. Fast horizontal
  speed is what makes edge bugs common: the edge window is the distance moved in the part of the tick after contact.

  The field is split into 15 lanes across Y, in three groups. Each lane is the same pattern shifted along X
  by a sixteenth of its period and lowered by a fraction of a tick's fall. Your path is the same every run,
  so a lane's result repeats. Only the shifts that an offline replay of the plugin's prediction says fire
  are built (KEEP below), plus a neighbour or two in case the real path is a few units off.
  Start gates on the platform line you up with a lane: walk straight forward down one gate. The first gate
  of each group has a marker in front of it; gates are numbered from the -Y side.

  Group A, dark (comb):    8-unit rails with 56-unit gaps. Plain edge bugs; 1-bump and 4-bump agree,
                           so expect "DO FIX: Edge Bug" with no "Edge predict" line.
  Group B, light (slot):   10-unit steps rising 4 units each, with 30-unit slots between (narrower than the
                           hull). Sliding off a step, the 1-bump estimate ends over the slot (edge bug), but the
                           real move stops against the next step's 4-unit face while still on the step.
                           Expect "Edge predict: 1-bump edge bug, 4-bump lands" (wall next to the edge, avoided).
  Group C, orange (kicker): 52-unit flats, each ending in an 8-unit 60 degree kicker ramp. Landing just before a
                           kicker, the 1-bump estimate pokes into the kicker but still has ground under the back
                           half; the real move rides up the kicker, off the ground, so there's nothing to fix.
                           Expect "Edge predict: 4-bump ends rising (z-vel ...), no fix" (fork.9 guard).

  Whatever happens, drop off the side of your lane: the floor is a teleport back to a closet in the start lobby
  (it stops your speed against the closet wall). You land at about 2300 u/s down, so the server needs fall
  damage off (most timers do; otherwise sv_falldamage_scale 0).
"""
import math, os

TEX = "DEV/DEV_MEASUREGENERIC01B"
TEX_FLOOR = "DEV/DEV_MEASUREGENERIC01"
TEX_DARK = "DEV/REFLECTIVITY_30"
TEX_LIGHT = "DEV/REFLECTIVITY_70"
TEX_ORANGE = "DEV/DEV_MEASUREGENERIC01"
TRIG = "TOOLS/TOOLSTRIGGER"

_id = [0]
def nid():
    _id[0] += 1
    return _id[0]

def sub(a, b): return [a[i] - b[i] for i in range(3)]
def cross(a, b): return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
def dot(a, b): return sum(a[i]*b[i] for i in range(3))
def fmt(v): return "(%s)" % " ".join(("%.4f" % c).rstrip("0").rstrip(".") for c in v)

def axes(n):
    ax = [abs(c) for c in n]
    if ax[2] >= ax[0] and ax[2] >= ax[1]: return "[1 0 0 0] 0.25", "[0 -1 0 0] 0.25"
    if ax[0] >= ax[1]: return "[0 1 0 0] 0.25", "[0 0 -1 0] 0.25"
    return "[1 0 0 0] 0.25", "[0 0 -1 0] 0.25"

def solid(verts, faces, tex):
    """verts: list of points; faces: lists of vertex indices (any winding). Convex brushes only."""
    center = [sum(v[i] for v in verts) / len(verts) for i in range(3)]
    out = ["\tsolid\n\t{\n\t\t\"id\" \"%d\"\n" % nid()]
    for f in faces:
        a, b, c = verts[f[0]], verts[f[1]], verts[f[2]]
        # Hammer's outward normal is (p1 - p2) x (p3 - p2).
        n = cross(sub(a, b), sub(c, b))
        fc = [sum(verts[i][k] for i in f) / len(f) for k in range(3)]
        if dot(n, sub(fc, center)) < 0:
            a, c = c, a
            n = [-x for x in n]
        u, v = axes(n)
        out.append("\t\tside\n\t\t{\n\t\t\t\"id\" \"%d\"\n\t\t\t\"plane\" \"%s %s %s\"\n"
                   "\t\t\t\"material\" \"%s\"\n\t\t\t\"uaxis\" \"%s\"\n\t\t\t\"vaxis\" \"%s\"\n"
                   "\t\t\t\"rotation\" \"0\"\n\t\t\t\"lightmapscale\" \"16\"\n\t\t\t\"smoothing_groups\" \"0\"\n\t\t}\n"
                   % (nid(), fmt(a), fmt(b), fmt(c), tex, u, v))
    out.append("\t}\n")
    return "".join(out)

BOX_FACES = [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [3, 2, 6, 7], [0, 3, 7, 4], [1, 2, 6, 5]]

def box(x0, y0, z0, x1, y1, z1, tex=TEX):
    v = [[x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0],
         [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]]
    return solid(v, BOX_FACES, tex)

def prism(poly, y0, y1, tex):
    """Extrude a convex x-z polygon along Y."""
    n = len(poly)
    verts = [[x, y0, z] for x, z in poly] + [[x, y1, z] for x, z in poly]
    faces = [list(range(n)), list(range(n, 2*n))]
    for i in range(n):
        j = (i + 1) % n
        faces.append([i, j, n + j, n + i])
    return solid(verts, faces, tex)

def entity(kv, solids=""):
    s = "entity\n{\n\t\"id\" \"%d\"\n" % nid()
    for k, v in kv.items():
        s += "\t\"%s\" \"%s\"\n" % (k, v)
    return s + solids + "}\n"

# ---- layout ---------------------------------------------------------------
FLOOR = 16                # room floor top
ZF = 400                  # field height (the slot steps climb from ZF-40)
LIP_Z = 600               # bottom of the launch ramp
ZP = 6600                 # start platform top
PLAT_EDGE_X = 0           # platform edge = top of the ramp
RAMP_DEG = 48             # normal z 0.669: not walkable
LIP_X = round((ZP - LIP_Z) / math.tan(math.radians(RAMP_DEG)))
FIELD_X0 = LIP_X + 64
FIELD_LEN = 224           # contact is around FIELD_X0 + 125..165; short so you slide off instead of hitting more kickers
ZTOP = ZP + 512
W = 16

KINDS = ["comb", "slot", "kicker"]
KIND_TEX = {"comb": TEX_DARK, "slot": TEX_LIGHT, "kicker": TEX_ORANGE}
PHASES = 16               # X shift step = period / PHASES
# Phase indices (0-based) built per group, in gate order. From the offline replay (edgesim): comb 14-15 edge bug,
# slot 5/7/9/10/11 avoided; the rest are neighbours. Kicker re-picked 2026-11-13 from the first game runs (phase 15
# landed twice, phase 0 fixed once): the real path sits near the top of the replay's height sweep, where phase 13
# rides up the kicker. 15 does so lower in the sweep and 1 at the bottom, for coverage.
KEEP = {"comb": [13, 14, 15], "slot": list(range(4, 13)), "kicker": [13, 15, 1]}
LANE_W = 48               # same as the gates: hull centre within 8 units of the lane centre
LANE_PITCH = 96
GROUP_GAP = 192
YSPAN = sum(len(KEEP[k]) for k in KINDS) * LANE_PITCH + (len(KINDS) - 1) * GROUP_GAP

# Pattern sizes.
COMB_W, COMB_GAP = 8, 56          # gap > 32 + 20 units a tick, so a slid-off hull can be clear of both rails
SLOT_W, SLOT_GAP, SLOT_RISE = 10, 30, 4
KICK_FLAT, KICK_H = 52, 8         # flat must be > 32 + the edge window so the hull can sit on it
KICK_RUN = KICK_H / math.tan(math.radians(60))
PERIOD = {"comb": COMB_W + COMB_GAP, "slot": SLOT_W + SLOT_GAP, "kicker": KICK_FLAT + KICK_RUN}

def lane_y(kind, gate):
    """Centre Y of the gate-th lane (0-based) of a group."""
    y = -YSPAN / 2
    for k in KINDS[:KINDS.index(kind)]:
        y += len(KEEP[k]) * LANE_PITCH + GROUP_GAP
    return y + gate * LANE_PITCH + LANE_PITCH / 2

def ramp_poly_2d():
    return [(PLAT_EDGE_X, LIP_Z), (LIP_X, LIP_Z), (PLAT_EDGE_X, ZP)]

# Your path is the same every run (only shifted by up to 2.4 units in X), so the part of the tick left after
# contact is too. Each lane is lowered by a different fraction of one tick's fall (golden ratio steps) as well
# as shifted along X, so the lanes sample both the contact point and the leftover tick.
TICK_FALL = 22.7          # units fallen per tick at the field (about 2300 u/s at 102.4 tick)

def lane_drop(lane):
    return round(((lane * 0.6180339887) % 1.0) * TICK_FALL, 2)

def pattern_polys_2d(kind, lane):
    """Convex x-z polygons for one lane."""
    P = PERIOD[kind]
    x = FIELD_X0 + lane * P / PHASES - P
    zf = ZF - lane_drop(lane)
    polys = []
    k = 0
    while x < FIELD_X0 + FIELD_LEN:
        if kind == "comb":
            polys.append([(x, zf - 48), (x + COMB_W, zf - 48), (x + COMB_W, zf), (x, zf)])
        elif kind == "slot":
            top = zf - 40 + SLOT_RISE * k
            polys.append([(x, top - 64), (x + SLOT_W, top - 64), (x + SLOT_W, top), (x, top)])
        else:
            xf = x + KICK_FLAT
            polys.append([(x, zf - 48), (xf, zf - 48), (xf, zf), (x, zf)])
            polys.append([(xf, zf - 48), (xf + KICK_RUN, zf - 48), (xf + KICK_RUN, zf + KICK_H), (xf, zf)])
        x += P
        k += 1
    return [[(round(px, 3), round(pz, 3)) for px, pz in p] for p in polys]

def build():
    XMIN, XMAX = -1400, FIELD_X0 + FIELD_LEN + 400
    YMIN, YMAX = -YSPAN / 2 - 256, YSPAN / 2 + 256
    world = []
    # Shell.
    world.append(box(XMIN, YMIN, 0, XMAX, YMAX, FLOOR, TEX_FLOOR))
    world.append(box(XMIN, YMIN, ZTOP - W, XMAX, YMAX, ZTOP))
    world.append(box(XMIN, YMIN, FLOOR, XMIN + W, YMAX, ZTOP - W))
    world.append(box(XMAX - W, YMIN, FLOOR, XMAX, YMAX, ZTOP - W))
    world.append(box(XMIN + W, YMIN, FLOOR, XMAX - W, YMIN + W, ZTOP - W))
    world.append(box(XMIN + W, YMAX - W, FLOOR, XMAX - W, YMAX, ZTOP - W))
    IY0, IY1 = YMIN + W, YMAX - W

    # Start platform and launch ramp (one wedge across every lane).
    world.append(box(XMIN + W, IY0, ZP - 32, PLAT_EDGE_X, IY1, ZP))
    world.append(prism(ramp_poly_2d(), IY0, IY1, TEX))

    # Gates: 48-unit corridors lined up with the lanes, 128 tall, ending at the platform edge.
    GATE_X0 = -384
    edges = [IY0]
    for kind in KINDS:
        for gate in range(len(KEEP[kind])):
            cy = lane_y(kind, gate)
            edges += [cy - LANE_W / 2, cy + LANE_W / 2]
    edges.append(IY1)
    for i in range(0, len(edges), 2):
        world.append(box(GATE_X0, edges[i], ZP, PLAT_EDGE_X, edges[i + 1], ZP + 128))
    for kind in KINDS:
        for gate in range(len(KEEP[kind])):
            cy = lane_y(kind, gate)
            # Floor strip in the group's colour; the group's first gate gets a marker at its mouth for counting.
            world.append(box(GATE_X0, cy - 8, ZP, PLAT_EDGE_X - 1, cy + 8, ZP + 1, KIND_TEX[kind]))
            if gate == 0:
                world.append(box(GATE_X0 - 64, cy - 24, ZP, GATE_X0, cy + 24, ZP + 1, KIND_TEX[kind]))

    # Return closet: you arrive moving +X fast, the +X wall stops you, then you walk out the -X side.
    CX0, CX1, CY = -1000, -936, 0
    world.append(box(CX1, CY - 40, ZP, CX1 + 8, CY + 40, ZP + 256))
    world.append(box(CX0, CY - 40, ZP, CX1, CY - 32, ZP + 256))
    world.append(box(CX0, CY + 32, ZP, CX1, CY + 40, ZP + 256))
    world.append(box(CX0 - 8, CY - 40, ZP + 96, CX0, CY + 40, ZP + 256))
    world.append(box(CX0 - 8, CY - 40, ZP + 256, CX1 + 8, CY + 40, ZP + 264))

    # Field.
    for kind in KINDS:
        for gate, lane in enumerate(KEEP[kind]):
            cy = lane_y(kind, gate)
            for poly in pattern_polys_2d(kind, lane):
                world.append(prism(poly, cy - LANE_W / 2, cy + LANE_W / 2, KIND_TEX[kind]))

    ents = []
    for i, y in enumerate([-64, 0, 64]):
        ents.append(entity({"classname": "info_player_terrorist", "origin": "-700 %d %d" % (y, ZP + 1), "angles": "0 0 0"}))
        ents.append(entity({"classname": "info_player_counterterrorist", "origin": "-760 %d %d" % (y, ZP + 1), "angles": "0 0 0"}))
    ents.append(entity({"classname": "info_teleport_destination", "targetname": "dest_closet",
                        "origin": "%d %d %d" % ((CX0 + CX1) // 2, CY, ZP + 120), "angles": "0 180 0"}))
    ents.append(entity({"classname": "trigger_teleport", "target": "dest_closet", "spawnflags": "1",
                        "StartDisabled": "0", "origin": "0 0 0"},
                       box(PLAT_EDGE_X - 64, IY0, FLOOR - 1, XMAX - W, IY1, FLOOR + 8, TRIG)))

    lights = [(-900, 0, ZP + 300), (-200, -YSPAN / 3, ZP + 300), (-200, YSPAN / 3, ZP + 300),
              (FIELD_X0 + 300, -YSPAN / 3, ZF + 600), (FIELD_X0 + 300, 0, ZF + 600), (FIELD_X0 + 300, YSPAN / 3, ZF + 600)]
    for i in range(1, 6):
        x = PLAT_EDGE_X + (LIP_X - PLAT_EDGE_X) * i / 6
        z = ZP - (ZP - LIP_Z) * i / 6 + 600
        lights.append((x, 0, z))
    for x, y, z in lights:
        ents.append(entity({"classname": "light", "origin": "%d %d %d" % (x, y, z), "_light": "255 255 255 3000"}))

    return ("versioninfo\n{\n\t\"editorversion\" \"400\"\n\t\"editorbuild\" \"8864\"\n\t\"mapversion\" \"1\"\n"
            "\t\"formatversion\" \"100\"\n\t\"prefab\" \"0\"\n}\n"
            "world\n{\n\t\"id\" \"%d\"\n\t\"mapversion\" \"1\"\n\t\"classname\" \"worldspawn\"\n"
            "\t\"skyname\" \"sky_dust\"\n\t\"maxpropscreenwidth\" \"-1\"\n%s}\n%s"
            % (nid(), "".join(world), "".join(ents)))

if __name__ == "__main__":
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "surf_rngfix_edgebug.vmf")
    with open(path, "w", newline="\n") as f:
        f.write(build())
    print("wrote", path)
    print("ramp lip x %d z %d, field x %d..%d, top z %d" % (LIP_X, LIP_Z, FIELD_X0, FIELD_X0 + FIELD_LEN, ZF))
    print("lane centres (y):")
    for kind in KINDS:
        print("  %-6s %s" % (kind, " ".join("gate %d:%d" % (i + 1, lane_y(kind, i)) for i in range(len(KEEP[kind])))))
