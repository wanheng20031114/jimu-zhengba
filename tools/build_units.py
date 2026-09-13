"""Original low-poly unit sculptures, authored offline and exported to native Godot scenes.

All small fittings are consolidated per rigid part. The saved .tscn contains the
actual joint hierarchy and AnimationPlayers; no geometry is generated at runtime.
"""
from pathlib import Path
from collections import defaultdict
import math
import json
import numpy as np
import trimesh as tm
from scipy.spatial.transform import Rotation

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/models/units"
OUT.mkdir(parents=True, exist_ok=True)
P = {
    "steel": (118, 135, 143), "edge": (174, 186, 184),
    "darksteel": (59, 70, 77), "gold": (196, 147, 64),
    "goldlight": (231, 186, 91), "blue": (44, 87, 126),
    "leather": (89, 53, 33), "leatherlight": (126, 78, 41),
    "wood": (111, 70, 35), "woodlight": (158, 106, 57),
    "wooddark": (70, 44, 28), "rope": (168, 142, 90),
    "black": (26, 29, 29), "skin": (201, 150, 106),
    "ivory": (226, 216, 183), "horse": (132, 84, 49),
    "horselight": (161, 111, 65), "mane": (51, 38, 28),
    "bronze": (122, 110, 69), "bronzelight": (171, 147, 82),
    "elephant": (120, 126, 124), "elephantlight": (147, 150, 141),
    "elephantdark": (91, 100, 99),
}
METALS = {"steel", "edge", "darksteel", "gold", "goldlight", "bronze", "bronzelight"}


def matrix(pos=(0, 0, 0), rot=(0, 0, 0)):
    m = tm.transformations.euler_matrix(*rot)
    m[:3, 3] = pos
    return m


def box(size, pos=(0, 0, 0), rot=(0, 0, 0), bevel=0.0):
    size = np.array(size, float)
    if bevel:
        half = size / 2
        b = min(bevel, min(half) * .6)
        verts = []
        for sx in (-1, 1):
            for sy in (-1, 1):
                for sz in (-1, 1):
                    sign = np.array((sx, sy, sz))
                    for axis in range(3):
                        v = (half - b) * sign
                        v[axis] = half[axis] * sign[axis]
                        verts.append(v)
        mesh = tm.convex.convex_hull(np.array(verts))
    else:
        mesh = tm.creation.box(size)
    mesh.apply_transform(matrix(pos, rot))
    return mesh


def ellipsoid(size, pos=(0, 0, 0), rot=(0, 0, 0), sub=1):
    mesh = tm.creation.icosphere(subdivisions=sub, radius=1)
    mesh.apply_scale(size)
    mesh.apply_transform(matrix(pos, rot))
    return mesh


def rod(a, b, radius, sections=8, r2=None):
    a, b = np.array(a, float), np.array(b, float)
    d = b - a
    if r2 is None:
        mesh = tm.creation.cylinder(radius=radius, height=np.linalg.norm(d), sections=sections)
    else:
        mesh = lathe([(0, radius), (np.linalg.norm(d), r2)], sections)
        mesh.apply_translation((0, -np.linalg.norm(d) / 2, 0))
        mesh.apply_transform(tm.transformations.rotation_matrix(math.pi / 2, (1, 0, 0)))
    m = tm.geometry.align_vectors((0, 0, 1), d)
    m[:3, 3] = (a + b) / 2
    mesh.apply_transform(m)
    return mesh


def lathe(profile, sections=12, pos=(0, 0, 0), rot=(0, 0, 0), caps=True):
    verts = [(r * math.cos(a * math.tau / sections), y,
              r * math.sin(a * math.tau / sections))
             for y, r in profile for a in range(sections)]
    faces = []
    for k in range(len(profile) - 1):
        for i in range(sections):
            j = (i + 1) % sections
            a, b, c, d = k*sections+i, k*sections+j, (k+1)*sections+j, (k+1)*sections+i
            faces.extend(((a, c, b), (a, d, c)))
    if caps:
        for row, reverse in ((0, True), (len(profile) - 1, False)):
            center = len(verts)
            verts.append((0, profile[row][0], 0))
            for i in range(sections):
                tri = (center, row * sections + i, row * sections + (i + 1) % sections)
                faces.append(tri[::-1] if reverse else tri)
    mesh = tm.Trimesh(vertices=verts, faces=faces, process=False)
    mesh.fix_normals()
    mesh.apply_transform(matrix(pos, rot))
    return mesh


def polygon(points, depth, pos=(0, 0, 0), rot=(0, 0, 0)):
    verts = [(x, y, z) for z in (-depth / 2, depth / 2) for x, y in points]
    mesh = tm.convex.convex_hull(np.array(verts))
    mesh.apply_transform(matrix(pos, rot))
    return mesh


def ring(radius, minor, pos=(0, 0, 0), rot=(0, 0, 0), n=16, m=4):
    mesh = tm.creation.torus(major_radius=radius, minor_radius=minor,
                            major_sections=n, minor_sections=m)
    mesh.apply_transform(matrix(pos, rot))
    return mesh


class Sculpture:
    def __init__(self, name):
        self.name = name
        self.parts = {}
        self.joints = {}
        self.parents = {}
        self.pivots = {}

    def joint(self, name, pos=(0, 0, 0), parent=None):
        self.parts[name] = defaultdict(list)
        self.joints[name] = pos
        self.parents[name] = parent
        return name

    def part_path(self, part):
        return self.part_path(self.parents[part]) + "/" + part if self.parents[part] else "Rig/Action/" + part

    def pivot(self, name, pos=(0,0,0), parent=None):
        self.pivots[name] = True
        self.joints[name] = pos
        self.parents[name] = parent
        return name

    def reparent(self, part, parent):
        # Authoring poses contain no initial rotations, so subtraction preserves
        # the sculpture's exact world-space geometry while inserting a joint.
        self.joints[part] = tuple(np.array(self.joints[part])-np.array(self.joints[parent]))
        self.parents[part] = parent

    def add(self, part, mesh, color, shade=1.0):
        srgb = np.clip(np.array(P[color], float) * shade / 255.0, 0, 1)
        c = np.where(srgb <= .04045, srgb / 12.92, ((srgb + .055) / 1.055) ** 2.4) * 255.0
        # Vertex paint supplies deliberate planar color variation without textures.
        colors = np.tile(np.append(np.clip(c, 0, 255), 255).astype(np.uint8), (len(mesh.vertices), 1))
        mesh.visual = tm.visual.ColorVisuals(mesh=mesh, vertex_colors=colors)
        category = "Heraldry" if color == "blue" else "ForgedMetal" if color in METALS else "PaintedMatte"
        self.parts[part][category].append(mesh)

    def b(self, part, size, pos, color, rot=(0, 0, 0), bevel=.02):
        self.add(part, box(size, pos, rot, bevel), color)

    def r(self, part, a, b, radius, color, sections=8, r2=None):
        self.add(part, rod(a, b, radius, sections, r2), color)

    def e(self, part, size, pos, color, rot=(0, 0, 0), sub=1):
        self.add(part, ellipsoid(size, pos, rot, sub), color)

    def save(self):
        folder = OUT / self.name
        folder.mkdir(exist_ok=True)
        counts = []
        for part, categories in self.parts.items():
            scene = tm.Scene()
            combined=[]
            for category, pieces in categories.items():
                for piece in pieces:
                    color=piece.visual.vertex_colors.copy()
                    # Alpha is a material tag, never transparency: 0 matte, 128
                    # forged metal, 255 heraldry. The shared native shader reads it.
                    color[:,3]=255 if category=="Heraldry" else 128 if category=="ForgedMetal" else 0
                    piece.visual=tm.visual.ColorVisuals(mesh=piece,vertex_colors=color)
                    combined.append(piece)
            merged=tm.util.concatenate(combined)
            merged.unmerge_vertices()
            material=tm.visual.material.PBRMaterial(name="UnitSurface",
                baseColorFactor=[255,255,255,255],metallicFactor=0,roughnessFactor=.8,
                alphaMode="OPAQUE",doubleSided=False)
            color=merged.visual.vertex_colors.copy()
            merged.visual=tm.visual.TextureVisuals(material=material)
            merged.visual.vertex_attributes['color']=color
            scene.add_geometry(merged,node_name="Sculpture",geom_name="Sculpture")
            counts.append(len(merged.faces))
            (folder / f"{part}.glb").write_bytes(scene.export(file_type="glb", include_normals=True))
        (folder/"parts.json").write_text(json.dumps(list(self.parts)),encoding="utf-8")
        write_scene(self)
        print(f"{self.name}: {len(self.parts)} rigid parts, {sum(counts):,} triangles")


def rivets(s, p, positions, r=.021, color="gold"):
    for v in positions:
        s.e(p, (r, r, r * .55), v, color)


def shield(s, p, center, large=False):
    x, y, z = center
    scale = 1.1 if large else 1
    pts = [(-.29, .34), (.29, .34), (.28, -.09), (0, -.43), (-.28, -.09)]
    s.add(p, polygon([(a * scale, b * scale) for a,b in pts], .095, center), "gold")
    s.add(p, polygon([(a * scale * .84, b * scale * .84) for a,b in pts], .025,
                     (x, y, z - .058)), "blue")
    # Raised heraldic sun-and-cross, readable from the tactical camera.
    s.b(p, (.055, .53 * scale, .022), (x, y + .015, z - .078), "goldlight", bevel=.006)
    s.b(p, (.38 * scale, .055, .022), (x, y + .075, z - .079), "goldlight", bevel=.006)
    s.e(p, (.070, .070, .033), (x, y + .075, z - .09), "gold")
    rivets(s,p,[(x+a*.91*scale,y+b*.91*scale,z-.059) for a,b in pts],.017)


def sword(s, p, center, length=.84):
    x,y,z = center
    s.r(p,(x,y-.14,z),(x,y+.055,z),.035,"leather",8)
    for yy in (-.10,-.05,0):
        s.add(p, ring(.036,.008,(x,y+yy,z),(math.pi/2,0,0),n=8),"gold")
    s.e(p,(.052,.049,.044),(x,y-.17,z),"gold")
    s.b(p,(.30,.057,.070),(x,y+.075,z),"gold",rot=(0,0,.05))
    s.add(p,polygon([(-.054,0),(.054,0),(.044,length-.15),(0,length),(-.044,length-.15)],
                    .034,(x,y+.1,z)),"edge")
    s.b(p,(.014,length-.18,.008),(x,y+.1+(length-.18)/2,z-.022),"steel",bevel=.002)


def helmet(s, p, center, knight=False):
    x,y,z = center
    s.add(p, lathe([(-.12,.29),(0,.33),(.14,.29),(.24,.20),(.29,.075)],12,center),"steel")
    s.add(p, lathe([(-.13,.304),(-.08,.335),(-.045,.333)],12,center,caps=False),"gold" if knight else "edge")
    # Broad recessed eye opening, separated cheek plates and raised nose guard.
    s.b(p,(.42,.15,.095),(x,y-.16,z-.218),"black",bevel=.035)
    for sign in (-1,1):
        s.add(p,polygon([(-.095,.08),(.095,.08),(.072,-.15),(-.07,-.20)],.04,
                        (x+sign*.155,y-.225,z-.262),(0,sign*.22,sign*.08)),"steel")
    s.b(p,(.059,.25,.048),(x,y-.16,z-.292),"edge",bevel=.012)
    s.b(p,(.43,.030,.04),(x,y-.101,z-.283),"edge",bevel=.006)
    rivets(s,p,[(x+xx,y-.05,z-.319) for xx in (-.22,-.11,0,.11,.22)],.017)
    # Crest ridge and cloth plume.
    s.b(p,(.052,.25,.12),(x,y+.20,z+.015),"gold" if knight else "edge",bevel=.022)
    if knight:
        for i in range(5):
            s.e(p,(.083,.12,.15),(x,y+.29-i*.016,z+.05+i*.10),"blue",rot=(.35,0,0))


def infantry(name, archer=False):
    s = Sculpture(name)
    body=s.joint("Body",(0,1.05,0))
    head=s.joint("Head",(0,1.57,0))
    left=s.joint("ArmLeft",(-.34,1.28,0))
    right=s.joint("ArmRight",(.34,1.28,0))
    ll=s.joint("LegLeft",(-.155,.75,0))
    lr=s.joint("LegRight",(.155,.75,0))
    # Tailored tunic: taper at waist and split skirt over a dark mail undersuit.
    s.add(body,lathe([(-.28,.28),(-.08,.25),(.21,.33),(.31,.27)],8),"blue")
    s.b(body,(.46,.14,.33),(0,-.05,0),"leather",bevel=.025)
    s.b(body,(.11,.10,.040),(0,-.047,-.19),"gold")
    for xx in (-.18,.18):
        s.b(body,(.15,.29,.09),(xx,-.27,-.15),"blue",rot=(0,0,-xx*.38))
        s.b(body,(.15,.026,.10),(xx,-.42,-.15),"gold",rot=(0,0,-xx*.38),bevel=.003)
    if archer:
        s.b(body,(.32,.40,.13),(0,.08,-.23),"leatherlight",bevel=.06)
        s.b(body,(.09,.69,.05),(0,.06,-.275),"leather",rot=(0,0,-.38))
        s.b(body,(.20,.045,.055),(-.05,.15,-.315),"gold",rot=(0,0,-.38))
        # Rolled hood and dark felt cap framing an expressive face.
        s.e(head,(.28,.29,.27),(0,-.01,.01),"blue",sub=2)
        s.e(head,(.213,.221,.198),(0,-.015,-.139),"skin",sub=1)
        s.b(head,(.41,.065,.23),(0,.113,-.17),"blue",bevel=.035)
        s.e(head,(.27,.13,.26),(0,.21,.01),"blue")
        for xx in (-.081,.081):
            s.b(head,(.040,.025,.014),(xx,.020,-.320),"black",bevel=.004)
            s.b(head,(.07,.026,.017),(xx,.067,-.305),"leather",rot=(0,0,xx),bevel=.004)
        s.e(head,(.045,.064,.074),(0,-.044,-.311),"skin")
        s.b(head,(.14,.044,.041),(0,-.106,-.3),"leather",bevel=.011)
        # Leather quiver, contrasting lip, individual shafts and fletching.
        s.add(body,lathe([(-.29,.108),(.28,.145),(.32,.145)],10,(.19,.03,.29),(0,0,-.14)),"leather")
        s.add(body,lathe([(.23,.149),(.29,.149)],10,(.19,.03,.29),(0,0,-.14),caps=False),"gold")
        for i in range(6):
            xx=.1+(i%3)*.067; zz=.25+(i//3)*.095; yy=.54+(.045*(i%2))
            s.r(body,(xx,.13,zz),(xx+.045,yy,zz),.012,"woodlight",6)
            s.b(body,(.073,.103,.008),(xx+.038,yy-.018,zz),"ivory",rot=(0,0,-.12),bevel=.002)
    else:
        # Leave a visible throat gap between the breastplate and cheek guards.
        s.b(body,(.47,.35,.14),(0,.065,-.295 if name=="spearman" else -.20),"steel",bevel=.060)
        s.b(body,(.035,.31,.024),(0,.065,-.377 if name=="spearman" else -.282),"edge",bevel=.006)
        for sign in (-1,1):
            for i in range(3):
                s.b(body,(.20,.065,.095),(sign*.145,-.24-i*.060,-.175),"darksteel",rot=(0,0,-sign*.09),bevel=.016)
        if name=="spearman":
            # Keep the torso protected like the swordsman, including a readable
            # back plate. The exposed head and wooden shield carry the contrast.
            s.b(body,(.46,.37,.13),(0,.075,.295),"steel",bevel=.055)
            s.b(body,(.035,.30,.026),(0,.075,.370),"edge",bevel=.006)
            for sign in (-1,1):
                s.b(body,(.080,.28,.40),(sign*.27,.045,.005),"darksteel",bevel=.025)
                s.b(body,(.12,.055,.12),(sign*.18,.21,.32),"leather",bevel=.012)
            # A soft cloth cap, cropped hair and exposed ears give the levy a
            # light, open silhouette next to the swordsman's armored helmet.
            s.e(head,(.225,.235,.215),(0,-.005,-.055),"skin")
            s.e(head,(.225,.19,.17),(0,.055,.038),"leather")
            s.e(head,(.245,.135,.23),(.018,.205,-.005),"blue",rot=(0,0,-.10))
            s.add(head,lathe([(.115,.223),(.163,.228)],12,(0,0,-.015),caps=False),"leatherlight")
            s.b(head,(.115,.075,.035),(-.104,.117,-.210),"leather",rot=(0,0,-.22),bevel=.012)
            s.b(head,(.09,.055,.035),(.024,.129,-.217),"leather",rot=(0,0,.12),bevel=.012)
            for sign in (-1,1):
                s.e(head,(.045,.066,.039),(sign*.223,.007,-.057),"skin")
                s.b(head,(.035,.115,.11),(sign*.211,.018,.015),"leather",bevel=.012)
            # Eyes sit above the middle of the exposed face; keep each fitting
            # just outside the faceted skin instead of down at the jawline.
            for xx in (-.075,.075):
                s.b(head,(.035,.025,.019),(xx,.025,-.264),"black",bevel=.003)
                s.b(head,(.055,.014,.018),(xx,.061,-.251),"leather",bevel=.002)
            s.e(head,(.04,.055,.05),(0,-.035,-.270),"skin")
            s.b(head,(.060,.014,.015),(0,-.103,-.250),"leather",bevel=.003)
            s.r(head,(0,-.29,.005),(0,-.16,.005),.104,"skin",8)
        else:
            helmet(s,head,(0,.055,-.10))
    for part,sign in ((left,-1),(right,1)):
        s.e(part,(.235,.18,.24),(sign*.04,.018,0),"leather" if archer else "steel")
        if not archer:
            s.b(part,(.32,.032,.31),(sign*.04,.024,-.042),"edge",rot=(0,0,sign*.13),bevel=.020)
        # A shield is carried on a bent forearm ahead of the breastplate. The
        # shoulder remains at its authored joint; moving the entire ArmLeft
        # instead would detach the pauldron from the torso during a strike.
        shield_arm = not archer and sign < 0
        sword_arm = not archer and sign > 0
        elbow = (-.13,-.30,-.035) if shield_arm else (sign*.10,-.30,-.04)
        wrist = (-.21,-.42,-.25) if shield_arm else (sign*.11,-.49,-.11)
        hand = (-.22,-.43,-.28) if shield_arm else (sign*.12,-.54,-.115)
        if sword_arm:
            elbow, wrist, hand = (.13,-.27,-.05), (.24,-.40,-.41), (.25,-.445,-.45)
        s.r(part,(sign*.045,-.08,0),elbow if shield_arm or sword_arm else (sign*.10,-.33,-.04),.106,"blue",8)
        s.e(part,(.115,.10,.11),elbow if shield_arm or sword_arm else (sign*.10,-.30,-.055),"darksteel" if not archer else "leather")
        fore=part
        origin=np.zeros(3)
        if archer and sign==1:
            origin=np.array((.10,-.30,-.04))
            fore=s.joint("ForearmRight",tuple(origin),parent=right)
        local=lambda p: tuple(np.array(p)-origin)
        s.r(fore,local(elbow),local(wrist),.100,"steel" if not archer else "leatherlight",8)
        cuff = (-.21,-.410,-.235) if shield_arm else (sign*.11,-.475,-.10)
        if sword_arm:
            cuff = (.23,-.385,-.395)
        s.b(fore,(.17,.085,.15),local(cuff),"gold" if not archer else "leather",bevel=.025)
        s.e(fore,(.097,.093,.1),local(hand),"skin" if archer else "darksteel")
        studs = [(-.17,-.35,-.14),(-.195,-.39,-.21)] if shield_arm else ([(.18,-.31,-.22),(.22,-.36,-.35)] if sword_arm else [(sign*.10,-.37,-.144),(sign*.10,-.44,-.15)])
        rivets(s,fore,[local(v) for v in studs],.015)
    for part in (ll,lr):
        s.r(part,(0,.01,0),(0,-.29,.02),.116,"leather" if archer else "darksteel",8)
        s.e(part,(.12,.11,.11),(0,-.28,-.033),"leatherlight" if archer else "steel")
        s.b(part,(.18,.25,.155),(0,-.43,-.01),"leather" if archer else "steel",bevel=.03)
        s.b(part,(.213,.17,.33),(0,-.65,-.075),"leather",bevel=.044)
        s.b(part,(.22,.045,.34),(0,-.714,-.07),"black",bevel=.012)
        s.b(part,(.21,.036,.18),(0,-.53,-.025),"gold" if not archer else "leatherlight",bevel=.01)
    if archer:
        # Long laminated bow held ahead of the body; string has its own visible V.
        bow=s.joint("Bow",(-.115,-.54,-.13),parent=left)
        bow_points=[(0,-.57,.12),(0,-.43,.045),(0,-.23,-.025),(0,0,0),(0,.23,-.025),(0,.43,.045),(0,.57,.12)]
        for a,b in zip(bow_points,bow_points[1:]):
            s.r(bow,a,b,.032,"woodlight",8)
        s.r(bow,(0,-.10,0),(0,.10,0),.041,"leather",8)
        for name in ("StringUpper","StringLower"):
            string=s.joint(name,(0,0,.14),parent=bow)
            s.r(string,(0,0,0),(0,1,0),.008,"rope",6)
        # Readied arrow points along the forward axis.
        arrow=s.joint("Arrow",(0,0,.14),parent=bow)
        s.r(arrow,(0,0,0),(0,0,-.95),.014,"woodlight",6)
        s.add(arrow,polygon([(-.046,0),(.046,0),(0,.12)],.020,(0,0,-.975),(math.pi/2,0,0)),"edge")
        s.b(arrow,(.10,.015,.13),(0,0,-.08),"ivory",bevel=.004)
    else:
        if name=="spearman":
            # Four unpainted planks and a narrow leather binding: a small wooden
            # buckler with no heraldic cross, broad metal rim or armored boss.
            center=(-.24,-.37,-.465)
            shield_radius=.25
            s.r(left,(-.24,-.37,-.395),(-.24,-.37,-.451),shield_radius,"wooddark",16)
            for index, (a,b) in enumerate([(-.247,-.126),(-.12,-.003),(.003,.12),(.126,.247)]):
                xs=np.linspace(a,b,5)
                arc=[(x,math.sqrt(shield_radius**2-x*x)) for x in xs]
                outline=arc+[(x,-y) for x,y in reversed(arc)]
                s.add(left,polygon(outline,.018,center),"woodlight" if index%2 else "wood")
            s.add(left,ring(.25,.012,center,n=16),"leather")
            for xx in (-.16,.16):
                for yy in (-.12,.12):
                    s.e(left,(.012,.012,.007),(-.24+xx,-.37+yy,-.480),"darksteel")
        else:
            shield(s,left,(-.24,-.37,-.425))
        # Back grip meets the gauntlet while the board clears the breastplate.
        s.r(left,(-.28,-.43,-.37),(-.16,-.43,-.37),.025,"leather",8)
        # A wrist pivot keeps the hilt inside the gauntlet while the blade leads
        # the cut. The arm no longer swings an upright sword as a rigid paddle.
        if name=="spearman":
            spear=s.joint("Spear",(.25,-.445,-.45),parent=right)
            s.r(spear,(0,-.68,0),(0,1.37,0),.032,"woodlight",10)
            s.r(spear,(0,-.72,0),(0,-.57,0),.037,"darksteel",8,r2=.029)
            s.r(spear,(0,-.12,0),(0,.13,0),.039,"leather",10)
            for y in np.linspace(-.1,.1,5):
                s.add(spear,ring(.04,.005,(0,y,0),(math.pi/2,0,0),n=10),"rope")
            s.r(spear,(0,1.18,0),(0,1.40,0),.05,"steel",8,r2=.033)
            s.add(spear,polygon([(-.035,0),(-.105,.17),(0,.52),(.105,.17),(.035,0)],.044,(0,1.35,0)),"edge")
            s.r(spear,(0,1.37,-.025),(0,1.79,-.025),.015,"steel",6,r2=.004)
            s.r(spear,(0,1.18,0),(0,1.22,0),.054,"gold",10)
        else:
            blade = s.joint("Sword",(.25,-.415,-.45),parent=right)
            sword(s,blade,(0,0,0))
        # Sheath and a small hip pouch complete the back and side silhouette.
        s.b(body,(.082,.58,.084),(-.27,-.25,.1),"leather",rot=(0,0,-.16))
        s.b(body,(.15,.17,.12),(.265,-.13,.08),"leatherlight",bevel=.025)
        s.b(body,(.10,.026,.02),(.265,-.11,.014),"gold",bevel=.004)
    waist=s.pivot("Waist",(0,1.05,0))
    for p in (body,head,left,right):
        s.reparent(p,waist)
    return s


def shield_guard():
    """Armored infantry with an open eye slit and a tall forearm-mounted shield."""
    s = Sculpture("shield_guard")
    body = s.joint("Body", (0, 1.05, 0))
    head = s.joint("Head", (0, 1.65, 0))
    left = s.joint("ArmLeft", (-.38, 1.31, 0))
    right = s.joint("ArmRight", (.38, 1.31, 0))
    legs = [s.joint("LegLeft", (-.18, .75, 0)), s.joint("LegRight", (.18, .75, 0))]
    s.add(body, lathe([(-.29,.30),(-.09,.27),(.22,.35),(.34,.28)], 8), "blue")
    s.b(body, (.56,.40,.14), (0,.08,-.31), "steel", bevel=.07)
    s.b(body, (.035,.35,.022), (0,.08,-.391), "edge", bevel=.007)
    s.b(body, (.52,.39,.13), (0,.08,.31), "steel", bevel=.06)
    s.b(body, (.035,.32,.023), (0,.08,.385), "edge", bevel=.006)
    for sign in (-1,1):
        s.b(body, (.095,.32,.44), (sign*.28,.055,0), "darksteel", bevel=.025)
        s.b(body, (.11,.045,.60), (sign*.19,.28,0), "leather", bevel=.012)
        for i in range(3):
            s.b(body, (.245,.075,.115), (sign*.145,-.23-i*.06,-.235), "steel", rot=(0,0,-sign*.06), bevel=.015)
        s.b(body, (.19,.28,.08), (sign*.17,-.30,.20), "blue", bevel=.02)
        s.b(body, (.19,.025,.09), (sign*.17,-.43,.20), "gold", bevel=.004)
    s.b(body, (.57,.105,.055), (0,-.15,-.305), "leather", bevel=.012)
    s.b(body, (.115,.09,.035), (0,-.15,-.347), "gold", bevel=.01)
    s.r(head, (0,-.30,0), (0,-.17,0), .105, "darksteel", 8)
    s.e(head, (.226,.233,.217), (0,-.018,-.055), "skin")
    # The cap starts above the eyes. Separate cheek plates leave a real opening,
    # so the face does not disappear under a solid dark visor or low helmet rim.
    s.add(head, lathe([(.115,.286),(.20,.30),(.31,.225),(.37,.10)], 12, (0,0,-.025)), "steel")
    s.add(head, lathe([(.105,.298),(.145,.307)], 12, (0,0,-.025), caps=False), "edge")
    s.b(head, (.06,.13,.18), (0,.355,.015), "edge", bevel=.025)
    s.b(head, (.40,.29,.075), (0,-.035,.192), "steel", bevel=.035)
    s.b(head, (.42,.027,.075), (0,-.174,.192), "edge", bevel=.006)
    for sign in (-1,1):
        s.b(head, (.065,.245,.205), (sign*.231,-.022,.095), "steel", bevel=.025)
        s.add(head, polygon([(-.095,.08),(.095,.08),(.07,-.16),(-.06,-.20)], .05,
            (sign*.205,-.065,-.21), (0,sign*.35,sign*.08)), "steel")
        s.e(head, (.061,.095,.09), (sign*.231,-.008,.01), "darksteel")
        s.b(head, (.033,.024,.018), (sign*.077,.060,-.270), "black", bevel=.003)
        s.b(head, (.06,.018,.017), (sign*.078,.093,-.253), "leather", bevel=.003)
    s.e(head, (.041,.059,.049), (0,-.009,-.286), "skin")
    s.b(head, (.065,.017,.018), (0,-.105,-.270), "leather", bevel=.003)
    s.b(head, (.039,.195,.033), (0,.012,-.329), "edge", bevel=.008)
    for part, sign in ((left,-1),(right,1)):
        s.e(part, (.24,.18,.25), (sign*.025,.008,0), "steel")
        s.b(part, (.32,.034,.34), (sign*.03,.006,-.035), "edge", rot=(0,0,sign*.12), bevel=.02)
        elbow = (-.075,-.275,-.06) if sign < 0 else (.105,-.27,-.055)
        wrist = (.035,-.345,-.315) if sign < 0 else (.20,-.415,-.355)
        hand = (.05,-.36,-.36) if sign < 0 else (.215,-.455,-.405)
        s.r(part, (sign*.035,-.075,0), elbow, .11, "blue", 8)
        s.e(part, (.118,.10,.115), elbow, "darksteel")
        s.r(part, elbow, wrist, .103, "steel", 8)
        s.b(part, (.18,.075,.16), wrist, "edge", bevel=.025)
        s.e(part, (.095,.092,.10), hand, "darksteel")
    # The board is centered ahead of the left breast, leaving the sword lane free.
    center = (.055,-.31,-.56)
    outline = [(-.41,.51),(-.30,.63),(.30,.63),(.41,.51),(.39,-.47),(.26,-.61),(-.26,-.61),(-.39,-.47)]
    s.add(left, polygon(outline,.12,center), "darksteel")
    s.add(left, polygon([(x*.88,y*.93) for x,y in outline],.018,(center[0],center[1],-.488)), "wood")
    s.add(left, polygon([(x*.86,y*.91) for x,y in outline],.025,(center[0],center[1],-.636)), "blue")
    # Broad forged edging, restrained heraldry, visible back braces and grip.
    for a,b in zip(outline, outline[1:]+outline[:1]):
        s.r(left, (center[0]+a[0],center[1]+a[1],-.622), (center[0]+b[0],center[1]+b[1],-.622), .022, "edge", 6)
    s.b(left, (.058,.97,.028), (center[0],center[1],-.666), "gold", bevel=.007)
    s.b(left, (.48,.055,.029), (center[0],center[1]+.23,-.667), "gold", bevel=.007)
    s.e(left, (.075,.075,.030), (center[0],center[1]+.23,-.693), "goldlight")
    for x,y in outline:
        s.r(left, (center[0]+x*.91,center[1]+y*.94,-.637), (center[0]+x*.91,center[1]+y*.94,-.654), .018, "gold", 6)
    for yy in (-.58,-.10):
        s.b(left, (.59,.065,.043), (center[0],yy,-.458), "leather", bevel=.009)
    s.r(left, (-.025,-.36,-.435), (-.025,-.36,-.35), .024, "steel", 6)
    s.r(left, (.135,-.36,-.435), (.135,-.36,-.35), .024, "steel", 6)
    s.r(left, (-.025,-.36,-.35), (.135,-.36,-.35), .030, "leather", 8)
    for part in legs:
        s.r(part, (0,.01,0), (0,-.29,.02), .123, "darksteel", 8)
        s.e(part, (.132,.114,.12), (0,-.28,-.03), "steel")
        s.b(part, (.205,.27,.17), (0,-.44,-.018), "steel", bevel=.04)
        s.b(part, (.035,.23,.022), (0,-.44,-.113), "edge", bevel=.005)
        s.b(part, (.225,.17,.34), (0,-.65,-.075), "leather", bevel=.044)
        s.b(part, (.235,.045,.35), (0,-.714,-.07), "black", bevel=.012)
        s.b(part, (.218,.038,.19), (0,-.535,-.025), "edge", bevel=.008)
    blade = s.joint("Sword", (.215,-.425,-.405), parent=right)
    sword(s, blade, (0,0,0), length=.63)
    s.b(body, (.09,.47,.09), (.30,-.25,.15), "leather", rot=(0,0,.13), bevel=.018)
    waist = s.pivot("Waist", (0,1.05,0))
    for part in (body,head,left,right):
        s.reparent(part,waist)
    return s


def horse_knight():
    s=Sculpture("knight")
    b=s.joint("Body",(0,1.10,0))
    # Strong horse silhouette: chest, barrel, rump and angular sloping neck.
    s.e(b,(.43,.44,.77),(0,0,.06),"horse",sub=2)
    s.e(b,(.39,.41,.37),(0,.018,-.49),"horselight",sub=1)
    s.e(b,(.44,.43,.40),(0,.02,.62),"horse",sub=1)
    s.e(b,(.25,.52,.31),(0,.38,-.62),"horselight",rot=(-.43,0,0),sub=1)
    s.e(b,(.225,.23,.37),(0,.72,-.89),"horse",rot=(.38,0,0),sub=1)
    s.e(b,(.207,.185,.22),(0,.56,-1.17),"horselight",sub=1)
    s.e(b,(.16,.11,.08),(0,.52,-1.36),"mane")
    for sign in (-1,1):
        s.add(b,polygon([(-.06,0),(.06,0),(.025,.25)],.11,(sign*.13,.9,-.79),(0,sign*.18,sign*.15)),"horse")
        s.e(b,(.017,.041,.041),(sign*.205,.76,-1.05),"black")
        s.e(b,(.008,.013,.013),(sign*.22,.77,-1.059),"ivory")
        s.b(b,(.042,.14,.37),(sign*.208,.55,-1.14),"leather",rot=(.34,0,0),bevel=.008)
        s.r(b,(sign*.22,.61,-1.21),(sign*.24,.68,-.54),.017,"rope",6)
        s.r(b,(sign*.24,.68,-.54),(sign*.26,.73,-.17),.017,"rope",6)
        s.add(b,ring(.056,.010,(sign*.224,.58,-1.205),(0,math.pi/2,0),n=10),"gold")
    s.b(b,(.43,.055,.073),(0,.49,-1.32),"leather",rot=(.16,0,0))
    # Scalloped dark mane, tail with multiple individually sculpted locks.
    for i in range(7):
        s.e(b,(.076,.145,.13),(0,.79-i*.07,-.65+i*.083),"mane",rot=(-.5,0,0))
    for i in range(5):
        s.e(b,(.10-i*.01,.22,.12),(0,.1-i*.15,.86+i*.078),"mane",rot=(-.32,0,0))
    # Blue horse caparison and gold-edged saddle blanket.
    for sign in (-1,1):
        s.add(b,polygon([(-.52,.27),(.46,.27),(.48,-.14),(.27,-.33),(-.44,-.27)],.035,
                        (sign*.425,-.02,.06),(0,math.pi/2,0)),"blue")
        s.b(b,(.047,.035,.89),(sign*.454,-.245,.08),"gold",rot=(.035,0,0),bevel=.006)
        s.b(b,(.051,.25,.042),(sign*.449,-.048,-.08),"goldlight",bevel=.005)
        s.b(b,(.051,.040,.22),(sign*.451,-.01,-.08),"goldlight",bevel=.005)
        s.b(b,(.055,.44,.087),(sign*.32,.27,.10),"leather",rot=(0,0,sign*.18),bevel=.01)
        s.add(b,ring(.09,.016,(sign*.37,.03,.09),(0,math.pi/2,0),n=10),"darksteel")
    s.b(b,(.62,.13,.54),(0,.42,.12),"leatherlight",bevel=.05)
    s.b(b,(.54,.16,.095),(0,.53,.36),"leather",rot=(-.18,0,0),bevel=.025)
    s.b(b,(.44,.12,.095),(0,.50,-.15),"leather",bevel=.025)
    # Barding browplate follows horse forehead; triangular nose plate.
    s.add(b,polygon([(-.15,.15),(.15,.15),(.13,-.10),(0,-.29),(-.13,-.10)],.03,
                    (0,.74,-1.17),(.42,0,0)),"steel")
    s.b(b,(.033,.25,.025),(0,.76,-1.245),"gold",rot=(.42,0,0),bevel=.006)
    for idx,(xx,zz) in enumerate(((-.29,-.49),(.29,-.49),(-.32,.57),(.32,.57))):
        p=s.joint(("LegFrontLeft","LegFrontRight","LegRearLeft","LegRearRight")[idx],(xx,.99,zz))
        rear=idx>=2
        knee=.12 if rear else -.03
        s.r(p,(0,0,0),(0,-.40,knee),.112,"horse",8,r2=.075)
        s.e(p,(.091,.105,.094),(0,-.4,knee),"horselight")
        s.r(p,(0,-.39,knee),(0,-.88,.015),.065,"horse",8,r2=.050)
        s.b(p,(.16,.145,.235),(0,-.89,-.035),"mane",bevel=.027)
        s.b(p,(.17,.025,.237),(0,-.958,-.035),"darksteel",bevel=.008)
        if not rear:
            s.b(p,(.145,.21,.086),(0,-.21,-.073),"steel",bevel=.02)
    # Rider torso sits naturally above the saddle, with armor and tucked boots.
    rider=s.joint("Rider",(0,1.75,.08))
    s.add(rider,lathe([(-.24,.28),(-.1,.24),(.20,.32),(.30,.245)],8),"blue")
    s.b(rider,(.46,.35,.16),(0,.10,-.21),"steel",bevel=.06)
    s.b(rider,(.04,.32,.025),(0,.10,-.30),"gold",bevel=.006)
    s.b(rider,(.49,.09,.39),(0,-.105,0),"leather",bevel=.02)
    s.b(rider,(.10,.075,.035),(0,-.10,-.214),"gold")
    for sign in (-1,1):
        s.r(rider,(sign*.16,-.13,.06),(sign*.40,-.30,.10),.12,"darksteel",8)
        s.r(rider,(sign*.40,-.3,.1),(sign*.41,-.57,-.005),.10,"steel",8)
        s.b(rider,(.17,.16,.28),(sign*.41,-.66,-.075),"darksteel",bevel=.027)
        s.b(rider,(.11,.43,.065),(sign*.22,-.20,-.16),"blue",rot=(0,0,sign*.25),bevel=.016)
    # Flowing short cloak: thick faceted asymmetric hem.
    s.add(rider,polygon([(-.29,.27),(.29,.27),(.37,-.28),(.13,-.43),(-.35,-.34)],.045,(0,-.02,.27),(-.20,0,0)),"blue")
    for xx in (-.23,0,.23):
        s.b(rider,(.015,.43,.013),(xx,-.03,.355),"gold",rot=(-.20,0,-xx*.24),bevel=.003)
    head=s.joint("Head",(0,2.18,.03))
    helmet(s,head,(0,0,0),True)
    for p,sign in ((s.joint("ArmLeft",(-.34,1.97,.06)),-1),(s.joint("ArmRight",(.34,1.97,.06)),1)):
        s.e(p,(.235,.18,.24),(sign*.025,.01,0),"steel")
        for yy in (0,-.075):
            s.b(p,(.32,.035,.31),(sign*.04,yy,-.042),"edge",rot=(0,0,sign*.15),bevel=.014)
        elbow = (-.14,-.27,-.04) if sign < 0 else (sign*.085,-.29,-.05)
        wrist = (-.28,-.39,-.30) if sign < 0 else (sign*.08,-.43,-.16)
        hand = (-.29,-.41,-.32) if sign < 0 else (sign*.08,-.47,-.19)
        s.r(p,(0,-.1,0),elbow,.105,"blue",8)
        s.r(p,elbow,wrist,.101,"steel",8)
        s.e(p,(.10,.095,.10),hand,"darksteel")
    shield(s,"ArmLeft",(-.30,-.35,-.465),True)
    s.r("ArmLeft",(-.35,-.41,-.41),(-.23,-.41,-.41),.025,"leather",8)
    sword(s,"ArmRight",(.09,-.43,-.22),1.0)
    # Preserve all horse geometry while separating the neck/head for a recoil nod.
    horse_head=s.joint("HorseHead",(0,.27,-.50),parent=b)
    for category,pieces in s.parts[b].items():
        retained=[]
        for piece in pieces:
            center=piece.centroid
            if center[1]>.25 and center[2]<-.40:
                piece.apply_translation((0,-.27,.50))
                s.parts[horse_head][category].append(piece)
            else:
                retained.append(piece)
        s.parts[b][category]=retained
    waist=s.pivot("Waist",(0,1.75,.08))
    for p in (rider,head,"ArmLeft","ArmRight"):
        s.reparent(p,waist)
    return s


def light_cavalry():
    s=Sculpture("light_cavalry")
    b=s.joint("Body",(0,1.10,0))
    # Same horse proportions as the knight, with an exposed chest and flanks.
    s.e(b,(.43,.44,.77),(0,0,.06),"horse",sub=2)
    s.e(b,(.39,.41,.37),(0,.018,-.49),"horselight")
    s.e(b,(.44,.43,.40),(0,.02,.62),"horse")
    horse_head=s.joint("HorseHead",(0,.27,-.50),parent=b)
    s.e(horse_head,(.25,.52,.31),(0,.38,-.62),"horselight",rot=(-.43,0,0))
    s.e(horse_head,(.225,.23,.37),(0,.72,-.89),"horse",rot=(.38,0,0))
    s.e(horse_head,(.207,.185,.22),(0,.56,-1.17),"horselight")
    s.e(horse_head,(.16,.11,.08),(0,.52,-1.36),"mane")
    for sign in (-1,1):
        s.add(horse_head,polygon([(-.06,0),(.06,0),(.025,.25)],.11,(sign*.13,.9,-.79),(0,sign*.18,sign*.15)),"horse")
        s.e(horse_head,(.021,.040,.042),(sign*.189,.76,-1.035),"black")
        s.e(horse_head,(.007,.012,.012),(sign*.209,.768,-1.043),"ivory")
        s.b(horse_head,(.042,.14,.37),(sign*.208,.55,-1.14),"leather",rot=(.34,0,0),bevel=.008)
        s.add(horse_head,ring(.056,.010,(sign*.224,.58,-1.205),(0,math.pi/2,0),n=10),"gold")
        # Both reins meet the left hand, outside the neck rather than through it.
        s.r(b,(sign*.224,.60,-1.21),(sign*.29,.52,-.55),.015,"leather",6)
        s.r(b,(sign*.29,.52,-.55),(-.22,.57,-.37),.015,"leather",6)
    s.b(horse_head,(.43,.055,.073),(0,.49,-1.32),"leather",rot=(.16,0,0))
    for i in range(7):
        s.e(horse_head,(.076,.145,.13),(0,.79-i*.07,-.65+i*.083),"mane",rot=(-.5,0,0))
    for i in range(5):
        s.e(b,(.10-i*.01,.22,.12),(0,.1-i*.15,.86+i*.078),"mane",rot=(-.32,0,0))
    # The rear saddle cloth has a sloped front edge under the knee. Its outer
    # surface stays inside the calf/boot layer rather than slicing through it.
    for sign in (-1,1):
        s.add(b,polygon([(-.30,.24),(0,.24),(.29,-.055),(.29,-.10),(0,-.19),(-.30,-.10)],.032,
                        (sign*.46,.16,.41),(0,math.pi/2,0)),"blue")
        hem=[(-.30,-.10),(0,-.19),(.29,-.10)]
        for a,c in zip(hem,hem[1:]):
            s.r(b,(sign*.482,.16+a[1],.41-a[0]),(sign*.482,.16+c[1],.41-c[0]),.0125,"gold",6)
        s.b(b,(.035,.13,.032),(sign*.484,.145,.57),"goldlight",bevel=.004)
        s.b(b,(.039,.029,.15),(sign*.484,.155,.57),"goldlight",bevel=.004)
        s.r(b,(sign*.30,.42,.15),(sign*.57,.06,.075),.021,"leather",6)
        s.add(b,ring(.093,.014,(sign*.57,.005,.07),(0,math.pi/2,0),n=10),"darksteel")
    s.b(b,(.61,.13,.53),(0,.42,.12),"leatherlight",bevel=.05)
    s.b(b,(.52,.14,.095),(0,.51,.36),"leather",bevel=.025)
    s.b(b,(.42,.10,.095),(0,.49,-.15),"leather",bevel=.025)
    # Articulated knees and level hooves: the saved curves plant each hoof
    # at ground height and move it backwards at the actual 6.8 travel speed.
    for i,(xx,zz) in enumerate(((-.29,-.49),(.29,-.49),(-.32,.57),(.32,.57))):
        name=("LegFrontLeft","LegFrontRight","LegRearLeft","LegRearRight")[i]
        upper=s.joint(name,(xx,.99,zz))
        lower=s.joint(name+"Lower",(0,-.54,0),parent=upper)
        hoof=s.joint(name+"Hoof",(0,-.57,0),parent=lower)
        s.r(upper,(0,.02,0),(0,-.54,0),.116,"horse",8,r2=.072)
        s.e(upper,(.092,.094,.094),(0,-.54,0),"horselight")
        s.r(lower,(0,0,0),(0,-.56,0),.069,"horse",8,r2=.048)
        s.b(hoof,(.16,.105,.225),(0,.009,-.030),"mane",bevel=.022)
        s.b(hoof,(.166,.022,.23),(0,-.052,-.030),"darksteel",bevel=.006)
    rider=s.joint("Rider",(0,1.75,.08))
    s.add(rider,lathe([(-.23,.27),(-.10,.235),(.20,.30),(.29,.23)],8),"blue")
    s.b(rider,(.42,.32,.11),(0,.105,-.22),"steel",bevel=.055)
    s.b(rider,(.43,.28,.085),(0,.11,.19),"leather",bevel=.042)
    s.b(rider,(.047,.28,.018),(0,.11,-.282),"edge",bevel=.004)
    s.b(rider,(.47,.085,.39),(0,-.105,0),"leather",bevel=.02)
    s.b(rider,(.09,.066,.027),(0,-.10,-.212),"gold")
    # Seated legs belong to the horse/saddle rigid part. Waist twists animate
    # the torso while the knees and stirrups remain seated together.
    for sign in (-1,1):
        s.r(b,(sign*.16,.52,.14),(sign*.57,.35,.18),.113,"leather",8)
        s.r(b,(sign*.57,.35,.18),(sign*.58,.08,.075),.090,"blue",8)
        s.b(b,(.17,.17,.28),(sign*.58,0,.005),"leather",bevel=.027)
    s.b(rider,(.17,.18,.13),(.28,-.10,.16),"leatherlight",bevel=.022)
    head=s.joint("Head",(0,2.20,.03))
    s.e(head,(.235,.246,.217),(0,-.005,-.008),"skin")
    # Simple cloth cap: team colour reads from above, with a thin leather
    # brow band above the eyes. The light rider has no metal helmet or crest.
    s.e(head,(.255,.125,.239),(0,.203,.014),"blue")
    s.b(head,(.429,.034,.055),(0,.131,-.202),"leather",bevel=.011)
    for sign in (-1,1):
        s.e(head,(.050,.072,.057),(sign*.227,-.005,.0),"skin")
        s.b(head,(.039,.029,.024),(sign*.085,.049,-.210),"black",bevel=.004)
        s.b(head,(.068,.023,.024),(sign*.085,.100,-.201),"leather",bevel=.004)
        s.b(head,(.037,.17,.06),(sign*.22,-.04,.038),"leather",bevel=.007)
    s.e(head,(.045,.058,.055),(0,-.015,-.225),"skin")
    s.b(head,(.103,.021,.025),(0,-.111,-.188),"leather",bevel=.004)
    for sign,name in ((-1,"ArmLeft"),(1,"ArmRight")):
        arm=s.joint(name,(sign*.31,1.97,.06))
        s.e(arm,(.14,.125,.15),(0,0,0),"leather")
        elbow=(sign*.07,-.24,-.025)
        hand=(.09,-.30,-.43) if sign<0 else (.09,-.42,-.22)
        s.r(arm,(0,-.055,0),elbow,.089,"blue",8)
        s.r(arm,elbow,hand,.071,"leather",8)
        s.e(arm,(.077,.078,.079),hand,"skin")
    blade=s.joint("Sword",(.09,-.42,-.22),parent="ArmRight")
    sword(s,blade,(0,0,0),.60)
    # Head pieces were authored in horse-body coordinates; localize once.
    for pieces in s.parts[horse_head].values():
        for piece in pieces:
            piece.apply_translation((0,-.27,.50))
    waist=s.pivot("Waist",(0,1.75,.08))
    for part in (rider,head,"ArmLeft","ArmRight"):
        s.reparent(part,waist)
    motion=s.pivot("BodyMotion",(0,0,0))
    s.reparent(b,motion)
    s.reparent(waist,motion)
    return s


def light_horse_leg_pose(z, lift, rear, hip_height=.99):
    """Offline two-link pose; saved native tracks need no runtime IK."""
    y=.065+lift-hip_height
    distance=math.hypot(y,z)
    direction=math.atan2(-z,-y)
    a,b=.54,.57
    bend=1 if rear else -1
    upper=direction+bend*math.acos((a*a+distance*distance-b*b)/(2*a*distance))
    lower=-bend*(math.pi-math.acos((a*a+b*b-distance*distance)/(2*a*b)))
    return upper,lower,-upper-lower


def war_elephant():
    s = Sculpture("war_elephant")
    torso = s.pivot("BodyMotion", (0, 1.68, .12))
    body = s.joint("Body", parent=torso)
    s.e(body, (.87, .78, 1.19), (0, 0, 0), "elephant", sub=2)
    s.e(body, (.72, .63, .58), (0, -.03, .77), "elephant", sub=1)
    s.e(body, (.72, .78, .63), (0, .06, -.67), "elephant", sub=1)
    # Thick column feet. Separate Step pivots own gait; the leg meshes own
    # attack motion, so stomping never overwrites the locomotion tracks.
    for name, xx, zz in [("LegFrontLeft", -.56, -.65), ("LegFrontRight", .56, -.65),
                         ("LegRearLeft", -.59, .89), ("LegRearRight", .59, .89)]:
        step = s.pivot(name + "Step", (xx, 1.22, zz))
        leg = s.joint(name, parent=step)
        s.add(leg, lathe([(-1.16,.265),(-1.02,.272),(-.73,.218),(-.40,.231),(-.07,.30),(.08,.285)],10), "elephant")
        s.e(leg,(.238,.20,.23),(0,-.54,-.025),"elephantlight")
        for nail_x in (-.15,0,.15):
            s.b(leg,(.108,.112,.075),(nail_x,-1.078,-.236+abs(nail_x)*.18),"ivory",bevel=.026)
        for y in (-.77,-.85):
            s.add(leg,lathe([(y,.224),(y+.012,.224)],10,caps=False),"elephantdark")
    head_motion = s.pivot("HeadMotion", (0,.40,-1.0), parent=torso)
    head = s.joint("Head", parent=head_motion)
    # A low, continuous forehead blends into the skull. Separate tall spheres
    # made the old brow look like two objects attached above the face.
    skull=ellipsoid((.585,.68,.575),(0,.06,-.07),sub=2)
    jaw=ellipsoid((.38,.39,.39),(0,-.32,-.22))
    brow=ellipsoid((.45,.34,.23),(0,.32,-.34),sub=2)
    s.add(head,tm.convex.convex_hull(np.vstack((skull.vertices,jaw.vertices,brow.vertices))),"elephant")
    for side in (-1,1):
        # Seat the eyelid base in the cheek. Its previous centre was .038
        # outside the skin, leaving even the back of the eye detached.
        normal=np.array((side*math.sin(.65),0,-math.cos(.65)))
        eye=np.array((side*.46,.16,-.465))-normal*.04
        eye_rotation=(0,-side*.65,0)
        s.e(head,(.117,.081,.037),tuple(eye),"elephantdark",rot=eye_rotation)
        s.e(head,(.090,.060,.028),tuple(eye+normal*.026),"black",rot=eye_rotation)
        tangent=np.array((math.cos(.65),0,side*math.sin(.65)))
        glint=eye+normal*.057-tangent*side*.023+np.array((0,.018,0))
        s.e(head,(.019,.021,.014),tuple(glint),"ivory",rot=eye_rotation)
        # Ivory tusks curve forward and gently upward, rather than following
        # the nose down. Their length is decorative, never a range input.
        points=[(side*.365,-.28,-.40),(side*.45,-.40,-.70),
                (side*.47,-.39,-1.02),(side*.44,-.28,-1.31),(side*.41,-.13,-1.47)]
        radii=[.108,.093,.067,.038,.003]
        for i in range(4):
            s.r(head,points[i],points[i+1],radii[i],"ivory",9,r2=radii[i+1])
        s.add(head,ring(.113,.016,points[0],(.95,side*.1,0),n=10),"gold")
    # A close-fitting riveted plate needs no straight cylindrical straps
    # crossing the forehead. Those rods pierced the old brow domes.
    plate_rotation=(.22,0,0)
    plate_transform=matrix((0,.30,-.566),plate_rotation)
    s.add(head,polygon([(-.19,.30),(.19,.30),(.245,.03),(0,-.21),(-.245,.03)],.055,(0,.30,-.566),plate_rotation),"steel")
    emblem=tuple((plate_transform@np.array((0,.02,-.043,1)))[:3])
    s.b(head,(.033,.29,.032),emblem,"gold",rot=plate_rotation,bevel=.007)
    for x,y in [(-.13,.20),(.13,.20),(-.12,-.05),(.12,-.05)]:
        at=tuple((plate_transform@np.array((x,y,-.031,1)))[:3])
        s.e(head,(.020,.020,.011),at,"gold",rot=plate_rotation)
    for side in (-1,1):
        ear=s.joint("EarLeft" if side<0 else "EarRight",(side*.46,.16,.18),parent=head_motion)
        # Rounded upper lobe and tapered lower edge; deliberately less wide
        # than African-elephant ears, keeping the war mount's face readable.
        outline=[(0,.31),(side*.27,.47),(side*.61,.27),(side*.64,-.13),
                 (side*.38,-.48),(side*.13,-.42),(-side*.04,-.12)]
        s.add(ear,polygon(outline,.12,rot=(.04,-side*.30,0)),"elephantdark")
        inset=[(x*.84,y*.82) for x,y in outline]
        s.add(ear,polygon(inset,.055,(0,0,-.070),(.04,-side*.30,0)),"elephantlight")
    trunk_swing=s.pivot("TrunkSwing",(0,-.02,-.54),parent=head_motion)
    upper=s.joint("TrunkUpper",parent=trunk_swing)
    s.r(upper,(0,.025,0),(0,-.57,-.13),.245,"elephant",10,r2=.184)
    s.e(upper,(.198,.19,.193),(0,-.54,-.125),"elephant",sub=1)
    middle=s.joint("TrunkMiddle",(0,-.54,-.125),parent=upper)
    s.r(middle,(0,.05,0),(0,-.55,-.09),.184,"elephant",10,r2=.129)
    s.e(middle,(.139,.14,.14),(0,-.52,-.085),"elephant",sub=1)
    tip=s.joint("TrunkTip",(0,-.52,-.085),parent=middle)
    s.r(tip,(0,.035,0),(0,-.27,-.14),.129,"elephant",9,r2=.096)
    s.r(tip,(0,-.27,-.14),(0,-.24,-.33),.096,"elephant",9,r2=.064)
    s.r(tip,(0,-.24,-.33),(0,-.14,-.38),.064,"elephant",8,r2=.042)
    for part, ys, z in [(upper,[-.16,-.30,-.43],-.17),(middle,[-.16,-.29,-.40],-.13)]:
        for y in ys:
            s.r(part,(-.11,y,z-.06),(.11,y,z-.06),.012,"elephantdark",6)
    tail=s.joint("Tail",(0,.02,1.075),parent=torso)
    s.r(tail,(0,0,0),(0,-.62,.23),.055,"elephant",8,r2=.028)
    s.e(tail,(.065,.17,.085),(0,-.66,.24),"elephantdark")
    # A blue saddle cloth drapes onto both sides, with a gold hem and emblem.
    s.b(body,(1.32,.09,1.36),(0,.69,.18),"blue",bevel=.035)
    for side in (-1,1):
        panel=[(-.60,.24),(.57,.24),(.62,-.32),(.32,-.53),(-.47,-.43)]
        s.add(body,polygon(panel,.048,(side*.82,.15,.20),(0,math.pi/2,0)),"gold")
        s.add(body,polygon([(x*.91,y*.88) for x,y in panel],.052,(side*.846,.15,.20),(0,math.pi/2,0)),"blue")
        s.b(body,(.042,.40,.048),(side*.881,.12,.20),"goldlight",bevel=.007)
        s.b(body,(.043,.048,.31),(side*.882,.18,.20),"goldlight",bevel=.007)
        s.e(body,(.025,.062,.062),(side*.908,.18,.20),"gold")
        s.b(body,(.095,.63,.11),(side*.755,.22,-.39),"leather",rot=(0,0,side*.18))
        s.b(body,(.12,.12,.14),(side*.82,.06,-.39),"gold")
    # Breast plate stays below the head and is attached to a broad belly strap.
    s.add(body,polygon([(-.40,.22),(.40,.22),(.34,-.22),(0,-.34),(-.34,-.22)],.075,(0,-.04,-1.01)),"steel")
    s.b(body,(.055,.35,.034),(0,-.03,-1.063),"edge",bevel=.009)
    s.b(body,(.90,.17,.73),(0,.81,.17),"leatherlight",bevel=.045)
    for z in (-.20,.56):
        s.b(body,(.88,.19,.105),(0,.90,z),"wooddark",bevel=.03)
        s.b(body,(.91,.045,.12),(0,1.005,z),"gold",bevel=.008)
    rider=s.joint("Rider",(0,.96,.08),parent=torso)
    s.add(rider,lathe([(-.14,.23),(.02,.235),(.25,.29),(.34,.22)],8),"blue")
    s.b(rider,(.41,.31,.11),(0,.14,-.20),"steel",bevel=.046)
    s.b(rider,(.44,.075,.38),(0,-.045,0),"leather",bevel=.02)
    s.b(rider,(.083,.075,.032),(0,-.038,-.213),"gold")
    for side in (-1,1):
        s.r(rider,(side*.14,-.06,0),(side*.39,-.27,-.07),.103,"leather",8)
        s.r(rider,(side*.39,-.27,-.07),(side*.43,-.57,-.16),.095,"blue",8)
        s.b(rider,(.18,.17,.29),(side*.43,-.60,-.23),"leather",bevel=.03)
        s.e(rider,(.15,.12,.155),(side*.28,.25,-.01),"steel")
        s.r(rider,(side*.28,.18,-.03),(side*.32,-.01,-.24),.083,"blue",8)
        s.r(rider,(side*.32,-.01,-.24),(side*.16,.01,-.42),.073,"leather",8)
        s.e(rider,(.073,.067,.079),(side*.14,.01,-.43),"skin")
        # Hands hold a short padded rein loop fixed to the saddle. No second
        # weapon or damage source is attached to the rider.
        s.r(rider,(side*.14,.01,-.46),(side*.29,-.13,-.43),.016,"rope",6)
    rider_head=s.joint("RiderHead",(0,.57,-.015),parent=rider)
    s.e(rider_head,(.236,.246,.217),(0,-.005,-.008),"skin")
    s.e(rider_head,(.249,.162,.23),(0,.157,.02),"blue")
    s.b(rider_head,(.44,.049,.081),(0,.17,-.186),"gold",bevel=.012)
    for side in (-1,1):
        s.b(rider_head,(.038,.030,.026),(side*.085,.049,-.211),"black",bevel=.004)
        s.b(rider_head,(.073,.025,.025),(side*.085,.102,-.203),"leather",bevel=.004)
        s.e(rider_head,(.052,.077,.066),(side*.234,-.004,0),"skin")
    s.e(rider_head,(.045,.061,.051),(0,-.012,-.225),"skin")
    s.b(rider_head,(.108,.022,.023),(0,-.115,-.190),"leather",bevel=.003)
    return s


def wheel(s, part, radius=.46, width=.16):
    # Real open spokes and separate iron tire. Axis X.
    s.add(part,ring(radius-.045,.057,rot=(0,math.pi/2,0),n=16,m=4),"woodlight")
    s.add(part,ring(radius+.004,.025,rot=(0,math.pi/2,0),n=16,m=4),"darksteel")
    for angle in np.arange(8)*math.tau/8:
        a=(0,math.cos(angle)*.09,math.sin(angle)*.09)
        b=(0,math.cos(angle)*(radius-.07),math.sin(angle)*(radius-.07))
        s.r(part,a,b,.039,"wood",6)
    s.r(part,(-width/2,0,0),(width/2,0,0),.12,"wooddark",12)
    s.r(part,(-width/2-.015,0,0),(width/2+.015,0,0),.060,"darksteel",10)
    for side in (-1,1):
        s.r(part,(side*width*.48,0,0),(side*(width*.5+.025),0,0),.102,"gold",10)


def beam(s,p,a,b,width=.14,depth=.16,color="wood"):
    a,b=np.array(a,float),np.array(b,float)
    m=box((width,depth,np.linalg.norm(b-a)),bevel=.018)
    t=tm.geometry.align_vectors((0,0,1),b-a)
    t[:3,3]=(a+b)/2
    m.apply_transform(t)
    s.add(p,m,color)


def catapult():
    s=Sculpture("catapult")
    body=s.joint("Body")
    # Chamfered oak chassis, cross members and individual deck slats.
    for xx in (-.64,.64):
        s.b(body,(.22,.22,2.19),(xx,.56,.10),"wood",bevel=.033)
        s.b(body,(.245,.035,2.12),(xx,.68,.10),"woodlight",bevel=.008)
    for zz in (-.80,-.35,.20,.72,1.10):
        s.b(body,(1.36,.18,.16),(0,.52,zz),"wooddark",bevel=.02)
    for i in range(8):
        s.b(body,(1.08,.07,.11),(0,.68,-.37+i*.18),"woodlight" if i%3 else "wood",bevel=.008)
    for zz in (-.67,.87):
        s.r(body,(-1.07,.43,zz),(1.07,.43,zz),.083,"darksteel",10)
        for side in (-1,1):
            p=s.joint(f"Wheel{'Left' if side<0 else 'Right'}{'Front' if zz<0 else 'Rear'}",(side*.97,.47,zz))
            wheel(s,p,.45,.22)
    # A-frame bearing towers with bolted metal mounting plates.
    for side in (-1,1):
        for zz in (-.59,.57):
            beam(s,body,(side*.61,.69,zz),(side*.61,1.66,-.05),.18,.18,"woodlight")
            s.b(body,(.235,.24,.055),(side*.61,.77,zz-.07),"darksteel",bevel=.016)
            rivets(s,body,[(side*.61+.07,.78,zz-.103),(side*.61-.07,.78,zz-.103)],.025)
        s.b(body,(.28,.22,.31),(side*.61,1.63,-.05),"wooddark",bevel=.03)
    s.r(body,(-.79,1.62,-.05),(.79,1.62,-.05),.113,"darksteel",12)
    # Rope-wrapped torsion bundle and tensioning windlass.
    s.r(body,(-.42,.92,-.48),(.42,.92,-.48),.14,"rope",12)
    for x in np.linspace(-.38,.38,12):
        s.add(body,ring(.15,.018,(x,.92,-.48),(0,math.pi/2,0),n=10),"rope")
    s.r(body,(-.83,.91,.93),(.83,.91,.93),.10,"wooddark",10)
    for x in np.linspace(-.22,.22,9):
        s.add(body,ring(.115,.022,(x,.91,.93),(0,math.pi/2,0),n=10),"rope")
    for side in (-1,1):
        s.b(body,(.10,.61,.075),(side*.84,.91,.93),"wood",rot=(.42,0,0),bevel=.016)
        s.r(body,(side*.84,1.14,.83),(side*1.04,1.14,.83),.048,"woodlight",8)
    # Mechanism visibly hinges at the bearing. Rest arm points backward and up.
    arm=s.joint("ThrowArm",(0,1.62,-.05))
    beam(s,arm,(0,-.35,-.51),(0,.79,.91),.19,.19,"woodlight")
    for t in (.05,.33,.63):
        s.b(arm,(.22,.105,.24),(0,-.35+t*.8,-.51+t),"darksteel",rot=(.66,0,0),bevel=.014)
    # Deep polygonal spoon with an actual open cup and stone seated inside.
    s.add(arm,lathe([(-.06,.18),(0,.32),(.19,.32),(.23,.29),(.19,.26),(.025,.245)],10,
                   (0,.77,.89),caps=False),"wooddark")
    s.add(arm,ring(.315,.026,(0,.94,.89),(math.pi/2,0,0),n=10),"darksteel")
    payload=s.joint("Payload",(0,.91,.89),parent="ThrowArm")
    s.e(payload,(.23,.22,.23),(0,0,0),"steel",sub=1)
    for side in (-1,1):
        s.r(body,(side*.28,.93,.91),(side*.09,1.40,.05),.016,"rope",6)
    # Blue hanging banner gives the siege engine a readable faction marking.
    s.b(body,(.71,.04,.032),(0,.65,-1.025),"gold",bevel=.005)
    s.add(body,polygon([(-.34,.17),(.34,.17),(.32,-.12),(0,-.23),(-.32,-.12)],.024,(0,.45,-1.035)),"blue")
    s.b(body,(.046,.25,.022),(0,.46,-1.06),"goldlight",bevel=.003)
    s.b(body,(.25,.038,.022),(0,.50,-1.06),"goldlight",bevel=.003)
    return s


def cannon():
    s=Sculpture("cannon")
    b=s.joint("Body")
    # Thick splayed cheeks, tail trail and stacked cross braces.
    for side in (-1,1):
        s.add(b,polygon([(-.90,-.16),(.80,-.16),(.44,.31),(-.47,.44)],.20,
                        (side*.41,.70,.03),(0,math.pi/2,0)),"wood")
        beam(s,b,(side*.43,.48,.3),(side*.29,.28,1.39),.20,.20,"woodlight")
        s.b(b,(.215,.14,.30),(side*.29,.30,1.24),"darksteel",rot=(.12,0,0),bevel=.022)
    for zz in (-.53,.03,.63,1.30):
        s.b(b,(.92 if zz<1 else .71,.15,.18),(0,.42 if zz<1 else .21,zz),"wooddark",bevel=.025)
    s.b(b,(.61,.09,.66),(0,.53,.27),"woodlight",bevel=.013)
    s.r(b,(-1.08,.57,-.07),(1.08,.57,-.07),.10,"darksteel",12)
    for side in (-1,1):
        p=s.joint("WheelLeft" if side<0 else "WheelRight",(side*.89,.57,-.07))
        wheel(s,p,.55,.23)
        for zz in (-.40,.23):
            s.b(b,(.055,.22,.16),(side*.531,.71,zz),"darksteel",bevel=.016)
            s.e(b,(.025,.033,.033),(side*.566,.71,zz),"gold")
    barrel=s.joint("Barrel",(0,.94,-.12))
    # Lathed hollow bronze bore, using connected outer and inner muzzle rings.
    profile=[(-.78,.21),(-.66,.28),(-.25,.28),(.33,.23),(.96,.215),
             (1.06,.275),(1.20,.275),(1.25,.23),(1.25,.16)]
    s.add(barrel,lathe(profile,16,rot=(-math.pi/2-.08,0,0),caps=False),"bronze")
    s.add(barrel,lathe([(1.25,.16),(.97,.16)],16,rot=(-math.pi/2-.08,0,0),caps=False),"black")
    # Deep black chamber seals bore well behind the lip: muzzle reads as hollow.
    s.add(barrel,lathe([(.96,.158),(.97,.158)],16,rot=(-math.pi/2-.08,0,0)),"black")
    # The mid-barrel band carries team paint; the other rings retain bronze.
    for yy,rr,color in ((-.59,.285,"bronzelight"),(-.19,.286,"bronzelight"),(.44,.238,"blue"),(1.085,.281,"bronzelight")):
        s.add(barrel,lathe([(yy-.034,rr),(yy+.034,rr)],16,rot=(-math.pi/2-.08,0,0),caps=False),color)
    s.e(barrel,(.24,.24,.16),(0,-.047,.78),"bronze")
    s.e(barrel,(.095,.095,.13),(0,-.07,.95),"bronzelight")
    s.r(barrel,(-.59,0,0),(.59,0,0),.10,"darksteel",12)
    # Touch hole, cast top ornament, and decorative side rivets.
    s.b(barrel,(.10,.07,.12),(0,.28,.42),"bronzelight",bevel=.019)
    s.e(barrel,(.025,.012,.025),(0,.319,.42),"black")
    for side in (-1,1):
        for zz in (-.33,.0,.34):
            s.e(barrel,(.019,.035,.035),(side*.268,.01,zz),"gold")
    # Elevation screw and iron handling loop at the trail.
    s.r(b,(0,.50,.62),(0,.78,.53),.031,"darksteel",10)
    for yy in (.55,.60,.65,.70):
        s.add(b,ring(.041,.009,(0,yy,.60-(yy-.55)*.35),(math.pi/2,0,0),n=8),"steel")
    s.add(b,ring(.14,.026,(0,.24,1.47),(math.pi/2,0,0),n=12),"darksteel")
    # Faction panels, rammer, cannonballs and a powder pouch.
    for side in (-1,1):
        s.b(b,(.031,.25,.42),(side*.55,.64,.23),"blue",bevel=.012)
        s.b(b,(.036,.17,.035),(side*.57,.64,.23),"goldlight",bevel=.004)
        s.b(b,(.036,.035,.24),(side*.57,.68,.23),"goldlight",bevel=.004)
    s.r(b,(.57,.38,.20),(.57,.25,1.34),.028,"woodlight",8)
    s.e(b,(.067,.067,.14),(.57,.25,1.31),"ivory")
    for xx,zz in ((-.17,.88),(.16,.88),(0,1.13)):
        s.e(b,(.135,.135,.135),(xx,.54,zz),"darksteel",sub=2)
    return s


def farmer():
    """A workman with separately posed hands, a forged pick and a wooden mallet."""
    s=Sculpture("farmer")
    body=s.joint("Body",(0,1.05,0))
    head=s.joint("Head",(0,1.57,0))
    left=s.joint("ArmLeft",(-.32,1.32,0))
    right=s.joint("ArmRight",(.32,1.32,0))
    # Rolled linen sleeves and a blue, tailored work tunic beneath the apron.
    s.add(body,lathe([(-.30,.28),(-.06,.245),(.22,.31),(.30,.235)],8),"blue")
    s.b(body,(.32,.47,.072),(0,-.08,-.264),"leatherlight",bevel=.027)
    for sign in (-1,1):
        s.b(body,(.048,.45,.032),(sign*.13,.16,-.231),"leather",rot=(0,0,sign*.16),bevel=.009)
        s.b(body,(.13,.31,.095),(sign*.15,-.31,-.115),"blue",rot=(0,0,-sign*.06),bevel=.016)
    s.b(body,(.51,.10,.36),(0,-.055,0),"leather",bevel=.016)
    s.b(body,(.095,.083,.039),(0,-.052,-.205),"gold",bevel=.010)
    s.b(body,(.052,.044,.012),(0,-.052,-.23),"wooddark",bevel=.006)
    # Belt pouch has a flap, stitching, buckle and a short awl on the other hip.
    s.b(body,(.19,.22,.16),(.28,-.16,.045),"leather",bevel=.037)
    s.b(body,(.18,.105,.024),(.28,-.085,-.046),"leatherlight",bevel=.020)
    s.b(body,(.032,.055,.018),(.28,-.10,-.064),"gold",bevel=.005)
    for y in (-.19,-.15,-.11):
        s.b(body,(.024,.009,.01),(.216,y,-.041),"rope",bevel=.002)
    s.r(body,(-.285,-.29,.015),(-.285,.03,.015),.021,"woodlight",8)
    s.r(body,(-.285,-.39,.015),(-.285,-.26,.015),.014,"darksteel",6)
    # A softened cloth cap with a stitched turned brim; visible hair, ears and face.
    s.e(head,(.233,.248,.216),(0,-.015,-.015),"skin",sub=2)
    s.e(head,(.254,.19,.238),(0,.105,.01),"mane",sub=1)
    s.e(head,(.268,.130,.251),(-.025,.209,.015),"rope",rot=(0,0,.12),sub=2)
    s.add(head,lathe([(.102,.255),(.158,.273),(.194,.247)],12),"rope")
    s.b(head,(.385,.046,.17),(0,.145,-.215),"leatherlight",rot=(.10,0,0),bevel=.027)
    for sign in (-1,1):
        s.e(head,(.047,.082,.055),(sign*.225,-.043,-.003),"skin")
        s.b(head,(.040,.023,.014),(sign*.080,.011,-.230),"black",bevel=.003)
        s.b(head,(.078,.025,.019),(sign*.080,.058,-.218),"mane",rot=(0,0,sign*.06),bevel=.004)
        s.b(head,(.09,.043,.036),(sign*.039,-.104,-.232),"leather",rot=(0,0,sign*.12),bevel=.014)
        s.b(head,(.060,.14,.065),(sign*.201,.014,.009),"mane",rot=(0,0,-sign*.12),bevel=.019)
    s.e(head,(.041,.061,.070),(0,-.045,-.229),"skin")
    for part,sign in ((left,-1),(right,1)):
        s.e(part,(.171,.145,.177),(sign*.025,.005,0),"ivory")
        s.r(part,(0,-.065,0),(sign*.045,-.24,0),.102,"ivory",8)
        s.add(part,lathe([(-.033,.107),(.033,.109)],8,(sign*.037,-.19,0),(0,0,-sign*.18)),"rope")
        fore=s.joint("ForearmLeft" if sign<0 else "ForearmRight",(sign*.045,-.24,0),parent=part)
        s.r(fore,(0,0,0),(sign*.025,-.20,-.045),.076,"skin",8)
        s.b(fore,(.137,.069,.133),(sign*.025,-.207,-.047),"leather",bevel=.018)
        s.e(fore,(.080,.080,.09),(sign*.025,-.235,-.055),"skin")
    for name,x in (("LegLeft",-.155),("LegRight",.155)):
        leg=s.joint(name,(x,.75,0))
        s.r(leg,(0,.015,0),(0,-.32,.018),.112,"ivory",8)
        s.b(leg,(.18,.24,.16),(0,-.43,0),"leather",bevel=.027)
        s.b(leg,(.216,.18,.335),(0,-.647,-.08),"leather",bevel=.041)
        s.b(leg,(.224,.042,.344),(0,-.716,-.076),"wooddark",bevel=.01)
        for y in (-.34,-.43):
            s.b(leg,(.187,.026,.174),(0,y,-.01),"leatherlight",bevel=.008)
    waist=s.pivot("Waist",(0,1.05,0))
    for part in (body,head,left,right):
        s.reparent(part,waist)
    tool=s.joint("Pick",(.39,-.19,-.09),parent=waist)
    s.r(tool,(0,-.24,0),(0,.72,0),.037,"woodlight",10)
    s.r(tool,(0,-.13,0),(0,.13,0),.042,"leather",10)
    for y in (-.09,-.03,.03,.09):
        s.add(tool,ring(.043,.007,(0,y,0),(math.pi/2,0,0),n=8),"rope")
    s.b(tool,(.19,.16,.15),(0,.66,0),"darksteel",bevel=.023)
    # A downward-curved pick point and broad, sharpened adze oppose each other.
    s.add(tool,polygon([(-.49,.54),(-.30,.71),(-.055,.735),(.075,.67),(-.10,.64),(-.31,.63)],.10),"steel")
    s.add(tool,polygon([(.04,.72),(.30,.70),(.46,.55),(.46,.49),(.26,.61),(.04,.62)],.13),"darksteel")
    s.b(tool,(.057,.085,.15),(.445,.535,0),"edge",rot=(0,0,-.30),bevel=.008)
    s.r(tool,(-.073,.66,-.084),(-.073,.66,.084),.024,"gold",8)
    mallet=s.joint("Mallet",(.39,-.19,-.09),parent=waist)
    s.r(mallet,(0,-.20,0),(0,.45,0),.039,"woodlight",8)
    s.b(mallet,(.35,.23,.21),(0,.45,0),"wood",bevel=.035)
    for sign in (-1,1):
        s.b(mallet,(.031,.22,.202),(sign*.145,.45,0),"darksteel",bevel=.012)
        s.e(mallet,(.012,.022,.022),(sign*.165,.45,-.045),"steel")
    return s


def farmer_arm_pose(s, side, target):
    """Offline two-bone solve: hands remain wrapped around the authored tool."""
    sign=-1 if side=="Left" else 1
    shoulder=np.array(s.joints["Arm"+side])
    upper=np.array((sign*.045,-.24,0))
    lower=np.array((sign*.025,-.235,-.055))
    direction=np.array(target)-shoulder
    a,b=np.linalg.norm(upper),np.linalg.norm(lower)
    distance=min(np.linalg.norm(direction),a+b-.001)
    direction/=np.linalg.norm(direction)
    projection=(a*a-b*b+distance*distance)/(2*distance)
    pole=np.array((sign*.80,-.10,.40))
    pole-=direction*np.dot(pole,direction)
    pole/=np.linalg.norm(pole)
    elbow=direction*projection+pole*math.sqrt(max(0,a*a-projection*projection))
    rotation=tm.geometry.align_vectors(upper,elbow)[:3,:3]
    local_hand=rotation.T@(direction*distance-elbow)
    forearm=tm.geometry.align_vectors(lower,local_hand)[:3,:3]
    return godot_euler(rotation),godot_euler(forearm)


def farmer_work_tracks(s, mode):
    mining=mode=="gather"
    duration=1.5 if mining else 1.0
    t=[q*duration for q in (0,.18,.36,.47,.52,.58,.72,1)]
    positions=[(0,.12,-.24),(0,.31,-.20),(.03,.55,-.23),(.03,.53,-.23),(0,.11,-.31),(0,.10,-.31),(0,.12,-.27),(0,.12,-.24)]
    rotations=[(-.25,0,-.10),(-.20,0,-.18),(-.20,0,-.18),(-.24,0,-.17),(-1.05,0,-.10),(-1.15,0,-.08),(-.60,0,-.10),(-.25,0,-.10)]
    if not mining:
        positions=[(.34,-.03,-.30),(.32,.13,-.30),(.29,.32,-.18),(.29,.30,-.18),(.29,.05,-.36),(.29,.04,-.36),(.32,-.02,-.34),(.34,-.03,-.30)]
        rotations=[(-.25,0,-.14),(-.10,0,-.17),(.25,0,-.19),(.18,0,-.19),(-1.25,0,-.10),(-1.30,0,-.10),(-.60,0,-.13),(-.25,0,-.14)]
    path=lambda part,prop:s.part_path(part)+":"+prop
    tracks=[(path("Pick","visible"),[mining,mining],[0,duration]),(path("Mallet","visible"),[not mining,not mining],[0,duration])]
    tool="Pick" if mining else "Mallet"
    tracks.extend([(path(tool,"position"),positions,t),(path(tool,"rotation"),rotations,t)])
    for side in ("Left","Right"):
        shoulders=[];forearms=[]
        for position,rotation in zip(positions,rotations):
            target=np.array(position)
            if side=="Left":
                target=target+godot_rotation(rotation)@np.array((0,-.19,0)) if mining else np.array((-.18,-.05,-.30))
            shoulder,forearm=farmer_arm_pose(s,side,target)
            shoulders.append(shoulder);forearms.append(forearm)
        tracks.extend([(path("Arm"+side,"rotation"),shoulders,t),(path("Forearm"+side,"rotation"),forearms,t)])
    tracks.append((path("Waist","rotation"),[(x,y,0) for x,y in [(0,.03),(.05,.06),(.11,.07),(.08,.06),(-.17,-.025),(-.20,-.035),(-.07,0),(0,.03)]],t))
    tracks.append((path("Head","rotation"),[(x,0,0) for x in [.08,.02,-.05,-.03,.13,.15,.10,.08]],t))
    tracks.append(("Rig:position",[(0,y,0) for y in [0,.01,.026,.017,-.055,-.06,-.02,0]],t))
    for part in ("LegLeft","LegRight"):
        tracks.append((path(part,"rotation"),[(0,0,0),(0,0,0)],[0,duration]))
    return duration,tracks


def write_farmer_scene(s):
    parts=list(s.parts)
    lines=[f'[gd_scene load_steps={len(parts)+9} format=3]',
           '[ext_resource type="Script" path="res://scripts/unit_visual.gd" id="1_script"]']
    for i,p in enumerate(parts):
        lines.append(f'[ext_resource type="ArrayMesh" path="res://assets/models/units/farmer/{p}.res" id="{i+2}_{p}"]')
    path=lambda part,prop:s.part_path(part)+":"+prop
    idle=[];walk=[]
    for part,sign in (("LegLeft",1),("LegRight",-1)):
        idle.append((path(part,"rotation"),[(0,0,0),(0,0,0)]))
        walk.append((path(part,"rotation"),[(sign*a,0,0) for a in (0,.50,0,-.50,0)]))
    for part in ("Waist","Head","ArmLeft","ForearmLeft"):
        idle.append((path(part,"rotation"),[(0,0,0),(0,0,0)]))
        walk.append((path(part,"rotation"),[(0,0,0),(0,0,0)]))
    right,fore=farmer_arm_pose(s,"Right",(.39,-.19,-.09))
    for part,pose in (("ArmRight",right),("ForearmRight",fore)):
        idle.append((path(part,"rotation"),[pose,pose]))
        walk.append((path(part,"rotation"),[pose,pose]))
    for tracks in (idle,walk):
        for part in ("Pick","Mallet"):
            tracks.extend([(path(part,"position"),[(.39,-.19,-.09),(.39,-.19,-.09)]),
                           (path(part,"rotation"),[(0,0,0),(0,0,0)]),
                           (path(part,"visible"),[part=="Pick",part=="Pick"])])
    idle.append(("Rig:position",[(0,0,0),(0,.014,0),(0,0,0)]))
    walk.append(("Rig:position",[(0,y,0) for y in (0,.04,0,.04,0)]))
    duration,gather=farmer_work_tracks(s,"gather")
    build_duration,build=farmer_work_tracks(s,"build")
    lines += [anim_resource("idle",2.6,idle,True),anim_resource("walk",.76,walk,True),
              anim_resource("gather",duration,gather,True),anim_resource("build",build_duration,build,True),
              anim_resource("strike",duration,gather),
              '[sub_resource type="AnimationLibrary" id="AnimationLibrary_locomotion"]\n_data = {&"idle": SubResource("Animation_idle"), &"walk": SubResource("Animation_walk")}',
              '[sub_resource type="AnimationLibrary" id="AnimationLibrary_attack"]\n_data = {&"strike": SubResource("Animation_strike"), &"gather": SubResource("Animation_gather"), &"build": SubResource("Animation_build")}',
              '[node name="Farmer" type="Node3D"]\nscript = ExtResource("1_script")\nkind = "farmer"\nprojectile_socket = NodePath("Rig/Action/ProjectileSocket")',
              '[node name="Rig" type="Node3D" parent="."]','[node name="Action" type="Node3D" parent="Rig"]']
    emitted=set()
    def emit(part):
        if part in emitted:return
        parent_part=s.parents[part]
        if parent_part:emit(parent_part)
        parent=s.part_path(parent_part) if parent_part else "Rig/Action"
        if part in s.pivots:
            lines.append(f'[node name="{part}" type="Node3D" parent="{parent}"]\nposition = {vec(s.joints[part])}')
        else:
            extra='\nvisible = false' if part=="Mallet" else ''
            lines.append(f'[node name="{part}" type="MeshInstance3D" parent="{parent}"]\nposition = {vec(s.joints[part])}\nmesh = ExtResource("{parts.index(part)+2}_{part}"){extra}')
        emitted.add(part)
    for part in parts:emit(part)
    lines += ['[node name="ProjectileSocket" type="Marker3D" parent="Rig/Action"]\nposition = Vector3(0,1.4,-0.6)',
              '[node name="Locomotion" type="AnimationPlayer" parent="."]\ncallback_mode_process = 0\nlibraries = {&"": SubResource("AnimationLibrary_locomotion")}\nautoplay = "idle"',
              '[node name="Attack" type="AnimationPlayer" parent="."]\ncallback_mode_process = 0\nlibraries = {&"": SubResource("AnimationLibrary_attack")}']
    (OUT/"farmer.tscn").write_text("\n\n".join(lines)+"\n",encoding="utf-8")


def vec(v):
    return "Vector3(" + ", ".join(f"{float(x):.6f}" for x in v) + ")"


def anim_resource(name, duration, tracks, loop=False):
    lines=[f'[sub_resource type="Animation" id="Animation_{name}"]',f'resource_name = "{name}"',f'length = {duration}',f'loop_mode = {1 if loop else 0}']
    for i,track in enumerate(tracks):
        path,values=track[:2]
        times=track[2] if len(track)>2 else [duration*j/(len(values)-1) for j in range(len(values))]
        discrete=isinstance(values[0],bool)
        formatted=[("true" if v else "false") if isinstance(v,bool) else vec(v) for v in values]
        lines += [f'tracks/{i}/type = "value"',f'tracks/{i}/imported = false',f'tracks/{i}/enabled = true',
            f'tracks/{i}/path = NodePath("{path}")',f'tracks/{i}/interp = 1',f'tracks/{i}/loop_wrap = true',
            f'tracks/{i}/keys = {{"times": PackedFloat32Array({", ".join(str(round(t,5)) for t in times)}), "transitions": PackedFloat32Array({", ".join("1" for _ in times)}), "update": {1 if discrete else 0}, "values": [{", ".join(formatted)}]}}']
    return "\n".join(lines)


def godot_rotation(euler):
    x,y,z=euler
    return Rotation.from_euler("YXZ",[y,x,z]).as_matrix()


def godot_euler(basis):
    y,x,z=Rotation.from_matrix(basis).as_euler("YXZ")
    return (float(x),float(y),float(z))


def aimed_right_arm(s,left_rotation,draw):
    shoulder=np.array(s.joints["ArmRight"])
    grip=np.array(s.joints["ArmLeft"])+godot_rotation(left_rotation)@np.array(s.joints["Bow"])
    target=grip+np.array((0,0,draw))
    upper=np.array((.10,-.30,-.04)); lower=np.array((.02,-.24,-.075))
    a,b=np.linalg.norm(upper),np.linalg.norm(lower)
    direction=target-shoulder
    distance=min(np.linalg.norm(direction),a+b-.002)
    direction/=np.linalg.norm(direction)
    projection=(a*a-b*b+distance*distance)/(2*distance)
    height=math.sqrt(max(0,a*a-projection*projection))
    pole=np.array((.7,.12,.7))
    pole-=direction*np.dot(pole,direction)
    pole/=np.linalg.norm(pole)
    elbow=direction*projection+pole*height
    rotation=tm.geometry.align_vectors(upper,elbow)[:3,:3]
    local_hand=rotation.T@(direction*distance-elbow)
    forearm=tm.geometry.align_vectors(lower,local_hand)[:3,:3]
    return godot_euler(rotation),godot_euler(forearm)


def attack_tracks(s):
    tracks=[]
    def prop(part,kind):
        return ("Rig/Action" if part=="Action" else s.part_path(part))+":"+kind
    def rot(part,values,times): tracks.append((prop(part,"rotation"),values,times))
    def pos(part,offsets,times):
        base=np.zeros(3) if part=="Action" else np.array(s.joints[part])
        tracks.append((prop(part,"position"),[tuple(base+np.array(o)) for o in offsets],times))
    if s.name=="light_cavalry":
        t=[0,.07,.145,.18,.20,.25,.40,.62,.85]
        rot("Waist",[(0,y,0) for y in [0,.06,.14,.12,-.12,-.18,-.08,.015,0]],t)
        rot("ArmRight",[(x,0,z) for x,z in [(0,0),(.15,-.10),(.31,-.20),(.32,-.18),(.80,-.07),(.88,.03),(.46,.03),(.08,0),(0,0)]],t)
        rot("Sword",[(x,0,0) for x in [0,.15,.32,.25,-1.95,-2.25,-1.35,-.25,0]],t)
        rot("Head",[(0,y,0) for y in [0,-.03,-.07,-.06,.10,.12,.035,0,0]],t)
        rot("HorseHead",[(x,0,0) for x in [0,-.007,-.012,0,.025,.03,-.01,0,0]],t)
        return .85,tracks
    if s.name=="war_elephant":
        t=[0,.16,.34,.48,.55,.66,.90,1.23,1.55]
        rot("HeadMotion",[(x,0,0) for x in [0,-.055,-.12,-.08,.22,.27,.10,-.025,0]],t)
        rot("BodyMotion",[(x,0,0) for x in [0,-.006,-.015,-.012,.018,.026,.008,-.004,0]],t)
        rot("TrunkUpper",[(x,0,0) for x in [0,.06,.18,.28,.44,.48,.25,.06,0]],t)
        rot("TrunkMiddle",[(x,0,0) for x in [0,.03,.12,.18,.29,.31,.18,.03,0]],t)
        rot("TrunkTip",[(x,0,0) for x in [0,-.08,-.18,-.26,-.35,-.38,-.20,-.04,0]],t)
        pos("Action",[(0,y,z) for y,z in [(0,0),(0,.015),(-.012,.035),(-.008,.025),(-.025,-.13),(-.03,-.15),(-.01,-.06),(0,0),(0,0)]],t)
        pos("LegFrontRight",[(0,y,z) for y,z in [(0,0),(.035,-.015),(.17,-.065),(.09,-.10),(0,-.12),(0,-.12),(.015,-.055),(0,0),(0,0)]],t)
        rot("Rider",[(x,0,0) for x in [0,.025,.06,.04,-.06,-.075,-.015,.012,0]],t)
        return 1.55,tracks
    if s.name=="shield_guard":
        t=[0,.10,.22,.30,.37,.52,.72,.96]
        rot("Waist",[(0,0,0),(.015,.045,0),(.025,.08,0),(-.035,-.07,0),(-.04,-.09,0),(-.02,-.04,0),(0,.01,0),(0,0,0)],t)
        rot("ArmRight",[(0,0,0),(.10,.015,-.045),(.20,.03,-.07),(.72,-.02,-.035),(.79,-.03,-.04),(.48,0,-.03),(.13,0,0),(0,0,0)],t)
        rot("Sword",[(x,0,-.16) for x in [0,-.55,-1.25,-2.26,-2.34,-1.65,-.45,0]],t)
        rot("ArmLeft",[(x,y,0) for x,y in [(0,0),(.018,-.02),(.03,-.035),(.045,.035),(.04,.045),(.02,.02),(0,0),(0,0)]],t)
        rot("Head",[(0,y,0) for y in [0,-.02,-.05,.055,.06,.025,0,0]],t)
        pos("Action",[(0,y,z) for y,z in [(0,0),(-.006,.012),(-.01,.025),(-.015,-.09),(-.016,-.105),(-.008,-.04),(0,0),(0,0)]],t)
        return .96,tracks
    if s.name=="spearman":
        # Lower the wrist-held shaft, drive its point straight forward, then recover.
        # Every pose returns to rest; the weapon pivot remains inside the gauntlet.
        t=[0,.08,.16,.22,.29,.43,.65,.88]
        rot("Waist",[(0,0,0),(.015,.07,0),(.02,.13,0),(-.10,-.10,0),(-.12,-.12,0),(-.04,-.04,0),(0,.01,0),(0,0,0)],t)
        rot("ArmRight",[(x,y,0) for x,y in [(0,0),(.10,.05),(.22,.04),(.88,-.03),(.94,-.03),(.60,0),(.18,0),(0,0)]],t)
        rot("Spear",[(x,0,0) for x in [-.30,-.75,-1.55,-2.35,-2.39,-1.96,-.85,-.30]],t)
        rot("ArmLeft",[(x,0,z) for x,z in [(0,0),(.12,.04),(.24,.08),(.40,.09),(.42,.10),(.28,.05),(.10,.02),(0,0)]],t)
        rot("Head",[(0,y,0) for y in [0,-.035,-.07,.08,.09,.035,0,0]],t)
        pos("Action",[(0,y,z) for y,z in [(0,0),(0,.035),(-.01,.06),(-.025,-.17),(-.03,-.20),(-.01,-.07),(0,0),(0,0)]],t)
        return .88,tracks
    if s.name=="swordsman":
        t=[0,.075,.15,.195,.22,.26,.35,.51,.69,.86]
        rot("Waist",[(0,0,0),(.02,.08,-.02),(.03,.16,-.04),(.02,.14,-.035),(-.06,-.10,.015),(-.075,-.16,.025),(-.035,-.10,.015),(.005,-.04,0),(0,.01,0),(0,0,0)],t)
        rot("ArmRight",[(0,0,0),(.20,0,-.18),(.42,.04,-.30),(.46,.03,-.28),(.95,0,-.12),(.98,-.06,-.10),(.78,-.08,-.10),(.48,-.03,-.08),(.14,0,-.03),(0,0,0)],t)
        rot("Sword",[(0,0,-.28),(.25,0,-.32),(.52,0,-.38),(.48,0,-.34),(-2.42,0,.08),(-3.05,0,.20),(-2.80,0,.18),(-1.85,0,.10),(-.60,0,-.10),(0,0,-.28)],t)
        rot("ArmLeft",[(0,0,0),(.18,-.10,.08),(.38,-.23,.19),(.42,-.26,.22),(.52,-.13,.15),(.50,-.08,.12),(.35,-.06,.075),(.14,0,.025),(0,0,0),(0,0,0)],t)
        rot("Head",[(0,0,0),(-.015,-.065,0),(-.02,-.22,.025),(-.01,-.21,.02),(.035,.27,-.02),(.045,.35,-.035),(.02,.24,-.02),(0,.08,0),(0,0,0),(0,0,0)],t)
        pos("Action",[(0,0,0),(-.02,-.018,.025),(-.03,-.035,.05),(-.01,-.02,.025),(.035,0,-.19),(.04,-.01,-.23),(.025,-.023,-.17),(.01,-.01,-.06),(0,0,0),(0,0,0)],t)
        pos("LegLeft",[(0,0,0),(-.02,.02,-.02),(-.025,.045,-.075),(-.025,.018,-.13),(-.025,0,-.15),(-.025,0,-.15),(-.02,0,-.13),(-.012,.025,-.07),(0,.01,-.015),(0,0,0)],t)
        pos("LegRight",[(0,0,0),(.02,0,.03),(.025,0,.065),(.025,0,.065),(.03,0,.085),(.03,0,.085),(.02,0,.055),(.01,0,.02),(0,0,0),(0,0,0)],t)
        return .86,tracks
    if s.name=="knight":
        t=[0,.06,.13,.178,.20,.235,.33,.49,.71,.94]
        rot("Waist",[(0,0,0),(.015,.18,-.035),(.025,.42,-.08),(.02,.37,-.07),(-.11,-.42,.055),(-.12,-.59,.075),(-.045,-.34,.04),(.02,-.1,0),(0,.02,0),(0,0,0)],t)
        rot("ArmRight",[(0,0,0),(.48,-.18,-.38),(1.18,-.48,-.90),(1.12,-.45,-.87),(-1.32,.25,.43),(-1.49,.45,.63),(-.75,.25,.36),(-.14,.04,.08),(.035,0,0),(0,0,0)],t)
        # Brace the shield outside the horse's neck while the waist follows the
        # sword through. Only its off-hand pose changes, never the hit timing.
        rot("ArmLeft",[(0,0,0),(.16,-.13,.06),(.30,-.19,.13),(.32,-.20,.13),(.45,.55,.15),(.41,.81,.13),(.24,.45,.07),(.08,.15,.02),(0,0,0),(0,0,0)],t)
        rot("Head",[(0,0,0),(0,-.10,0),(-.025,-.27,.025),(-.02,-.25,.015),(.035,.24,-.02),(.04,.34,-.04),(.025,.2,-.02),(0,.05,0),(0,0,0),(0,0,0)],t)
        pos("Action",[(0,0,0),(0,-.018,.015),(0,-.027,.045),(0,-.005,.015),(.025,.02,-.23),(.03,-.015,-.29),(.015,-.035,-.22),(0,-.012,-.085),(0,.005,-.01),(0,0,0)],t)
        rot("Body",[(0,0,0),(.018,0,0),(.045,0,-.012),(.03,0,-.012),(-.065,0,.015),(-.05,0,.014),(.035,0,.008),(-.012,0,0),(0,0,0),(0,0,0)],t)
        rot("HorseHead",[(0,0,0),(-.015,0,0),(-.065,-.015,0),(-.04,-.01,0),(.16,.025,0),(.115,.02,0),(-.065,-.015,0),(.025,0,0),(-.005,0,0),(0,0,0)],t)
        pos("Waist",[(0,0,0),(0,-.008,.01),(0,-.025,.025),(0,-.01,.015),(0,.018,-.045),(0,-.005,-.03),(0,-.024,.005),(0,.008,0),(0,0,0),(0,0,0)],t)
        return .94,tracks
    if s.name=="archer":
        t=[0,.075,.135,.205,.26,.27,.295,.35,.50,.72,.90,1.10]
        left=[(0,0,0),(.82,-.32,0),(1.60,-.65,0),(1.60,-.65,0),(1.60,-.65,0),(1.60,-.65,0),(1.58,-.65,0),(1.50,-.61,0),(.95,-.40,0),(.25,-.10,0),(0,0,0),(0,0,0)]
        draw=[.14,.17,.29,.46,.46,.14,.205,.14,.14,.14,.14,.14]
        rot("ArmLeft",left,t)
        rot("Bow",[godot_euler(godot_rotation(v).T) for v in left],t)
        right=[];fore=[]
        for index,(left_pose,pull) in enumerate(zip(left,draw)):
            if index in (0,10,11):
                r,f=(0,0,0),(0,0,0)
            elif index==9:
                r,f=(.12,-.1,-.18),(.10,0,-.22)
            else:
                reach=.49 if index in (5,6,7) else pull
                r,f=aimed_right_arm(s,left_pose,reach)
            right.append(r);fore.append(f)
        rot("ArmRight",right,t);rot("ForearmRight",fore,t)
        for string,tip_y in (("StringUpper",.57),("StringLower",-.57)):
            tracks.append((prop(string,"position"),[(0,0,d) for d in draw],t))
            rot(string,[(math.atan2(.12-d,tip_y),0,0) for d in draw],t)
            tracks.append((prop(string,"scale"),[(1,math.hypot(tip_y,.12-d),1) for d in draw],t))
        tracks.append((prop("Arrow","position"),[(0,0,d) for d in draw],t))
        tracks.append((prop("Arrow","visible"),[True,False,True],[0,.27,.82]))
        rot("Waist",[(0,0,0),(.015,.055,-.025),(.005,.12,-.04),(0,.14,-.04),(0,.14,-.04),(-.02,.12,-.035),(-.035,.10,-.02),(-.015,.085,-.01),(.02,.03,0),(.01,-.025,.01),(0,0,0),(0,0,0)],t)
        rot("Head",[(0,0,0),(-.03,-.03,-.015),(-.045,-.1,-.04),(-.045,-.12,-.04),(-.045,-.12,-.04),(-.035,-.1,-.03),(-.015,-.07,-.015),(0,-.06,0),(.02,.02,0),(.015,.04,0),(0,0,0),(0,0,0)],t)
        pos("Action",[(0,0,0),(0,-.018,.015),(0,-.025,.025),(0,-.015,.04),(0,-.015,.04),(0,0,.018),(0,.005,.006),(0,-.008,0),(0,-.012,0),(0,0,0),(0,0,0),(0,0,0)],t)
        pos("LegLeft",[(0,0,0),(-.025,0,-.03),(-.04,0,-.045),(-.04,0,-.045),(-.04,0,-.045),(-.04,0,-.045),(-.04,0,-.04),(-.03,0,-.035),(-.015,0,-.02),(0,0,0),(0,0,0),(0,0,0)],t)
        return 1.10,tracks
    if s.name=="catapult":
        t=[0,.18,.32,.44,.48,.53,.61,.70,.86,1.08,1.34,1.53,1.72]
        rot("ThrowArm",[(x,0,0) for x in [0,.10,.22,.25,-1.60,-1.82,-1.56,-1.73,-1.54,-.92,-.20,.025,0]],t)
        pos("Action",[(0,0,0),(0,-.003,0),(0,-.008,-.006),(0,-.012,-.012),(0,.023,.015),(0,.012,.09),(0,-.012,.065),(0,.006,.028),(0,-.003,.008),(0,0,0),(0,0,0),(0,0,0),(0,0,0)],t)
        rot("Body",[(x,0,z) for x,z in [(0,0),(-.003,0),(-.008,0),(-.012,0),(.018,.004),(.032,-.004),(-.016,.004),(.012,-.002),(-.005,0),(0,0),(0,0),(0,0),(0,0)]],t)
        for wheel in [p for p in s.pivots if p.endswith("Kick")]:
            rot(wheel,[(x,0,0) for x in [0,0,-.008,-.015,.03,.17,.11,.052,.016,0,0,0,0]],t)
        tracks.append((prop("Payload","visible"),[True,False,True],[0,.48,1.61]))
        return 1.72,tracks
    t=[0,.12,.22,.249,.25,.285,.34,.415,.50,.64,.82,1.02]
    pos("Barrel",[(0,y,z) for y,z in [(0,0),(.003,-.006),(.006,-.012),(.006,-.012),(.006,-.012),(-.025,.32),(-.018,.27),(-.011,.16),(-.004,.078),(.004,.019),(0,0),(0,0)]],t)
    rot("Barrel",[(x,0,0) for x in [0,-.012,-.026,-.026,-.026,-.075,-.043,-.052,-.025,-.008,.004,0]],t)
    pos("Action",[(0,y,z) for y,z in [(0,0),(0,0),(-.005,0),(-.005,0),(-.005,0),(.023,.15),(.010,.12),(-.010,.065),(.004,.028),(-.002,.006),(0,0),(0,0)]],t)
    rot("Body",[(x,0,z) for x,z in [(0,0),(0,0),(-.005,0),(-.005,0),(-.005,0),(.065,.01),(.025,-.012),(-.025,.008),(.014,-.004),(-.004,0),(0,0),(0,0)]],t)
    for wheel in [p for p in s.pivots if p.endswith("Kick")]:
        rot(wheel,[(x,0,0) for x in [0,0,0,0,0,.27,.22,.115,.045,.008,0,0]],t)
    return 1.02,tracks


def write_scene(s):
    if s.name == "heavy_cannon":
        from unit_heavy_cannon import write_heavy_cannon_scene
        write_heavy_cannon_scene(s)
        return
    if s.name == "priest":
        from unit_priest import write_priest_scene
        write_priest_scene(s)
        return
    if s.name == "engineer":
        from unit_engineer import write_engineer_scene
        write_engineer_scene(s)
        return
    if s.name=="farmer":
        write_farmer_scene(s)
        return
    if s.name in ("catapult","cannon"):
        for part in [p for p in s.parts if p.startswith("Wheel")]:
            kick=s.pivot(part+"Kick",s.joints[part])
            s.reparent(part,kick)
    parts=list(s.parts)
    lines=[f'[gd_scene load_steps={len(parts)+7} format=3]',
           '[ext_resource type="Script" path="res://scripts/unit_visual.gd" id="1_script"]']
    for i,p in enumerate(parts):
        lines.append(f'[ext_resource type="ArrayMesh" path="res://assets/models/units/{s.name}/{p}.res" id="{i+2}_{p}"]')
    walk=[]
    idle=[]
    if s.name in ("swordsman","spearman","archer","shield_guard"):
        for p,sign in (("LegLeft",1),("LegRight",-1)):
            amplitude = .48 if s.name == "shield_guard" else .56
            walk.append((f"Rig/{p}:rotation",[(sign*a,0,0) for a in (0,amplitude,0,-amplitude,0)]))
            idle.append((f"Rig/{p}:rotation",[(0,0,0),(0,0,0)]))
        rise = .032 if s.name == "shield_guard" else .042
        walk.append(("Rig:position",[(0,y,0) for y in (0,rise,0,rise,0)]))
        idle.append(("Rig:position",[(0,0,0),(0,.014,0),(0,0,0)]))
    elif s.name=="war_elephant":
        cycle=1.24
        times=[cycle*i/16 for i in range(17)]
        for p,phase in (("LegFrontLeft",0), ("LegRearLeft",.24),
                        ("LegFrontRight",.50), ("LegRearRight",.74)):
            # Four-beat walk: each foot remains down for three quarters of
            # its cycle, then lifts forward. The model faces -Z: positive
            # X rotation puts a foot forward, so stance must decrease it.
            rotations=[]; offsets=[]
            base=np.array(s.joints[p+"Step"])
            for i in range(17):
                u=(i/16+phase)%1
                if u<.75:
                    angle=.24-.48*u/.75
                    lift=0.0
                else:
                    v=(u-.75)/.25
                    angle=-.24+.48*v
                    lift=.15*math.sin(v*math.pi)
                rotations.append((angle,0,0))
                offsets.append(tuple(base+np.array((0,lift,0))))
            walk.append((f"Rig/{p}Step:rotation",rotations,times))
            walk.append((f"Rig/{p}Step:position",offsets,times))
            idle.append((f"Rig/{p}Step:rotation",[(0,0,0),(0,0,0)]))
            idle.append((f"Rig/{p}Step:position",[tuple(base),tuple(base)]))
        for tracks,amount in ((idle,.012),(walk,.032)):
            base=np.array(s.joints["BodyMotion"])
            tracks.append(("Rig/BodyMotion:position",[tuple(base+np.array((0,y,0))) for y in (0,amount,0,amount,0)]))
            for part,sign in (("EarLeft",1),("EarRight",-1)):
                tracks.append((f"Rig/{part}:rotation",[(0,sign*y,0) for y in (0,.07,0,-.04,0)]))
            tracks.append(("Rig/TrunkSwing:rotation",[(x,0,z) for x,z in [(0,0),(.025,.028),(0,0),(-.02,-.025),(0,0)]]))
            tracks.append(("Rig/Tail:rotation",[(0,0,z) for z in (0,.10,0,-.08,0)]))
    elif s.name=="light_cavalry":
        cycle=.48
        # Diagonal pairs alternate. Stance travel = speed * planted time;
        # knees fold on the forward recovery and hooves stay level at contact.
        samples=100
        times=[cycle*i/samples for i in range(samples+1)]
        stance=.32
        stroke=6.8*cycle*stance
        for p,phase in (("LegFrontLeft",0),("LegRearRight",0),
                        ("LegFrontRight",.5),("LegRearLeft",.5)):
            curves=[[],[],[]]
            rear=p.startswith("LegRear")
            for i in range(samples+1):
                u=(i/samples+phase)%1
                if u<stance:
                    z=-stroke/2+6.8*cycle*u
                    lift=0
                else:
                    v=(u-stance)/(1-stance)
                    z=stroke/2-stroke*v*v*(3-2*v)
                    lift=.23*math.sin(v*math.pi)**2
                for curve,angle in zip(curves,light_horse_leg_pose(z,lift,rear)):
                    curve.append((angle,0,0))
            for suffix,curve,rest in zip(("","Lower","Hoof"),curves,light_horse_leg_pose(0,0,rear,1.14)):
                walk.append((f"Rig/{p+suffix}:rotation",curve,times))
                idle.append((f"Rig/{p+suffix}:rotation",[(rest,0,0),(rest,0,0)]))
            # Tuck the hip joint further inside the barrel when standing, so
            # the exposed forelegs rest upright instead of permanently crouching.
            base=np.array(s.joints[p])
            walk.append((f"Rig/{p}:position",[tuple(base),tuple(base)]))
            rest=tuple(base+np.array((0,.15,0)))
            idle.append((f"Rig/{p}:position",[rest,rest]))
        walk.append(("Rig/BodyMotion:position",[(0,y,0) for y in (0,.032,0,.032,0)]))
        idle.append(("Rig/BodyMotion:position",[(0,0,0),(0,.012,0),(0,0,0)]))
    elif s.name=="knight":
        for p,sign in (("LegFrontLeft",1),("LegFrontRight",-1),("LegRearLeft",-1),("LegRearRight",1)):
            walk.append((f"Rig/{p}:rotation",[(sign*a,0,0) for a in (0,.53,0,-.53,0)]))
            idle.append((f"Rig/{p}:rotation",[(0,0,0),(0,0,0)]))
        walk.append(("Rig:position",[(0,y,0) for y in (0,.065,0,.065,0)]))
        idle.append(("Rig:position",[(0,0,0),(0,.016,0),(0,0,0)]))
    else:
        for p in parts:
            if p.startswith("Wheel"):
                walk.append((f"Rig/{p}:rotation",[(0,0,0),(-math.pi,0,0),(-math.tau,0,0)]))
        idle.append(("Rig:position",[(0,0,0),(0,0,0)]))
    def remap(track):
        path,values=track[:2]
        if path.startswith("Rig/"):
            node,prop=path[4:].split(":")
            path=s.part_path(node)+":"+prop
        return (path,values,*track[2:])
    walk=[remap(track) for track in walk]
    idle=[remap(track) for track in idle]
    duration,strike=attack_tracks(s)
    socket_parent=s.part_path("Bow") if s.name=="archer" else s.part_path("ThrowArm") if s.name=="catapult" else s.part_path("Barrel") if s.name=="cannon" else "Rig/Action"
    socket_position=(0,0,-.83) if s.name=="archer" else (0,.91,.89) if s.name=="catapult" else (0,-.10,-1.25) if s.name=="cannon" else (0,1.4,-.6)
    walk_duration = .48 if s.name=="light_cavalry" else 1.24 if s.name=="war_elephant" else .60 if s.name=="knight" else .72
    lines += [anim_resource("walk",walk_duration,walk,True),
              anim_resource("idle",2.6,idle,True),anim_resource("strike",duration,strike),
              '[sub_resource type="AnimationLibrary" id="AnimationLibrary_locomotion"]\n_data = {&"idle": SubResource("Animation_idle"), &"walk": SubResource("Animation_walk")}',
              '[sub_resource type="AnimationLibrary" id="AnimationLibrary_attack"]\n_data = {&"strike": SubResource("Animation_strike")}',
              f'[node name="{s.name.title()}" type="Node3D"]\nscript = ExtResource("1_script")\nkind = "{s.name}"\nprojectile_socket = NodePath("{socket_parent}/ProjectileSocket")',
              '[node name="Rig" type="Node3D" parent="."]',
              '[node name="Action" type="Node3D" parent="Rig"]']
    emitted=set()
    def emit(p):
        if p in emitted:return
        parent_part=s.parents[p]
        if parent_part:emit(parent_part)
        parent=s.part_path(parent_part) if parent_part else "Rig/Action"
        if p in s.pivots:
            lines.append(f'[node name="{p}" type="Node3D" parent="{parent}"]\nposition = {vec(s.joints[p])}')
        else:
            i=parts.index(p)
            extra=""
            if p.startswith("String"):
                tip_y=.57 if p=="StringUpper" else -.57
                extra=f'\nrotation = {vec((math.atan2(-.02,tip_y),0,0))}\nscale = {vec((1,math.hypot(tip_y,.02),1))}'
            if s.name in ("swordsman","shield_guard") and p == "Sword":
                extra = f'\nrotation = {vec((0,0,-.16 if s.name == "shield_guard" else -.28))}'
            if s.name == "spearman" and p == "Spear":
                extra = f'\nrotation = {vec((-.30,0,0))}'
            lines.append(f'[node name="{p}" type="MeshInstance3D" parent="{parent}"]\nposition = {vec(s.joints[p])}\nmesh = ExtResource("{i+2}_{p}"){extra}')
        emitted.add(p)
    for p in parts:emit(p)
    lines.append(f'[node name="ProjectileSocket" type="Marker3D" parent="{socket_parent}"]\nposition = {vec(socket_position)}')
    lines += ['[node name="Locomotion" type="AnimationPlayer" parent="."]\ncallback_mode_process = 0\nlibraries = {&"": SubResource("AnimationLibrary_locomotion")}\nautoplay = "idle"',
              '[node name="Attack" type="AnimationPlayer" parent="."]\ncallback_mode_process = 0\nlibraries = {&"": SubResource("AnimationLibrary_attack")}']
    lines += ['[node name="VisibilityNotifier" type="VisibleOnScreenNotifier3D" parent="."]\naabb = AABB(-4, -2, -4, 8, 9, 8)',
              '[connection signal="screen_entered" from="VisibilityNotifier" to="." method="_on_screen_entered"]',
              '[connection signal="screen_exited" from="VisibilityNotifier" to="." method="_on_screen_exited"]']
    (OUT/f"{s.name}.tscn").write_text("\n\n".join(lines)+"\n",encoding="utf-8")


if __name__=="__main__":
    import argparse
    from unit_engineer import build_engineer
    from unit_priest import build_priest
    from unit_heavy_cannon import build_heavy_cannon
    builders={"swordsman":lambda:infantry("swordsman"), "shield_guard":shield_guard, "spearman":lambda:infantry("spearman"),
              "archer":lambda:infantry("archer",True), "knight":horse_knight, "war_elephant":war_elephant, "light_cavalry":light_cavalry,
              "catapult":catapult, "cannon":cannon, "heavy_cannon":build_heavy_cannon, "farmer":farmer, "engineer":build_engineer, "priest":build_priest}
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kinds",nargs="*",help="Only rebuild these units (default: all)")
    args=parser.parse_args()
    for kind in args.kinds or builders:
        if kind not in builders:
            parser.error(f"Unknown unit: {kind}")
        builders[kind]().save()
