"""Generate surf_rngfix_telehop.vmf, a test box for rngfix_telehop 2 (ordered telehop).

Run:  python make_telehop_test.py   (writes the .vmf next to this script)

Layout (all on a platform at z=2048, spawn at x=128):
  Shaft A   big hole at x -768..-256. Falls ~2000 units onto a floor covered by a 3-unit
            teleport slab. The hull enters the slab before touching the floor -> expect "restore".
  Pad B1    dark pad at (-128, -200). Teleports you to the top of a narrow tube above a 50 degree
            ramp, lined up so you hit the ramp just above the teleport slab and slide into it in
            the same tick -> expect "skip".
  Pad B2    light pad at (-128, 200). Same, but you drop straight into the slab -> expect "restore".
Every teleport slab sends you back to the spawn platform with your velocity kept.
"""
import math, os

TEX = "DEV/DEV_MEASUREGENERIC01B"
TEX_FLOOR = "DEV/DEV_MEASUREGENERIC01"
TEX_DARK = "DEV/REFLECTIVITY_30"
TEX_LIGHT = "DEV/REFLECTIVITY_70"
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

def hexa(bottom4, top4, tex):
    """Eight-vertex brush: bottom and top quads given in the same order as box()."""
    return solid(bottom4 + top4, BOX_FACES, tex)

def entity(kv, solids=""):
    s = "entity\n{\n\t\"id\" \"%d\"\n" % nid()
    for k, v in kv.items():
        s += "\t\"%s\" \"%s\"\n" % (k, v)
    return s + solids + "}\n"

# ---- geometry -------------------------------------------------------------
XMIN, XMAX, YMIN, YMAX, ZTOP = -1024, 1024, -512, 512, 2560
W = 16
PLAT = 2048               # platform top
FLOOR = 16                # room floor top

# 50 degree ramp under the B tubes, descending towards +X: rise 610 over 512 (normal z 0.643, not walkable).
RX0, RX1, RISE = 256, 768, 610
SLOPE = RISE / (RX1 - RX0)
def ramp_z(x): return FLOOR + (RX1 - x) * SLOPE

SLAB_X0 = 512             # teleport slab covers the ramp from here down
SLAB_T = 3                # vertical thickness of the teleport slabs

TUBE_HALF = 17            # 34-unit tube interior for a 32-unit hull: x/y fixed within 1 unit
TUBES = {"b1": 524, "b2": 640}

world = []
# Shell.
world.append(box(XMIN, YMIN, 0, XMAX, YMAX, FLOOR, TEX_FLOOR))
world.append(box(XMIN, YMIN, ZTOP - W, XMAX, YMAX, ZTOP))
world.append(box(XMIN, YMIN, FLOOR, XMIN + W, YMAX, ZTOP - W))
world.append(box(XMAX - W, YMIN, FLOOR, XMAX, YMAX, ZTOP - W))
world.append(box(XMIN + W, YMIN, FLOOR, XMAX - W, YMIN + W, ZTOP - W))
world.append(box(XMIN + W, YMAX - W, FLOOR, XMAX - W, YMAX, ZTOP - W))

# Platform with shaft A's hole at x -768..-256, y -256..256.
IX0, IX1, IY0, IY1 = XMIN + W, XMAX - W, YMIN + W, YMAX - W
world.append(box(IX0, IY0, PLAT - 16, -768, IY1, PLAT))
world.append(box(-256, IY0, PLAT - 16, IX1, IY1, PLAT))
world.append(box(-768, IY0, PLAT - 16, -256, -256, PLAT))
world.append(box(-768, 256, PLAT - 16, -256, IY1, PLAT))

# Pad markers (1 unit tall, walkable).
world.append(box(-160, -232, PLAT, -96, -168, PLAT + 1, TEX_DARK))
world.append(box(-160, 168, PLAT, -96, 232, PLAT + 1, TEX_LIGHT))

# Ramp wedge.
ramp_v = [[RX0, -256, FLOOR], [RX1, -256, FLOOR], [RX1, 256, FLOOR], [RX0, 256, FLOOR],
          [RX0, -256, ramp_z(RX0)], [RX0, 256, ramp_z(RX0)]]
ramp_f = [[0, 1, 2, 3], [0, 3, 5, 4], [1, 2, 5, 4], [0, 1, 4], [3, 2, 5]]
world.append(solid(ramp_v, ramp_f, TEX))

# Tubes: walls from well above the ramp contact (hull top clears the tube when it lands) up to the platform.
tube_bottoms = {}
for name, cx in TUBES.items():
    x0, x1 = cx - TUBE_HALF, cx + TUBE_HALF
    zb = math.ceil(ramp_z(x0) + 72 + 24)
    tube_bottoms[name] = zb
    zt = PLAT - 16
    world.append(box(x0 - 8, -TUBE_HALF - 8, zb, x0, TUBE_HALF + 8, zt))
    world.append(box(x1, -TUBE_HALF - 8, zb, x1 + 8, TUBE_HALF + 8, zt))
    world.append(box(x0, -TUBE_HALF - 8, zb, x1, -TUBE_HALF, zt))
    world.append(box(x0, TUBE_HALF, zb, x1, TUBE_HALF + 8, zt))

ents = []
ents.append(entity({"classname": "worldspawn"}))  # placeholder, replaced below

# Spawns and the return destination.
for i, y in enumerate([-64, 0, 64]):
    ents.append(entity({"classname": "info_player_terrorist", "origin": "128 %d %d" % (y, PLAT + 1), "angles": "0 180 0"}))
    ents.append(entity({"classname": "info_player_counterterrorist", "origin": "192 %d %d" % (y, PLAT + 1), "angles": "0 180 0"}))
ents.append(entity({"classname": "info_teleport_destination", "targetname": "dest_start",
                    "origin": "128 360 %d" % (PLAT + 1), "angles": "0 180 0"}))

def teleport(target, solid_txt):
    return entity({"classname": "trigger_teleport", "target": target, "spawnflags": "1",
                   "StartDisabled": "0", "origin": "0 0 0"}, solid_txt)

# Shaft A floor slab.
ents.append(teleport("dest_start", box(-800, -288, FLOOR - 1, -224, 288, FLOOR + SLAB_T, TRIG)))

# Ramp slab: vertical end at SLAB_X0, follows the ramp surface down to the floor.
sb = [[SLAB_X0, -256, ramp_z(SLAB_X0) - 1], [RX1, -256, FLOOR - 1], [RX1, 256, FLOOR - 1], [SLAB_X0, 256, ramp_z(SLAB_X0) - 1]]
st = [[SLAB_X0, -256, ramp_z(SLAB_X0) + SLAB_T], [RX1, -256, FLOOR + SLAB_T], [RX1, 256, FLOOR + SLAB_T], [SLAB_X0, 256, ramp_z(SLAB_X0) + SLAB_T]]
ents.append(teleport("dest_start", hexa(sb, st, TRIG)))

# Pads and tube tops.
for name, cx, py in (("b1", TUBES["b1"], -200), ("b2", TUBES["b2"], 200)):
    ents.append(entity({"classname": "info_teleport_destination", "targetname": "dest_" + name,
                        "origin": "%d 0 %d" % (cx, PLAT - 160), "angles": "0 0 0"}))
    ents.append(teleport("dest_" + name, box(-160, py - 32, PLAT + 1, -96, py + 32, PLAT + 72, TRIG)))

# Lights above and below the platform (the map also works fullbright without vrad).
for x, z in ((-600, 2400), (0, 2400), (600, 2400), (-512, 1200), (512, 1200), (-512, 400), (900, 400)):
    ents.append(entity({"classname": "light", "origin": "%d 0 %d" % (x, z), "_light": "255 255 255 1200"}))

ents.pop(0)
vmf = ("versioninfo\n{\n\t\"editorversion\" \"400\"\n\t\"editorbuild\" \"8864\"\n\t\"mapversion\" \"1\"\n"
       "\t\"formatversion\" \"100\"\n\t\"prefab\" \"0\"\n}\n"
       "world\n{\n\t\"id\" \"%d\"\n\t\"mapversion\" \"1\"\n\t\"classname\" \"worldspawn\"\n"
       "\t\"skyname\" \"sky_dust\"\n\t\"maxpropscreenwidth\" \"-1\"\n%s}\n%s"
       % (nid(), "".join(world), "".join(ents)))

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "surf_rngfix_telehop.vmf")
with open(path, "w", newline="\n") as f:
    f.write(vmf)

print("wrote", path)
print("tube bottoms:", tube_bottoms)
for name, cx in TUBES.items():
    # Ramp contact is at the hull's -X bottom edge; the slab is entered once the hull is below its top at SLAB_X0.
    contact_z = ramp_z(cx - 16)
    slab_top = ramp_z(SLAB_X0) + SLAB_T
    order = "slab first (restore)" if contact_z <= slab_top else "ramp first by %.2f z (skip)" % (contact_z - slab_top)
    print("%s cx=%d: contact z %.2f, slab top %.2f -> %s" % (name, cx, contact_z, slab_top, order))
