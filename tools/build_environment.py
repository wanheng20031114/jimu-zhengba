"""Offline, deterministic architectural modelling for Ashen Kingdom.

All visible detail is exported as actual low-poly GLB geometry, grouped by
material family.  Godot only instances the saved models; it does not build
individual shingles, stones, spokes or grass blades while the game runs.
"""
from __future__ import annotations

import json
import math
from collections import defaultdict
from pathlib import Path

import numpy as np
import trimesh as tm
from shapely import constrained_delaunay_triangles
from shapely.geometry import Polygon

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/models/environment"
SCENES = ROOT / "scenes"
OUT.mkdir(parents=True, exist_ok=True)
SCENES.mkdir(parents=True, exist_ok=True)
RNG = np.random.default_rng(932710)

C = {
    "stone": (197, 177, 134), "stone_light": (226, 211, 172),
    "plaster": (218, 202, 164), "mortar": (130, 118, 94),
    "wood": (101, 66, 39), "wood_light": (145, 104, 62),
    "wood_dark": (62, 43, 31), "iron": (71, 76, 72),
    "iron_light": (132, 138, 130), "gold": (209, 159, 64),
    "slate": (44, 78, 121), "slate_light": (62, 100, 145),
    "terracotta": (158, 77, 46), "terracotta_light": (190, 104, 58),
    "blue": (38, 85, 129), "red": (140, 45, 34),
    "dark": (42, 37, 31), "glass": (48, 66, 62),
    "leaf": (91, 105, 54), "leaf_light": (125, 131, 65),
    "grass": (136, 129, 74), "grass_light": (171, 153, 91),
    "earth": (126, 98, 60), "sand": (166, 132, 79),
    "road": (195, 159, 102), "water": (71, 96, 92),
    "paving": (148, 137, 113), "road_mortar": (104, 91, 66),
    "canvas": (180, 166, 131), "burlap": (154, 127, 82),
    "straw": (157, 129, 62), "straw_light": (193, 164, 87),
    "granite": (103, 103, 94), "granite_light": (142, 141, 123),
    "ore_rock": (78, 83, 82), "ore_rock_light": (115, 119, 107),
    "gold_light": (238, 190, 82), "gold_dark": (170, 119, 39),
    "leaf_dark": (55, 75, 47), "leaf_pine": (68, 89, 50),
    "bark": (95, 67, 45), "bark_light": (129, 90, 51),
}


def color(value, variation=0.0):
    value = C.get(value, value) if isinstance(value, str) else value
    return np.array([*np.clip(np.asarray(value, dtype=float) * (1.0 + variation), 0, 255), 255], dtype=np.uint8)


def write_asset(path, data):
    """Publish complete files atomically while the user's editor auto-imports."""
    if isinstance(data,str):
        data=data.encode("utf-8")
    if path.exists() and path.read_bytes()==data:
        return
    temporary=path.with_suffix(path.suffix+".tmp")
    temporary.write_bytes(data)
    temporary.replace(path)


def family(value):
    if not isinstance(value, str):
        return "Earth"
    if value in ("iron", "iron_light", "gold", "gold_light", "gold_dark"):
        return "Metal"
    if value in ("blue", "red", "canvas", "burlap"):
        return "Fabric"
    if "wood" in value or "bark" in value:
        return "Timber"
    if "leaf" in value or "grass" in value:
        return "Foliage"
    if value in ("slate", "slate_light", "terracotta", "terracotta_light"):
        return "Roof"
    if value in ("glass", "water"):
        return "Glass"
    return "Stone"


def transform(pos=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1)):
    mat = tm.transformations.euler_matrix(*rot)
    mat[:3, :3] = mat[:3, :3] @ np.diag(scale)
    mat[:3, 3] = pos
    return mat


def extruded_contour(points, depth, center_z):
    """Preserve concave breaks in a masonry silhouette with ear clipping."""
    def cross2(a,b):
        return a[0]*b[1]-a[1]*b[0]
    points=np.asarray(points,dtype=float)
    area=sum(cross2(points[i],points[(i+1)%len(points)]) for i in range(len(points)))
    if area<0:
        points=points[::-1]
    remaining=list(range(len(points)))
    triangles=[]
    while len(remaining)>3:
        for index,current in enumerate(remaining):
            previous=remaining[index-1]
            following=remaining[(index+1)%len(remaining)]
            a,b,c=points[previous],points[current],points[following]
            if cross2(b-a,c-b)<=1e-9:
                continue
            occupied=False
            for other in remaining:
                if other in (previous,current,following):continue
                p=points[other]
                if min(cross2(b-a,p-a),cross2(c-b,p-b),cross2(a-c,p-c))>=-1e-9:
                    occupied=True
                    break
            if not occupied:
                triangles.append([previous,current,following])
                remaining.pop(index)
                break
        else:
            raise ValueError("The masonry contour must be a simple polygon")
    triangles.append(remaining)
    count=len(points)
    verts=[[x,y,z] for z in (center_z-depth/2,center_z+depth/2) for x,y in points]
    faces=[tri[::-1] for tri in triangles]+[[i+count for i in tri] for tri in triangles]
    for i in range(count):
        j=(i+1)%count
        faces.extend([[i,j,count+j],[i,count+j,count+i]])
    mesh=tm.Trimesh(verts,faces,process=False)
    mesh.fix_normals()
    return mesh


class Model:
    def __init__(self):
        self.parts = defaultdict(list)

    def add(self, mesh, material="stone", pos=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1), variation=0.0):
        mesh = mesh.copy()
        mesh.apply_transform(transform(pos, rot, scale))
        mesh.visual.vertex_colors = np.tile(color(material, variation), (len(mesh.vertices), 1))
        mesh.metadata["heraldry"] = isinstance(material,str) and material in ("blue","red","slate","slate_light")
        self.parts[family(material)].append(mesh)
        return mesh

    def box(self, size, pos, material="stone", rot=(0, 0, 0), bevel=0.0, variation=0.0):
        size = np.asarray(size, dtype=float)
        if bevel:
            radius = min(bevel, min(size) * .24)
            verts = []
            for axis in range(3):
                for a in (-1, 1):
                    for b in (-1, 1):
                        for d in (-1, 1):
                            p = np.array([a, b, d]) * (size * .5 - radius)
                            p[axis] += np.sign(p[axis]) * radius
                            verts.append(p)
            mesh = tm.convex.convex_hull(np.asarray(verts))
        else:
            mesh = tm.creation.box(size)
        return self.add(mesh, material, pos, rot, variation=variation)

    def cylinder(self, radius, height, pos, material="wood", sections=10, rot=(0, 0, 0), variation=0.0):
        mesh = tm.creation.cylinder(radius=radius, height=height, sections=sections)
        mesh.apply_transform(tm.transformations.rotation_matrix(-math.pi / 2, [1, 0, 0]))
        return self.add(mesh, material, pos, rot, variation=variation)

    def cone(self, r1, r2, height, pos, material="wood", sections=8, rot=(0, 0, 0)):
        verts = []
        for y, r in ((-height / 2, r1), (height / 2, r2)):
            verts.extend([(math.cos(a * math.tau / sections) * r, y, math.sin(a * math.tau / sections) * r) for a in range(sections)])
        faces = []
        for i in range(sections):
            j = (i + 1) % sections
            faces += [[i, j, sections + j], [i, sections + j, sections + i]]
        faces += [[0, i + 1, i] for i in range(1, sections - 1)]
        faces += [[sections, sections + i, sections + i + 1] for i in range(1, sections - 1)]
        mesh = tm.Trimesh(verts, faces, process=False)
        mesh.fix_normals()
        return self.add(mesh, material, pos, rot)

    def beam(self, start, end, width=.16, material="wood", depth=None, bevel=.012):
        start, end = np.asarray(start, float), np.asarray(end, float)
        delta = end - start
        mesh = tm.creation.box((width, np.linalg.norm(delta), depth or width))
        mat = tm.geometry.align_vectors([0, 1, 0], delta)
        mesh.apply_transform(mat)
        return self.add(mesh, material, (start + end) / 2)

    def polygon(self, points, thickness=.12, material="stone", axis="z", variation=0.0):
        # Convex polygons used for stone fractures, roof gables and fabric.
        points = np.asarray(points)
        if axis == "z":
            verts = [[x, y, z] for z in (-thickness / 2, thickness / 2) for x, y in points]
        else:
            verts = [[x, y, z] for y in (-thickness / 2, thickness / 2) for x, z in points]
        return self.add(tm.convex.convex_hull(np.asarray(verts)), material, variation=variation)

    def ring(self, inner, outer, height, pos, material="iron", sections=14, rot=(0, 0, 0)):
        verts = []
        for y in (-height / 2, height / 2):
            for radius in (inner, outer):
                verts.extend([(math.cos(a * math.tau / sections) * radius, y, math.sin(a * math.tau / sections) * radius) for a in range(sections)])
        faces = []
        for a in range(sections):
            b = (a + 1) % sections
            for q0, q1, q2, q3 in ((a, b, sections + b, sections + a), (2*sections+a, 3*sections+a, 3*sections+b, 2*sections+b), (a, 2*sections+a, 2*sections+b, b), (sections+a, sections+b, 3*sections+b, 3*sections+a)):
                faces.extend([[q0, q1, q2], [q0, q2, q3]])
        mesh = tm.Trimesh(verts, faces, process=False)
        mesh.fix_normals()
        return self.add(mesh, material, pos, rot)

    def absorb(self, other, pos=(0, 0, 0), rot=0.0, scale=(1, 1, 1)):
        mat = transform(pos, (0, rot, 0), scale)
        for group, meshes in other.parts.items():
            for mesh in meshes:
                item = mesh.copy()
                item.apply_transform(mat)
                self.parts[group].append(item)

    def save(self, name, wrapper=True):
        scene = tm.Scene()
        for group, meshes in self.parts.items():
            merged = tm.util.concatenate(meshes)
            if wrapper:
                merged.vertices[:, 1] = np.maximum(merged.vertices[:, 1], 0.0)
            # Compare triangles by position without welding their vertices:
            # neighboring stones/soil regions intentionally keep distinct colors
            # and hard normals at an otherwise shared geometric edge.
            triangles=np.round(merged.triangles,8)
            order=np.lexsort((triangles[:,:,2],triangles[:,:,1],triangles[:,:,0]),axis=1)
            canonical=np.take_along_axis(triangles,order[:,:,None],axis=1)
            _,unique=np.unique(canonical.reshape((-1,9)),axis=0,return_index=True)
            merged.update_faces(np.sort(unique))
            merged.update_faces(merged.nondegenerate_faces(height=1e-7))
            merged.unmerge_vertices()
            rgba = merged.visual.vertex_colors.copy()
            srgb = rgba[:, :3].astype(np.float32) / 255.0
            linear = np.where(srgb <= .04045, srgb / 12.92, ((srgb + .055) / 1.055) ** 2.4)
            rgba[:, :3] = np.round(linear * 255).astype(np.uint8)
            roughness = .82
            metalness = 0.0
            if group == "Metal":
                metalness, roughness = .65, .38
            elif group == "Glass":
                metalness, roughness = .05, .32
            material = tm.visual.material.PBRMaterial(name=group, baseColorFactor=[255, 255, 255, 255], metallicFactor=metalness, roughnessFactor=roughness, doubleSided=False)
            merged.visual = tm.visual.TextureVisuals(material=material)
            merged.visual.vertex_attributes["color"] = rgba
            # Export glTF COLOR_0 alongside PBR materials.
            merged.vertex_attributes["_COLOR_0"] = rgba.astype(np.float32) / 255.0
            scene.add_geometry(merged, node_name=group, geom_name=group)
        # trimesh exports vertex color automatically for ColorVisuals, with a
        # neutral PBR material added afterwards below to retain exact palette.
        for geometry in scene.geometry.values():
            rgba = (geometry.vertex_attributes.pop("_COLOR_0") * 255).astype(np.uint8)
            mat = geometry.visual.material
            geometry.visual = tm.visual.ColorVisuals(mesh=geometry, vertex_colors=rgba)
            geometry.metadata["material_family"] = mat.name
        floor_offset = scene.bounds[0, 1]
        if wrapper and floor_offset > 0.0001:
            for geometry in scene.geometry.values():
                geometry.vertices[:, 1] -= floor_offset

        def materials(tree):
            tree["materials"] = []
            for mesh in tree["meshes"]:
                group = mesh["name"]
                metalness, roughness = (.65, .38) if group == "Metal" else (0.0, .84)
                if group == "Glass":
                    metalness, roughness = .05, .34
                index = len(tree["materials"])
                tree["materials"].append({"name": group, "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1], "metallicFactor": metalness, "roughnessFactor": roughness}, "doubleSided": group in ("Fabric", "Foliage")})
                for primitive in mesh["primitives"]:
                    primitive["material"] = index
        blob = tm.exchange.gltf.export_glb(scene, include_normals=True, tree_postprocessor=materials)
        write_asset(OUT / f"{name}.glb",blob)
        if wrapper:
            extras=''
            flag_resource=''
            if name=="headquarters":
                flag_resource='\n[ext_resource type="PackedScene" path="res://assets/models/environment/royal_banner.tscn" id="2_banner"]'
                extras='\n[node name="RoyalBannerLeft" parent="." instance=ExtResource("2_banner")]\nposition = Vector3(-3.23, 0.48, 3.365)\n\n[node name="RoyalBannerRight" parent="." instance=ExtResource("2_banner")]\nposition = Vector3(3.23, 0.48, 3.365)\n'
            write_asset(OUT / f"{name}.tscn",f'[gd_scene load_steps={3 if name=="headquarters" else 2} format=3]\n\n[ext_resource type="PackedScene" path="res://assets/models/environment/{name}.glb" id="1_visual"]{flag_resource}\n\n[node name="{name.title().replace("_", "")}" type="Node3D"]\n\n[node name="Architecture" parent="." instance=ExtResource("1_visual")]\n{extras}')
            if name=="defense_tower":
                # Saved material overrides retain the consolidated sculpture and
                # expose a native per-instance construction plane to its building.
                lines=['[gd_scene load_steps=5 format=3]',
                       '[ext_resource type="PackedScene" path="res://assets/models/environment/defense_tower.glb" id="1_visual"]',
                       '[ext_resource type="Shader" path="res://assets/models/environment/construction.gdshader" id="2_shader"]',
                       '[sub_resource type="ShaderMaterial" id="Matte"]\nshader = ExtResource("2_shader")\nshader_parameter/metalness = 0.0\nshader_parameter/roughness = 0.84',
                       '[sub_resource type="ShaderMaterial" id="Metal"]\nshader = ExtResource("2_shader")\nshader_parameter/metalness = 0.65\nshader_parameter/roughness = 0.38',
                       '[node name="DefenseTower" type="Node3D"]',
                       '[node name="Architecture" parent="." instance=ExtResource("1_visual")]']
                for i,group in enumerate(scene.geometry):
                    material="Metal" if group=="Metal" else "Matte"
                    lines.append(f'[node name="{group}" parent="Architecture" index="{i}"]\nmaterial_override = SubResource("{material}")')
                lines.append('[editable path="Architecture"]')
                write_asset(OUT/"defense_tower.tscn","\n\n".join(lines)+"\n")
        bounds = scene.bounds
        print(f"{name}: {sum(len(g.faces) for g in scene.geometry.values()):,} triangles, {len(scene.geometry)} meshes, bounds {np.round(bounds, 2).tolist()}")
        return {"bounds": bounds.tolist(), "triangles": sum(len(g.faces) for g in scene.geometry.values()), "meshes": len(scene.geometry)}


def stone_rows(m, w, h, d, center=(0, 0, 0), block=1.05, rows=None):
    x, y, z = center
    rows = rows or max(1, round(h / .40))
    course = h / rows
    count = max(2, round(w / block))
    for row in range(rows):
        offset = (row % 2) * .5
        divisions = [-w / 2] + [(-w / 2 + (i + offset) * w / count) for i in range(count + 1) if -w / 2 + .08 < -w / 2 + (i + offset) * w / count < w / 2 - .08] + [w / 2]
        for left, right in zip(divisions, divisions[1:]):
            m.box((right-left-.025, course-.024, d), (x+(left+right)/2, y+(row+.5)*course, z), "stone", bevel=.045, variation=RNG.uniform(-.06, .10))


def window(m, x, y, z, width=.78, height=1.08, shutters=True):
    m.box((width+.22, height+.23, .15), (x, y, z), "stone_light", bevel=.035)
    m.box((width, height, .17), (x, y+.01, z+.065), "dark")
    m.box((.075, height-.04, .07), (x, y, z+.18), "wood")
    m.box((width-.04, .065, .08), (x, y+.03, z+.22), "wood")
    m.box((width+.34, .12, .28), (x, y-height/2-.06, z+.09), "stone_light", bevel=.025)
    if shutters:
        for sign in (-1, 1):
            m.box((.27, height, .11), (x+sign*(width/2+.13), y, z+.13), "wood_light", rot=(0, sign*.27, 0), bevel=.013)
            for yy in (-height*.3, height*.3):
                # Hinge bands follow their shutter plane and sit 3 cm proud.
                m.box((.25, .07, .04), (x+sign*(width/2+.13)+sign*math.sin(.27)*.10, y+yy, z+.13+math.cos(.27)*.10), "wood_dark", rot=(0, sign*.27, 0))


def arched_gate(m, width, height, depth, center, portcullis=False):
    x, base, z = center
    radius = width / 2
    spring = height - radius
    m.box((width, spring-.04, .08), (x, base+(spring+.04)/2, z), "dark")
    arch = [[x-radius, base+spring]] + [[x+math.cos(a)*radius, base+spring+math.sin(a)*radius] for a in np.linspace(math.pi, 0, 13)] + [[x+radius, base+spring]]
    mesh = tm.convex.convex_hull(np.asarray([[xx, yy, zz] for zz in (z-.04, z+.04) for xx, yy in arch]))
    m.add(mesh, "dark")
    for i in range(max(5, int(width / .23))):
        xx = -radius + (i+.5)*width/max(5,int(width/.23))
        hh = spring + math.sqrt(max(0, radius*radius-xx*xx)) - .10
        m.box((width/max(5,int(width/.23))-.027, hh, .085), (x+xx, base+hh/2, z+.055), "wood_dark" if portcullis else "wood", bevel=.012)
    for sign in (-1, 1):
        for j in range(max(2, math.ceil(spring/.39))):
            hh = spring / max(2, math.ceil(spring/.39))
            m.box((.33, hh-.02, depth), (x+sign*(radius+.16), base+(j+.5)*hh, z+.12), "stone_light", bevel=.04, variation=RNG.uniform(-.07,.04))
    for i in range(11):
        a1, a2 = i*math.pi/11+.011, (i+1)*math.pi/11-.011
        poly = [(x+math.cos(a1)*radius, base+spring+math.sin(a1)*radius), (x+math.cos(a1)*(radius+.34), base+spring+math.sin(a1)*(radius+.34)), (x+math.cos(a2)*(radius+.34), base+spring+math.sin(a2)*(radius+.34)), (x+math.cos(a2)*radius, base+spring+math.sin(a2)*radius)]
        mesh = tm.convex.convex_hull(np.asarray([[xx, yy, zz] for zz in (z-depth/2, z+depth/2) for xx, yy in poly]))
        m.add(mesh, "stone_light", variation=RNG.uniform(-.08,.07))
    for yy in (spring*.28, spring*.75):
        m.box((width-.12, .11, .10), (x, base+yy, z+.14), "iron")
        for xx in (-width*.35, width*.35):
            m.cylinder(.035, .035, (x+xx, base+yy, z+.21), "iron_light", sections=6, rot=(math.pi/2,0,0))
    if portcullis:
        for xx in np.arange(-radius+.13, radius, .29):
            hh = spring + math.sqrt(max(0,radius*radius-xx*xx))-.12
            m.box((.065, hh, .07), (x+xx, base+hh/2, z+.18), "iron")


def banner(m, x, y, z, team="blue", size=1.0):
    m.cylinder(.045, 2.0*size, (x,y+size,z), "wood_dark", sections=8)
    m.cone(.09, 0, .24, (x,y+2.10*size,z), "gold", sections=6)
    verts = [[x,y+1.87*size,z], [x+.48*size,y+1.94*size,z+.05], [x+1.12*size,y+1.74*size,z+.10], [x+.94*size,y+1.27*size,z+.12], [x+.45*size,y+1.37*size,z+.03], [x,y+1.25*size,z]]
    faces = [[0,1,5],[1,4,5],[1,2,4],[2,3,4]]
    sheet = tm.Trimesh(verts, faces, process=False)
    m.add(sheet, team)
    # Fabric is already a double-sided glTF material: one sheet, no duplicate
    # back faces. The raised crest clears the maximum local fold depth.
    m.box((.085*size,.43*size,.019), (x+.43*size,y+1.61*size,z+.145), "gold")
    m.box((.40*size,.073*size,.020), (x+.43*size,y+1.62*size,z+.175), "gold")


def tiled_roof(m, w, d, eave, peak, center=(0,0), blue=False):
    x,z = center
    hw, hd = w/2, d/2
    verts = [[x-hw,eave,z-hd],[x+hw,eave,z-hd],[x-hw,peak,z],[x+hw,peak,z],[x-hw,eave,z+hd],[x+hw,eave,z+hd]]
    roof = tm.Trimesh(verts, [[0,1,3],[0,3,2],[2,3,5],[2,5,4],[0,2,4],[1,5,3],[0,4,5],[0,5,1]], process=False)
    roof.fix_normals()
    m.add(roof, "slate" if blue else "terracotta")
    slope=(peak-eave)/hd
    angle=math.atan(slope)
    rows=max(4,round(hd/.38))
    cols=max(5,round(w/.47))
    for sign in (-1,1):
        for row in range(rows):
            zz=(row+.53)*hd/rows
            yy=peak-slope*zz+.06
            for col in range(cols):
                xx=-hw+(col+.5)*w/cols+(row%2-.5)*.055
                material=("slate_light" if (col+row)%4==0 else "slate") if blue else ("terracotta_light" if (col+row)%4==0 else "terracotta")
                # The tile's long axis descends along the actual roof slope.
                # A narrow mortar joint replaces overlapping coplanar tile rows.
                m.box((w/cols-.02,.075,hd/rows/math.cos(angle)-.018), (x+xx,yy,z+sign*zz), material, rot=(sign*angle,0,0), bevel=.014, variation=RNG.uniform(-.09,.08))
    for sign in (-1,1):
        m.box((w+.1,.20,.19),(x,eave-.035,z+sign*hd),"wood_dark",bevel=.02)
        m.beam((x+sign*hw,eave-.07,z-hd),(x+sign*hw,peak+.05,z),.19,"wood_dark")
        m.beam((x+sign*hw,peak+.05,z),(x+sign*hw,eave-.07,z+hd),.19,"wood_dark")
    for i in range(cols):
        m.cylinder(.13,w/cols-.025,(x-hw+(i+.5)*w/cols,peak+.04,z),"slate_light" if blue else "terracotta_light",sections=8,rot=(0,0,math.pi/2))


def battlements(m, x,z,w,d, y):
    m.box((w+.19,.22,d+.19),(x,y,z),"stone_light",bevel=.055)
    for sign in (-1,1):
        for xx in np.linspace(-w/2+.2,w/2-.2,max(3,round(w/.75))):
            m.box((.43,.60,.44),(x+xx,y+.34,z+sign*(d/2-.12)),"stone_light",bevel=.04)
        for zz in np.linspace(-d/2+.62,d/2-.62,max(2,round(d/.9))):
            m.box((.44,.60,.43),(x+sign*(w/2-.12),y+.34,z+zz),"stone_light",bevel=.04)


def square_tower(m,x,z,w=2.1,h=4.5,team=None):
    m.box((w+.28,.34,w+.28),(x,.17,z),"stone",bevel=.08)
    m.box((w,h-.28,w),(x,(h+.28)/2,z),"plaster",bevel=.09)
    for sy in (.45, .84):
        stone_rows(m,w+.03,.35,.14,(x,sy,z+w/2))
    for sign in (-1,1):
        for row in range(int(h/.58)):
            m.box((.30,.34,.30),(x+sign*(w/2-.1),.35+row*.58,z+w/2-.02),"stone_light",bevel=.028)
    window(m,x,h*.66,z+w/2+.035,.24,.84,False)
    battlements(m,x,z,w,w,h)
    if team:
        banner(m,x-.36,h+.35,z,team,.75)


def headquarters():
    m=Model()
    m.box((8.9,.28,7.7),(0,.14,0),"stone",bevel=.12)
    m.box((6.5,3.45,5.7),(0,1.99,-.25),"plaster",bevel=.06)
    stone_rows(m,6.5,.8,.20,(0,.28,2.64),rows=2)
    for sign in (-1,1):
        m.box((.26,3.35,5.76),(sign*3.20,2.03,-.25),"stone_light",bevel=.04)
        for zz in (-2.6,-1.1,.7,2.35):
            m.box((.28,3.4,.28),(sign*3.28,2.00,zz),"wood_dark",bevel=.015)
        for zz in (-1.80,.06):
            inset=Model()
            window(inset,0,2.33,0,.56,.89)
            m.absorb(inset,(sign*3.31,0,zz),sign*math.pi/2)
    arched_gate(m,1.7,2.55,.38,(0,.28,2.68))
    for sign in (-1,1):
        window(m,sign*2.08,2.63,2.68,.64,.99)
    tiled_roof(m,7.08,6.08,3.77,6.05,(0,-.25),True)
    for sign in (-1,1):
        # The corner turrets clear the main hall's sloping eaves. Keeping the
        # parapet above the roof avoids two surfaces cutting through each other.
        square_tower(m,sign*3.23,2.40,1.85,5.55,"blue" if sign<0 else None)
    m.box((2.2,.17,.8),(0,.36,3.50),"stone_light",bevel=.04)
    m.box((2.5,.13,.7),(0,.19,4.05),"stone",bevel=.04)
    m.box((2.7,.10,.45),(0,.075,4.50),"stone",bevel=.04)
    # Roof lantern with miniature roof, window and gilded finial.
    m.box((1.30,1.08,1.40),(0,5.94,-.3),"plaster",bevel=.035)
    window(m,0,6.0,.435,.46,.65,False)
    tiled_roof(m,1.70,1.83,6.47,7.32,(0,-.3),True)
    banner(m,.12,7.28,-.35,"blue",.65)
    for x in (-1.1,1.1):
        m.beam((x,1.6,2.83),(x,1.92,3.06),.075,"iron")
        m.box((.17,.26,.17),(x,1.97,3.08),"gold",bevel=.018)
    return m


def enemy_keep():
    m=Model()
    m.box((8.8,.31,7.6),(0,.155,0),"stone",bevel=.12)
    m.box((6.35,4.1,5.55),(0,2.34,-.2),"plaster",bevel=.06)
    stone_rows(m,6.4,1.15,.18,(0,.31,2.62),rows=3)
    battlements(m,0,-.2,6.45,5.65,4.44)
    arched_gate(m,2.03,3.03,.42,(0,.34,2.73),True)
    for x in (-2.30,2.30):
        window(m,x,2.95,2.70,.34,1.14,False)
    for sign in (-1,1):
        for zz in (-1.3,.72):
            inset=Model()
            window(inset,0,2.78,0,.29,1.01,False)
            m.absorb(inset,(sign*3.22,0,zz),sign*math.pi/2)
        for zz in (-1.30,.72):
            m.box((.33,1.18,.48),(sign*3.25,.88,zz),"stone",bevel=.045)
            m.box((.49,.18,.61),(sign*3.29,1.52,zz),"stone_light",bevel=.03)
    for x in (-3.13,3.13):
        for z in (-2.48,2.48):
            square_tower(m,x,z,1.85,5.18,"red" if z<0 else None)
    m.box((2.82,1.65,2.83),(0,5.28,-.72),"plaster",bevel=.065)
    window(m,0,5.6,.72,.63,1.13,False)
    tiled_roof(m,3.42,3.4,6.10,7.55,(0,-.72),False)
    banner(m,-.3,7.53,-.7,"red",.70)
    m.box((.85,1.95,.04),(-1.70,2.83,2.88),"red")
    m.box((.85,1.95,.04),(1.70,2.83,2.88),"red")
    for xx in (-1.7,1.7):
        m.box((.12,.82,.03),(xx,2.97,2.93),"gold")
        m.box((.57,.12,.03),(xx,3.10,2.94),"gold")
    return m


def house(barracks=False):
    m=Model()
    w,d=(5.8,4.6) if barracks else (4.9,4.2)
    h=2.95 if barracks else 3.18
    m.box((w+.30,.26,d+.30),(0,.13,0),"stone",bevel=.06)
    m.box((w,h-.06,d),(0,.26+(h-.06)/2,0),"plaster",bevel=.035)
    for z in (-d/2,d/2):
        stone_rows(m,w,.65,.16,(0,.26,z),rows=2)
        for x in np.linspace(-w/2+.1,w/2-.1,5):
            m.box((.16,h,.19),(x,.26+h/2,z),"wood_dark",bevel=.013)
        for yy in (1.07,h+.19):
            m.box((w+.08,.18,.19),(0,yy,z+math.copysign(.045,z)),"wood",bevel=.014)
        for x in (-w*.375,w*.375):
            brace_z=z+math.copysign(.035,z)
            m.beam((x-.42,1.20,brace_z),(x+.42,h+.02,brace_z),.105,"wood")
    for x in (-w/2,w/2):
        # Side rails stop inside the front rails, forming an actual butt joint
        # rather than two long boxes crossing with equal-height top surfaces.
        m.box((.19,.18,d-.16),(x+math.copysign(.045,x),1.07,0),"wood")
        m.box((.19,.18,d-.16),(x+math.copysign(.045,x),h+.18,0),"wood")
        for z in (-d/2+.10,0,d/2-.10):
            m.box((.19,h-.04,.16),(x,.26+(h-.04)/2,z),"wood_dark")
        for z in (-d*.26,d*.26):
            inset=Model()
            window(inset,0,2.06,0,.60,.84,False)
            m.absorb(inset,(x+math.copysign(.04,x),0,z),math.copysign(math.pi/2,x))
    arched_gate(m,1.18 if barracks else .90,2.12,.25,(0,.26,d/2+.07))
    for x in (-w*.31,w*.31):
        window(m,x,2.10,d/2+.04,.65,.89)
    tiled_roof(m,w+.66,d+.65,h+.31,h+2.05,(0,0),False)
    m.box((.60,1.51,.68),(-w*.3,h+1.59,-.55),"stone",bevel=.03)
    for y in (h+1.12,h+1.48,h+1.84,h+2.20):
        m.box((.64,.075,.72),(-w*.3,y,-.55),"stone_light",bevel=.015)
    m.box((.79,.20,.86),(-w*.3,h+2.40,-.55),"stone_light",bevel=.03)
    m.box((.48,.05,.55),(-w*.3,h+2.51,-.55),"dark")
    if barracks:
        banner(m,w*.40,h+.72,.3,"red",.8)
        for x in (-2.35,2.35):
            m.box((.75,.13,.52),(x,.32,d/2+.48),"wood_dark")
            for j in (-1,0,1):
                m.beam((x+j*.20,.35,d/2+.54),(x+j*.20,2.05,d/2+.35),.06,"wood_light")
                m.cone(.09,0,.33,(x+j*.20,2.16,d/2+.35),"iron_light",sections=4)
    return m


def tower():
    m=Model()
    square_tower(m,0,0,3.18,5.72,"red")
    arched_gate(m,.83,1.72,.24,(0,.13,1.63))
    for sign in (-1,1):
        m.box((.57,2.08,.85),(sign*1.60,1.09,.65),"stone",bevel=.06)
        m.box((.81,.20,1.02),(sign*1.60,2.18,.65),"stone_light",bevel=.03)
    m.box((2.63,.12,2.63),(0,5.815,0),"wood_dark")
    return m


def wall():
    m=Model()
    stone_rows(m,3.76,1.25,.53,rows=3)
    m.box((3.95,.21,.69),(0,1.34,0),"stone_light",bevel=.055)
    for x in (-1.9,1.9):
        stone_rows(m,.66,1.45,.67,(x,0,0),rows=3)
        m.box((.80,.21,.80),(x,1.55,0),"stone_light",bevel=.05)
    return m


def palisade():
    m=Model()
    for i in range(11):
        x=(i-5)*.34
        h=1.6+RNG.uniform(-.14,.14)
        m.cone(.17,.145,h,(x,h/2,0),"wood_light",sections=7)
        m.cone(.145,0,.34,(x,h+.17,0),"wood",sections=7)
        for yy in (.45,1.18):
            m.ring(.168,.185,.12,(x,yy+(i%2)*.035,0),"wood_dark",sections=7)
    for yy in (.45,1.18):
        m.box((3.91,.17,.20),(0,yy,.17),"wood",bevel=.015)
    return m


def barrel():
    m=Model()
    segments=14
    for i in range(segments):
        a1=i*math.tau/segments+.012
        a2=(i+1)*math.tau/segments-.012
        verts=[]
        for yy,rr in ((.035,.32),(.26,.40),(.66,.44),(1.02,.40),(1.23,.32)):
            verts += [[rr*math.cos(a1),yy,rr*math.sin(a1)],[rr*math.cos(a2),yy,rr*math.sin(a2)]]
        faces=[]
        for j in range(4):
            faces.extend([[j*2,j*2+1,j*2+3],[j*2,j*2+3,j*2+2]])
        m.add(tm.Trimesh(verts,[f[::-1] for f in faces],process=False),"wood_light",variation=RNG.uniform(-.12,.10))
    for yy,rr in ((.16,.379),(.37,.429),(.91,.429),(1.12,.379)):
        m.ring(rr-.04,rr+.014,.075,(0,yy,0),"iron",sections=14)
    m.cylinder(.323,.048,(0,1.232,0),"wood",sections=14)
    for xx in (-.16,0,.16):
        m.box((.010,.008,.54 if xx else .62),(xx,1.26,0),"wood_dark")
    m.cylinder(.065,.017,(.14,1.273,.06),"wood_light",sections=8)
    return m


def crate():
    m=Model()
    m.box((.94,.90,.94),(0,.45,0),"wood_dark")
    for i in range(5):
        q=(i-2)*.18
        for sign in (-1,1):
            m.box((.17,.84,.075),(q,.46,sign*.49),"wood_light",variation=RNG.uniform(-.10,.08))
            m.box((.075,.84,.17),(sign*.49,.46,q),"wood_light",variation=RNG.uniform(-.10,.08))
        m.box((.17,.065,.93),(q,.94,0),"wood_light",variation=RNG.uniform(-.10,.08))
    for sign in (-1,1):
        for yy in (.10,.83):
            m.box((1.10,.13,.09),(0,yy,sign*.545),"wood")
            m.box((.09,.13,.98),(sign*.545,yy,0),"wood")
        m.beam((-.43,.16,sign*.59),(.43,.77,sign*.59),.105,"wood")
        m.beam((sign*.59,.16,-.43),(sign*.59,.77,.43),.105,"wood")
    for xx in (-.44,.44):
        for zz in (-.59,.59):
            for yy in (.10,.84):
                m.cylinder(.021,.019,(xx,yy,zz),"iron",sections=6,rot=(math.pi/2,0,0))
    return m


def tree():
    m=Model()
    m.cone(.38,.19,2.75,(0,1.375,0),"wood",sections=7)
    for a in np.linspace(0,math.tau,5,endpoint=False):
        end=(math.cos(a)*.8,.11,math.sin(a)*.8)
        m.beam((0,.40,0),end,.19,"wood")
    for pos,scale in [((-.98,3.48,.12),(1.45,1.50,1.28)),((.86,3.92,-.2),(1.45,1.52,1.30)),((.08,4.90,.12),(1.51,1.53,1.27)),((.12,3.68,1.05),(1.22,1.17,1.2))]:
        m.beam((0,1.75,0),(pos[0]*.8,pos[1]-.48,pos[2]*.8),.19,"wood")
        ico=tm.creation.icosphere(subdivisions=1)
        ico.vertices *= RNG.uniform(.85,1.12,(len(ico.vertices),1))
        m.add(ico,"leaf" if pos[1]<4.5 else "leaf_light",pos,scale=scale,variation=RNG.uniform(-.05,.05))
    return m


def rock():
    m=Model()
    ico=tm.creation.icosphere(subdivisions=1)
    ico.vertices *= RNG.uniform(.77,1.2,(len(ico.vertices),1))
    ico.vertices[:,1]=np.maximum(ico.vertices[:,1],-.5)
    m.add(ico,"stone",(.0,.38,0),scale=(.86,.73,.68),variation=-.04)
    m.add(tm.creation.icosphere(subdivisions=0),"stone_light",(.64,.14,.30),scale=(.32,.25,.32),variation=-.06)
    return m


def fractured_boulder(m, center, scale, material="granite", seed=1):
    """A closed, irregular convex mass, with broad cut planes rather than spheres."""
    random=np.random.default_rng(seed)
    mesh=tm.creation.icosphere(subdivisions=1)
    mesh.vertices*=random.uniform(.80,1.15,(len(mesh.vertices),1))
    mesh.vertices[:,1]=np.maximum(mesh.vertices[:,1],-.43)
    mesh=tm.convex.convex_hull(mesh.vertices)
    return m.add(mesh,material,center,rot=(0,random.uniform(-.4,.4),.06),scale=scale)


def natural_rock(large=True):
    m=Model()
    factor=1.0 if large else .64
    fractured_boulder(m,(-.42*factor,.90*factor,.03*factor),np.array((1.55,2.02,1.22))*factor,"granite",619)
    fractured_boulder(m,(.98*factor,.52*factor,.31*factor),np.array((.99,1.14,.94))*factor,"granite_light",621)
    fractured_boulder(m,(-.76*factor,.27*factor,1.05*factor),np.array((.72,.64,.52))*factor,"granite",627)
    # Faceted lichen patches are tiny rock growths, with enough depth to avoid z-fighting.
    for x,y,z in [(-.80,1.92,.26),(.03,2.13,-.13),(.65,1.12,.83),(-1.16,.46,.91)]:
        m.add(tm.creation.icosphere(subdivisions=0),"leaf_light",(x*factor,y*factor,z*factor),scale=(.18*factor,.06*factor,.20*factor),variation=-.12)
    for j,(x,z) in enumerate([(-1.65,-.20),(1.61,.96),(.70,1.58),(-.42,-1.36)]):
        fractured_boulder(m,(x*factor,.105*factor,z*factor),np.array((.25,.23,.20))*factor,"granite_light",630+j)
    return m


def gold_vein():
    m=Model()
    core=fractured_boulder(m,(-.38,.57,.01),(1.27,1.43,1.09),"ore_rock",773)
    shoulder=fractured_boulder(m,(.93,.35,.28),(.88,.83,.94),"ore_rock_light",779)
    fractured_boulder(m,(-.77,.23,.88),(.83,.54,.66),"ore_rock",783)
    # Surface fault exposures follow the actual cut rock planes. Their shallow
    # solid extrusion stays outside the stone instead of disappearing inside it.
    for chunk in (core,shoulder):
        exposed=0
        for i,(triangle,normal) in enumerate(zip(chunk.triangles,chunk.face_normals)):
            center=np.mean(triangle,axis=0)
            if center[1]<.56 or normal[1]<.03 or max(normal[1],normal[2],normal[0])<.37 or i%3==0:
                continue
            barycentric=np.array([[.76,.19,.05],[.39,.56,.05],[.15,.70,.15],
                                  [.06,.37,.57],[.26,.10,.64],[.58,.08,.34]])
            contour=barycentric@np.roll(triangle,i%3,axis=0)
            scale=.83 if i%2 else .96
            top=center+(contour-center)*scale+normal*.014
            bottom=top-normal*.045
            m.add(tm.convex.convex_hull(np.concatenate((top,bottom))),"gold" if i%2 else "gold_dark")
            if exposed%3==0:
                crystal=tm.creation.icosphere(subdivisions=0)
                crystal.apply_scale((.15,.22,.12))
                m.add(crystal,"gold_light",tuple(center+normal*.13))
            exposed+=1
    # Angular golden ore grows through faults as connected volumetric seams.
    for start,end,width in [((-.94,1.17,.57),(-.48,1.50,.17),.10),
                            ((-.48,1.50,.17),(.11,1.59,-.15),.095),
                            ((.11,1.59,-.15),(.32,1.12,-.68),.12),
                            ((-.58,1.36,.60),(-.26,.80,1.06),.13),
                            ((.53,.97,.60),(1.21,.77,.62),.10),
                            ((1.21,.77,.62),(1.62,.30,.60),.095)]:
        m.beam(start,end,width,"gold",depth=width*1.5,bevel=.014)
    clusters=[(-.57,1.30,.54,.24),(-.16,1.54,.04,.21),(.58,.95,.42,.20),
              (1.26,.66,.62,.18),(-.78,.48,1.08,.22),(-1.15,.79,-.24,.17)]
    for i,(x,y,z,size) in enumerate(clusters):
        for j in range(3):
            m.cone(size*.65,0,size*1.7,(x+(j-1)*size*.55,y+(j%2)*size*.18,z+j*.06),
                   ["gold","gold_light","gold_dark"][(i+j)%3],sections=5,
                   rot=(.15-j*.15,i*.7,(j-1)*.24))
    for j,(x,z) in enumerate([(-1.60,.76),(1.70,-.10),(.99,1.45),(-.24,-1.35),(-1.35,-.88)]):
        fractured_boulder(m,(x,.12,z),(.24,.29,.25),"ore_rock_light",799+j)
        if j%2==0:
            m.add(tm.creation.icosphere(subdivisions=0),"gold",(x+.03,.23,z+.06),scale=(.10,.075,.07))
    return m


def oak_tree():
    m=Model()
    m.cone(.41,.20,3.5,(0,1.75,0),"bark",sections=9,rot=(0,0,-.035))
    for i,angle in enumerate(np.linspace(0,math.tau,6,endpoint=False)):
        direction=np.array((math.cos(angle),0,math.sin(angle)))
        m.beam(tuple(direction*.1+(0,.55,0)),tuple(direction*.98+(0,.05,0)),.22,"bark")
        m.beam(tuple(direction*.34+(0,.64,0)),tuple(direction*.21+(0,2.65+(i%2)*.22,0)),.065,"bark_light",bevel=.008)
    branches=[(-1.20,3.68,.25),(.99,4.02,-.33),(.32,4.74,.12),(-.24,3.74,1.37),(.03,3.83,-1.21)]
    for i,p in enumerate(branches):
        m.beam((0,2.06,0),p,.22 if i<2 else .16,"bark")
        for j,(offset,scale) in enumerate([((0,0,0),(1.32,1.23,1.20)),((.49,.43,-.26),(.82,.90,.87))]):
            random=np.random.default_rng(981+i*7+j)
            crown=tm.creation.icosphere(subdivisions=1)
            crown.vertices*=random.uniform(.88,1.10,(len(crown.vertices),1))
            m.add(crown,["leaf","leaf_light","leaf_dark"][(i+j)%3],tuple(np.array(p)+offset),scale=scale)
    # A healed branch knot and bark collar break the trunk silhouette.
    m.cone(.13,.06,.31,(.35,1.82,.04),"bark_light",sections=7,rot=(0,0,-1.15))
    return m


def pine_tree():
    m=Model()
    m.cone(.29,.105,5.50,(0,2.75,0),"bark",sections=8)
    for i,angle in enumerate(np.linspace(0,math.tau,5,endpoint=False)):
        m.beam((0,.45,0),(.70*math.cos(angle),.04,.70*math.sin(angle)),.14,"bark")
    # Overlapping asymmetric tiers have modeled twig tips and a legible pointed crown.
    for level,(y,radius,height) in enumerate([(1.87,1.75,1.72),(2.77,1.55,1.72),(3.60,1.20,1.62),(4.34,.92,1.42),(4.94,.58,1.25)]):
        m.cone(radius,.05,height,(0,y,0),"leaf_pine" if level%2==0 else "leaf_dark",sections=9,rot=(0,level*.53,0))
        for j in range(4):
            angle=j*math.pi/2+level*.67
            end=(math.cos(angle)*radius*.89,y-height*.34,math.sin(angle)*radius*.89)
            m.beam((0,y-height*.13,0),end,.050,"bark",bevel=.006)
            m.cone(radius*.30,0,height*.65,(end[0]*.78,y-height*.15,end[2]*.78),"leaf" if j%2 else "leaf_pine",sections=5,rot=(.10,angle,-.04))
    return m


def defense_tower():
    m=Model()
    # Same dressed warm stone as the keep, with a complete stone shell on all sides.
    square_tower(m,0,0,2.9,4.88)
    arched_gate(m,.72,1.49,.18,(0,.11,1.49))
    for sign in (-1,1):
        for side in (-1,1):
            m.box((.38,3.73,.38),(sign*1.35,2.05,side*1.35),"stone",bevel=.047)
        for row in range(7):
            y=.50+row*.56
            for x in (-1.33,1.33):
                m.box((.30,.32,.26),(x,y,sign*1.48),"stone_light",bevel=.023)
        # Arrow slit recesses and surrounds face the two open sides.
        m.box((.035,.80,.22),(sign*1.474,3.3,0),"dark",bevel=.013)
        for z in (-.22,.22):
            m.box((.11,.93,.16),(sign*1.52,3.3,z),"stone_light",bevel=.018)
    m.box((2.52,.14,2.52),(0,4.98,0),"wood_dark",bevel=.013)
    for i in range(9):
        m.box((.263,.08,2.42),(-1.14+i*.285,5.09,0),"wood_light",bevel=.008,variation=(i%3-1)*.06)
    # An unmanned heavy arbalest is built into the parapet, not a garrison slot.
    m.cylinder(.36,.45,(0,5.36,0),"wood",sections=12)
    m.ring(.35,.43,.11,(0,5.53,0),"iron",sections=12)
    m.box((.25,.24,1.74),(0,5.72,-.18),"wood",rot=(-.12,0,0),bevel=.024)
    m.box((.12,.06,1.48),(0,5.866,-.22),"wood_dark",rot=(-.12,0,0),bevel=.011)
    for sign in (-1,1):
        points=[(0,5.79,-.70),(sign*.52,5.79,-.68),(sign*.96,5.78,-.47),(sign*1.13,5.77,-.23)]
        for a,b in zip(points,points[1:]):m.beam(a,b,.085,"wood_light",depth=.14)
        m.beam(points[-1],(0,5.79,.17),.015,"burlap",depth=.015,bevel=.002)
        m.box((.12,.17,.22),(sign*.17,5.74,.39),"iron",bevel=.016)
    m.beam((0,5.91,.10),(0,5.91,-1.09),.027,"wood_light",depth=.027,bevel=.004)
    m.cone(.060,0,.20,(0,5.91,-1.17),"iron_light",sections=4,rot=(-math.pi/2,0,0))
    m.box((.17,.019,.18),(0,5.95,.04),"canvas",bevel=.003)
    for x in (-1.27,1.27):
        banner(m,x,4.60,0,"blue",.60)
    return m


def scaffolding():
    m=Model()
    # The construction footprint fits exactly inside the 4 x 4 build rectangle.
    for x in (-1.70,1.70):
        for z in (-1.70,1.70):
            m.box((.19,3.82,.19),(x,1.91,z),"wood",bevel=.020)
            m.box((.36,.15,.36),(x,.075,z),"wood_dark",bevel=.017)
            for y in (1.08,2.86):
                m.box((.21,.12,.23),(x,y,z),"burlap",bevel=.011)
    for side in (-1,1):
        for y in (1.03,2.81):
            m.beam((-1.77,y,side*1.70),(1.77,y,side*1.70),.17,"wood_light")
            m.beam((side*1.70,y,-1.77),(side*1.70,y,1.77),.17,"wood_light")
        m.beam((-1.65,.22,side*1.73),(1.65,2.76,side*1.73),.13,"wood")
        m.beam((side*1.73,.22,1.65),(side*1.73,2.76,-1.65),.13,"wood")
        for i in range(3):
            m.box((3.64,.10,.19),(0,2.97,side*(1.25+i*.22)),"wood_light",bevel=.013,variation=(i-1)*.06)
    # The low foundation and neatly piled timber make the site legible at 0%.
    for z in (-1.08,1.08):
        stone_rows(m,2.58,.49,.36,(0,.02,z),block=.65,rows=2)
    for x in (-1.20,1.20):
        m.box((.36,.49,1.92),(x,.26,0),"stone",bevel=.030)
    for i in range(5):
        m.box((.13,.11,1.49),(-.43+(i%3)*.18,.13+(i//3)*.12,-.02),"wood_light",rot=(0,.13,0),bevel=.012)
    # An integral ladder, iron fasteners, and a small blueprint workboard.
    for x in (-.35,.35):m.beam((x,.03,1.88),(x,3.12,1.17),.095,"wood")
    for i in range(9):
        y=.27+i*.32
        m.beam((-.35,y,1.88-y*.229),(.35,y,1.88-y*.229),.080,"wood_light")
    m.box((.64,.09,.46),(.79,.78,.23),"wood_dark",rot=(.30,0,0),bevel=.010)
    m.box((.49,.018,.35),(.79,.842,.22),"canvas",rot=(.30,0,0),bevel=.005)
    m.beam((.79,0,.36),(.79,.73,.23),.12,"wood")
    return m


def well():
    m=Model()
    for row in range(3):
        for i in range(12):
            a=(i+row*.5)*math.tau/12
            angles=(a-math.pi/12+.018,a+math.pi/12-.018)
            contour=Polygon([(radius*math.cos(theta),radius*math.sin(theta)) for radius,theta in [(.67,angles[0]),(.97,angles[0]),(.97,angles[1]),(.67,angles[1])]])
            outer=np.asarray(contour.exterior.coords)[:-1]
            inset=np.asarray(contour.buffer(-.022,join_style=2).exterior.coords)[:-1]
            bottom=.025+row*.32
            verts=[[x,bottom+yy,z] for yy,ring in [(.0,inset),(.022,outer),(.288,outer),(.31,inset)] for x,z in ring]
            m.add(tm.convex.convex_hull(np.asarray(verts)),"stone_light",variation=RNG.uniform(-.10,.04))
    m.cylinder(.63,.035,(0,.24,0),"water",sections=16)
    for x in (-1.04,1.04):
        m.box((.16,2.65,.17),(x,1.325,0),"wood",bevel=.015)
        m.beam((x,.94,0),(x,1.75,.64),.11,"wood")
    m.cylinder(.09,2.38,(0,1.98,0),"wood_light",sections=10,rot=(0,0,math.pi/2))
    for x in np.linspace(-.22,.22,9):
        m.ring(.092,.115,.034,(x,1.98,0),"wood_dark",sections=10,rot=(0,0,math.pi/2))
    m.cylinder(.020,1.03,(0,1.40,0),"wood_light",sections=6)
    m.cone(.13,.18,.24,(0,.94,0),"wood",sections=9)
    m.box((.08,.42,.08),(1.25,1.82,0),"iron")
    m.cylinder(.065,.24,(1.34,1.62,0),"wood",sections=8,rot=(0,0,math.pi/2))
    tiled_roof(m,2.74,1.84,2.65,3.26,(0,0),False)
    return m


def cart():
    m=Model()
    for xx in (-.76,.76):
        m.box((.16,.24,2.47),(xx,.65,0),"wood_dark",bevel=.02)
    for i in range(8):
        m.box((1.65,.10,.27),(0,.84,(i-3.5)*.28),"wood_light",bevel=.008,variation=RNG.uniform(-.05,.08))
    for xx in (-.85,.85):
        for zz in (-1.06,0,1.06):
            m.box((.15,.85,.10),(xx,1.18,zz),"wood",bevel=.012)
        for yy in (1.01,1.29,1.56):
            m.box((.09,.19,2.24),(xx,yy,0),"wood_light",bevel=.008)
    for zz in (-1.12,1.12):
        for yy in (1.01,1.29,1.56):
            m.box((1.57,.19,.09),(0,yy,zz),"wood_light",bevel=.008)
    for zz in (-.77,.77):
        m.cylinder(.09,2.20,(0,.58,zz),"iron",sections=8,rot=(0,0,math.pi/2))
        for xx in (-1.06,1.06):
            m.ring(.43,.58,.16,(xx,.58,zz),"wood",sections=14,rot=(0,0,math.pi/2))
            m.ring(.575,.61,.14,(xx,.58,zz),"iron",sections=14,rot=(0,0,math.pi/2))
            m.cylinder(.145,.24,(xx,.58,zz),"wood_light",sections=10,rot=(0,0,math.pi/2))
            for a in np.linspace(0,math.tau,8,endpoint=False):
                m.beam((xx,.58+math.sin(a)*.13,zz+math.cos(a)*.13),(xx,.58+math.sin(a)*.49,zz+math.cos(a)*.49),.065,"wood_light")
    for xx in (-.62,.62):
        m.beam((xx,.71,1.07),(xx,.55,3.10),.13,"wood")
    return m


def tent():
    m=Model()
    half_w,half_d,peak=1.42,1.70,2.28
    m.box((2.84,.045,3.40),(0,.023,0),"wood_dark")
    for side in (-1,1):
        for band in range(7):
            z0=-half_d+band*(2*half_d/7)
            z1=z0+2*half_d/7-.014
            verts=[[0,peak,z0],[side*half_w,.085,z0],[0,peak,z1],[side*half_w,.085,z1]]
            mesh=tm.Trimesh(verts,[[0,1,3],[0,3,2]],process=False)
            mat="blue" if band in (1,5) else "canvas"
            m.add(mesh,mat)
        for z in np.linspace(-half_d,half_d,8):
            # Stop the seam short of the ridge so the two seam end caps do not
            # occupy the same plane at the tent's peak.
            m.beam((side*.028,peak-.010,z),(side*half_w,.085,z),.025,"burlap")
    # Open front flaps and a closed canvas back retain the tent's hollow shape.
    back=tm.Trimesh([[-half_w,.05,-half_d],[0,peak,-half_d],[half_w,.05,-half_d]],[[0,1,2]],process=False)
    m.add(back,"canvas")
    for side in (-1,1):
        verts=[[0,peak,half_d],[side*half_w,.07,half_d],[side*.79,.06,half_d+.04],[side*.39,1.40,half_d+.04]]
        m.add(tm.Trimesh(verts,[[0,1,2],[0,2,3]],process=False),"canvas")
        m.beam((side*.82,.16,half_d+.06),(side*.35,1.48,half_d+.06),.067,"burlap")
    for z in (-half_d-.04,half_d+.04):
        m.cylinder(.055,2.46,(0,1.23,z),"wood",sections=8)
        m.cone(.083,0,.16,(0,2.53,z),"gold",sections=6)
        m.beam((0,2.36,z),(0,.08,z+math.copysign(.86,z)),.026,"burlap")
        m.box((.06,.23,.07),(0,.09,z+math.copysign(.86,z)),"wood_dark",rot=(.2,0,0))
    for side in (-1,1):
        for z in (-1.24,1.24):
            m.beam((side*1.15,.46,z),(side*1.95,.07,z+.10),.023,"burlap")
            m.box((.055,.19,.055),(side*1.95,.09,z+.10),"wood_dark",rot=(0,0,side*.25))
    return m


def sacks():
    m=Model()
    for index,(x,z,s) in enumerate([(-.32,-.10,1),(.35,.205,.78),(-.12,.47,.61)]):
        verts=[]
        rings=[(0,.23),(.18,.37),(.50,.40),(.77,.33),(.91,.14),(1.03,.16)]
        sides=12
        for y,radius in rings:
            for j in range(sides):
                a=j*math.tau/sides
                verts.append([x+math.cos(a)*radius*s,y*s,z+math.sin(a)*radius*s])
        faces=[]
        for row in range(len(rings)-1):
            for j in range(sides):
                a=row*sides+j;b=row*sides+(j+1)%sides;c=b+sides;d=a+sides
                faces.extend([[a,b,c],[a,c,d]])
        faces += [[0,j+1,j] for j in range(1,sides-1)]
        last=(len(rings)-1)*sides
        faces += [[last,last+j,last+j+1] for j in range(1,sides-1)]
        body=tm.Trimesh(verts,faces,process=False)
        body.fix_normals()
        m.add(body,"burlap",variation=index*.035)
        m.ring(.135*s,.16*s,.035*s,(x,.905*s,z),"wood_dark",sections=12)
        m.beam((x+.15*s,.90*s,z),(x+.25*s,.72*s,z+.08*s),.018,"wood_light")
        for j in range(5):
            yy=(.23+j*.10)*s
            m.box((.014*s,.06*s,.013*s),(x-.26*s,yy,z+.25*s),"canvas",rot=(0,0,.17))
    return m


def hay_bale():
    m=Model()
    m.box((1.72,.81,.93),(0,.405,0),"straw",bevel=.12)
    for i in range(9):
        zz=-.39+i*.095
        m.box((1.65,.012,.012),(0,.831,zz),"straw_light",variation=(i%4)*.025)
    for i in range(7):
        yy=.11+i*.098
        for sign in (-1,1):
            m.box((1.64,.014,.012),(0,yy,sign*.489),"straw_light",variation=(i%4)*.025)
    for xx in (-.47,.47):
        m.box((.052,.025,1.0),(xx,.870,0),"wood_dark",bevel=.005)
        for sign in (-1,1):
            m.box((.052,.78,.025),(xx,.417,sign*.516),"wood_dark",bevel=.005)
    return m


def campfire():
    m=Model()
    m.cylinder(.60,.025,(0,.014,0),"dark",sections=14)
    for i in range(11):
        a=i*math.tau/11
        m.box((.28,.17,.22),(.69*math.cos(a),.09,.69*math.sin(a)),"stone",rot=(0,-a,0),bevel=.05,variation=(i%3)*.025)
    for row,angle in enumerate((-.55,.63,-.20,.91)):
        m.box((.14,.14,1.10),(0,.12+row*.07,0),"wood_dark",rot=(0,angle,0),bevel=.02)
        m.box((.15,.11,.05),(.4*math.sin(angle),.13+row*.07,.4*math.cos(angle)),"wood",rot=(0,angle,0))
    for a in (0,math.tau/3,math.tau*2/3):
        m.beam((math.cos(a)*.67,.04,math.sin(a)*.67),(0,1.48,0),.063,"wood")
    m.cylinder(.018,.40,(0,1.13,0),"iron",sections=6)
    m.cone(.17,.24,.23,(0,.84,0),"iron",sections=10)
    m.ring(.222,.249,.03,(0,.96,0),"iron_light",sections=12)
    return m


def broken_wheel():
    m=Model()
    for i in range(11):
        a0=(i+1)*math.tau/14+.008
        a1=(i+2)*math.tau/14-.008
        for inner,outer,mat in ((.42,.545,"wood"),(.550,.574,"iron")):
            verts=[[math.cos(a)*r,y,math.sin(a)*r] for y in (.055,.18) for r in (inner,outer) for a in (a0,a1)]
            m.add(tm.convex.convex_hull(np.asarray(verts)),mat)
    for a in (1.05,1.85,2.65,3.45,4.25,5.05):
        m.beam((.13*math.cos(a),.12,.13*math.sin(a)),(.47*math.cos(a),.12,.47*math.sin(a)),.055,"wood_light")
    m.cylinder(.13,.20,(0,.11,0),"wood_light",sections=9)
    m.cylinder(.045,.22,(0,.12,0),"iron",sections=8)
    return m


def broken_shield():
    m=Model()
    contour=[(-.43,.51),(.43,.51),(.44,.02),(.20,-.45),(0,-.65),(-.20,-.42),(-.18,-.03),(-.42,.09)]
    mesh=extruded_contour(contour,.085,0)
    m.add(mesh,"wood",(0,.08,0),rot=(-math.pi/2,0,0))
    for x in (-.27,0,.25):
        m.box((.025,.012,.63),(x,.13,-.08),"wood_dark")
    m.box((.22,.014,.77),(.06,.14,-.05),"red")
    m.cylinder(.14,.09,(0,.18,0),"iron",sections=10)
    m.box((.84,.06,.07),(0,.11,-.52),"iron")
    m.beam((.43,.11,-.47),(.43,.11,.02),.055,"iron")
    m.beam((.40,.11,.07),(.19,.11,.43),.055,"iron")
    return m


def ruin():
    m=Model()
    m.box((6.16,.17,4.70),(0,.085,0),"stone",bevel=.04)
    stone_rows(m,5.80,.65,.45,(0,.17,-2.04),rows=2)
    poly=[(-2.90,.77),(-2.90,3.65),(-2.08,3.57),(-1.89,3.05),(-1.20,2.80),(-.84,1.70),(.07,1.26),(.92,.77)]
    for shift in (-2.04,):
        mesh=extruded_contour(poly,.46,shift)
        m.add(mesh,"plaster")
    m.box((.50,2.57,2.96),(-2.70,1.46,-.38),"plaster",bevel=.04)
    for row in range(5):
        m.box((.66,.33,.40),(-2.74,.48+row*.47,1.10),"stone_light",bevel=.035)
    arched_gate(m,1.17,2.1,.31,(-.48,.17,2.04))
    m.box((1.23,1.18,.47),(-2.09,.76,2.04),"plaster",bevel=.04)
    m.box((1.14,.69,.47),(2.22,.52,2.04),"plaster",bevel=.05)
    # Broken roof members remain visibly supported on surviving wall stumps.
    m.beam((-2.67,2.87,-1.92),(-1.20,.28,1.48),.20,"wood_dark")
    m.beam((-2.75,3.52,-2.03),(.64,1.01,-1.81),.21,"wood")
    m.beam((-.84,.22,1.16),(1.71,.21,.04),.17,"wood_dark")
    for i in range(31):
        x,z=RNG.uniform(-2.6,2.6),RNG.uniform(-1.70,1.76)
        ico=tm.creation.icosphere(subdivisions=0)
        scale=RNG.uniform(.13,.46,3)
        m.add(ico,"stone_light" if i%3 else "plaster",(x,scale[1]*.55+.1,z),rot=tuple(RNG.uniform(-.8,.8,3)),scale=scale)
    return m


def tuft(m,x,z,scale=1.0):
    for i in range(4):
        a=RNG.uniform(0,math.tau)
        w=RNG.uniform(.035,.07)*scale
        h=RNG.uniform(.18,.43)*scale
        lean=RNG.uniform(.07,.20)*scale
        verts=[[x-w*math.cos(a),.025,z-w*math.sin(a)],[x+w*math.cos(a),.025,z+w*math.sin(a)],[x+lean*math.cos(a),h,z+lean*math.sin(a)]]
        m.add(tm.Trimesh(verts,[[0,1,2]],process=False),"grass" if i%2 else "grass_light",variation=RNG.uniform(-.11,.05))


BUILDINGS = [(-22,23,9,8),(22,-24,9,8),(9,-21,6,5),(25,-7,4,4),(-4,-12,6,5)]
RESOURCE_VEINS = [(-31,17),(-9,27),(-17,2),(9,3),(31,-19)]


def reserved(x,z,margin=1.0):
    return any(abs(x-bx)<w/2+margin and abs(z-bz)<d/2+margin for bx,bz,w,d in BUILDINGS) or any((x-mx)**2+(z-mz)**2<(2.2+margin)**2 for mx,mz in RESOURCE_VEINS)


def horizontal_surface(model, polygon, height, material, variation=0.0):
    """Triangulate a disjoint, possibly holed ground region once, facing up."""
    if polygon.is_empty:
        return
    triangles=constrained_delaunay_triangles(polygon)
    vertices=[]
    faces=[]
    for triangle in triangles.geoms:
        coords=np.asarray(triangle.exterior.coords)[:3]
        start=len(vertices)
        vertices.extend([[x,height,z] for x,z in coords])
        face=[start,start+1,start+2]
        a,b,c=np.asarray(vertices[-3:])
        if np.cross(b-a,c-a)[1]<0:
            face.reverse()
        faces.append(face)
    model.add(tm.Trimesh(vertices,faces,process=False),material,variation=variation)


def terrain():
    m=Model()
    # The substrate ends below the lowest earth vertex. Previously its top
    # crossed the jittered earth triangles at y=-0.03.
    m.box((84,.72,84),(0,-.435,0),"earth",bevel=.12)
    # A jittered paved-earth field; face color variations stay broad and quiet.
    step=2.0
    grid=[]
    count=43
    for iz in range(count):
        for ix in range(count):
            x=-42+ix*step
            z=-42+iz*step
            if ix not in (0,count-1):x+=RNG.uniform(-.50,.50)
            if iz not in (0,count-1):z+=RNG.uniform(-.50,.50)
            RNG.uniform(-.006,.006)  # Retain the established deterministic layout.
            grid.append((x,-.03,z))
    faces=[]
    colors=[]
    for iz in range(count-1):
        for ix in range(count-1):
            a=iz*count+ix;b=a+1;c=a+count;d=c+1
            for f in ([a,c,b],[b,c,d]):
                faces.append(f)
                x,_,z=np.mean([grid[q] for q in f],axis=0)
                dist=abs(x+.65*z)/1.19
                road=math.exp(-(dist/5.9)**4)
                field = .5 + .29*math.sin(x*.17)*math.sin(z*.14) + .21*math.sin(x*.10+z*.18)
                earth_mix = max(0,min(.52,field*.54)) * (1-road)
                soil=np.asarray(C["sand"])*(1-earth_mix)+np.asarray(C["earth"])*earth_mix
                base=soil*(1-road*.9)+np.asarray(C["road"])*road*.9
                variation=RNG.uniform(-.044,.034)+.017*math.sin(x*.22+z*.13)
                colors.append(color(base,variation))
    # Broad, irregular ochre earth islands establish the same stepped color
    # hierarchy as the reference village, without a noisy texture overlay.
    soil_islands=[]
    for i in range(96):
        cx,cz=RNG.uniform(-40,40,2)
        if reserved(cx,cz,.7) or abs(cx+.65*cz)<6.3:
            continue
        w,d=RNG.uniform(1.7,4.9,2)
        points=[(-w*.50,-d*.25),(-w*.31,-d*.25),(-w*.31,-d*.50),(w*.21,-d*.50),(w*.21,-d*.33),(w*.50,-d*.33),(w*.50,d*.21),(w*.24,d*.21),(w*.24,d*.50),(-w*.34,d*.50),(-w*.34,d*.28),(-w*.50,d*.28)]
        shade = tuple(np.asarray(C["sand"])*RNG.uniform(.83,.96))
        soil_islands.append((Polygon([(cx+x,cz+z) for x,z in points]),shade))
    # A continuous, laid stone road, aligned to its travel direction. Dark mortar
    # stays between the staggered courses; no separate bright paper-like tiles.
    angle=-math.atan(.65)
    ca,sa=math.cos(angle),math.sin(angle)
    def road_point(cross,along):
        return cross*ca+along*sa, -cross*sa+along*ca
    road_bed=Polygon([road_point(c,t) for c,t in [(-3.11,-47),(3.11,-47),(3.11,47),(-3.11,47)]])
    # The apron and avenue are one shared mortar surface. Earth islands are
    # clipped into disjoint regions, retaining their original palette/contours.
    paved_bed=road_bed
    horizontal_surface(m,paved_bed,-.012,"road_mortar")
    claimed=paved_bed
    for polygon,shade in reversed(soil_islands):
        horizontal_surface(m,polygon.difference(claimed),-.03,shade)
        claimed=claimed.union(polygon)
    # Soil color islands belong to the earth itself. Cut the base triangles
    # around them so there is exactly one surface at y=-0.03, without floating
    # color plates or their unwanted contact shadows.
    for face,rgba in zip(faces,colors):
        polygon=Polygon([(grid[index][0],grid[index][2]) for index in face])
        horizontal_surface(m,polygon.difference(claimed),-.03,tuple(rgba[:3]))
    for row in range(96):
        along=-47+(row+.5)*.978
        offset=(row%2)*.5
        divisions=[-3.04]+[-3.04+(col+offset)*.76 for col in range(10) if -3.039 < -3.04+(col+offset)*.76 < 3.039]+[3.04]
        for left,right in zip(divisions,divisions[1:]):
            cross=(left+right)/2
            x,z=road_point(cross,along)
            if reserved(x,z,.15):continue
            worn=RNG.random() < (.12 if abs(cross)>2.3 else .018)
            mat="road" if worn else "paving"
            width=right-left-.047
            m.box((width,.050,.927),(x,-.009,z),mat,rot=(0,angle+RNG.uniform(-.009,.009),0),bevel=.020,variation=RNG.uniform(-.065,.065))
    # Low sand banks settle onto earth at their outer edge and onto the stone
    # tops at their inner edge. This avoids a floating sheet and its dark rim.
    for side in (-1,1):
        for along in np.arange(-43,45,4.8):
            reach=RNG.uniform(.45,1.13)
            coords=[(side*(3.14-reach),along-.83),(side*3.97,along-1.71),(side*4.30,along+.71),(side*(3.10-reach*.42),along+1.29)]
            middle=np.mean(coords,axis=0)
            mx,mz=road_point(*middle)
            verts=[[mx,.047,mz]]+[[road_point(c,t)[0],.016 if abs(c)<3.11 else -.03,road_point(c,t)[1]] for c,t in coords]
            faces=[]
            for i in range(4):
                face=[0,i+1,(i+1)%4+1]
                a,b,c=np.asarray([verts[index] for index in face])
                if np.cross(b-a,c-a)[1]<0:face.reverse()
                faces.append(face)
            m.add(tm.Trimesh(verts,faces,process=False),"road",variation=RNG.uniform(-.075,-.025))
    return m


def build_environment(models):
    decor=Model()
    obstacles=[]
    instances=[]
    def obstacle(label,x,z,w,h,d,angle=0,resource=False):
        ca,sa=abs(math.cos(angle)),abs(math.sin(angle))
        item={"name":label,"position":[x,h/2,z],"size":[w,h,d],"rotation_y":angle,
              "aabb_min":[x-(w*ca+d*sa)/2,0,z-(w*sa+d*ca)/2],
              "aabb_max":[x+(w*ca+d*sa)/2,h,z+(w*sa+d*ca)/2]}
        if resource:item["resource"]=True
        obstacles.append(item)
    def place(name,x,z,angle=0,scale=1,label=None):
        label=label or f"{name.title().replace('_','')}{len(instances):02d}"
        instances.append((name,label,x,z,angle,scale))
        # Trunks block movement; canopies do not consume their whole ground projection.
        dims={"rock_large":(4.05,3.1,3.60),"rock_medium":(2.60,2.0,2.31),
              "tree_oak":(.92,3.0,.92),"tree_pine":(.70,3.0,.70)}
        w,h,d=dims[name]
        obstacle(label,x,z,w*scale,h*scale,d*scale,angle)
    # Small composed natural groups replace every former decorative house, ruin,
    # wall, cart, well and supply tent. The diagonal army road stays continuous.
    for item in [
        ("rock_large",-29,5,.24,1.05),("rock_medium",-31.1,2.8,-.30,.94),
        ("rock_large",-27,-7,-.17,.90),("rock_medium",-29.2,-8.5,.60,.85),
        ("rock_large",16,15,-.43,.95),("rock_medium",18.5,15.1,.19,.85),
        ("rock_large",28,23,.10,1.00),("rock_medium",30.3,24.4,.51,.88),
        ("rock_large",-20,-25,.38,1.08),("rock_medium",-22.5,-23.5,-.31,.90),
        ("rock_large",31,-32,-.18,.95),("rock_medium",33.0,-33.0,.58,.90),
        ("rock_medium",-13,33,.19,.95),("rock_medium",13,-1,.64,.88)]:
        place(*item)
    for item in [
        ("tree_oak",-32,9,.3,.98),("tree_pine",-33,4,.8,.92),
        ("tree_pine",-31,-5,.5,1.05),("tree_oak",-27,-13,.9,.92),
        ("tree_oak",20,19,.4,.92),("tree_pine",23,21,.7,1.02),
        ("tree_pine",30,28,.2,1.05),("tree_oak",25,28,.9,.97),
        ("tree_oak",-16,-25,.3,.91),("tree_pine",-18,-29,.8,1.03),
        ("tree_pine",27,-34,.1,1.05),("tree_oak",33,-28,.6,.90),
        ("tree_oak",-17,34,.1,.91),("tree_pine",-20,33,.8,.88)]:
        place(*item)
    # Baked boundary groves share only a few material surfaces, while saved
    # native trunk colliders stay individually editable and enter offline navigation.
    for i in range(48):
        side=i%4
        along=-37+(i//4)*6.8+RNG.uniform(-1.1,1.1)
        across=RNG.uniform(37.2,40.2)
        x,z=((along,across),(-across,along),(along,-across),(across,along))[side]
        if reserved(x,z,1.8) or abs(x+.65*z)/1.19<5.3:continue
        size=RNG.uniform(.78,1.13)
        name="tree_oak" if i%3==0 else "tree_pine"
        decor.absorb(models[name],(x,0,z),RNG.uniform(0,math.tau),(size,size,size))
        width=(.92 if name=="tree_oak" else .70)*size
        obstacle(f"BoundaryTree{i}",x,z,width,3.0*size,width)
    # Small ground stones are below a footstep, visually grounding obstacle bases.
    for name,label,cx,cz,angle,scale in instances:
        for j in range(4 if name.startswith("rock") else 2):
            a=RNG.uniform(0,math.tau)
            r=RNG.uniform(1.3,2.2) if name.startswith("rock") else RNG.uniform(.9,1.4)
            x,z=cx+math.cos(a)*r,cz+math.sin(a)*r
            if reserved(x,z,1.4):continue
            size=RNG.uniform(.11,.22)
            decor.absorb(models["rock_medium"],(x,0,z),a,(size,size*.65,size))
    for i in range(870):
        x,z=RNG.uniform(-41,41,2)
        if reserved(x,z,1.7) or abs(x+.65*z)<7.4:continue
        tuft(decor,x,z,RNG.uniform(.65,1.27))
    # ResourceVein scenes in main own both mine visuals and physics. These entries
    # are exclusively their permanent offline navigation/build-placement footprint.
    for i,(x,z) in enumerate(RESOURCE_VEINS):
        obstacle(f"GoldVein{i+1}",x,z,4.4,2.2,4.4,resource=True)
    decor.save("world_details",False)
    solids=[item for item in obstacles if not item.get("resource",False)]
    names=sorted({name for name,*_ in instances})
    lines=['[gd_scene load_steps=%d format=3]'%(4+len(names)+len(solids)),
           '[ext_resource type="PackedScene" path="res://assets/models/environment/terrain.glb" id="1_terrain"]',
           '[ext_resource type="PackedScene" path="res://assets/models/environment/world_details.glb" id="2_details"]']
    ids={}
    for i,name in enumerate(names):
        ids[name]=f"{i+3}_{name}"
        lines.append(f'[ext_resource type="PackedScene" path="res://assets/models/environment/{name}.tscn" id="{ids[name]}"]')
    lines+=['[sub_resource type="BoxShape3D" id="FloorShape"]\nsize = Vector3(84, 1, 84)']
    for i,item in enumerate(solids):
        w,h,d=item["size"]
        lines.append(f'[sub_resource type="BoxShape3D" id="ObstacleShape{i}"]\nsize = Vector3({w:.4f}, {h:.4f}, {d:.4f})')
    lines += ['[node name="Environment" type="Node3D"]',
              '[node name="EarthAndAncientRoad" parent="." instance=ExtResource("1_terrain")]',
              '[node name="GroundCoverAndBoundaryGrove" parent="." instance=ExtResource("2_details")]',
              '[node name="Ground" type="StaticBody3D" parent="."]\ncollision_layer = 1\ncollision_mask = 0',
              '[node name="CollisionShape3D" type="CollisionShape3D" parent="Ground"]\nposition = Vector3(0, -0.53, 0)\nshape = SubResource("FloorShape")',
              '[node name="NaturalObstacles" type="Node3D" parent="."]']
    for name,label,x,z,angle,scale in instances:
        lines.append(f'[node name="{label}" parent="NaturalObstacles" instance=ExtResource("{ids[name]}")]\nposition = Vector3({x},0,{z})\nrotation = Vector3(0,{angle:.6f},0)\nscale = Vector3({scale},{scale},{scale})')
    # Keep distant obstacles in separate broad-phase bodies. Moving each saved
    # transform onto the body leaves its one primitive shape untransformed.
    lines += ['[node name="SolidEnvironment" type="Node3D" parent="."]']
    for i,item in enumerate(solids):
        x,y,z=item["position"]
        lines.append(f'[node name="{item["name"]}" type="StaticBody3D" parent="SolidEnvironment"]\nposition = Vector3({x:.4f},{y:.4f},{z:.4f})\nrotation = Vector3(0,{item["rotation_y"]:.6f},0)\ncollision_layer = 1\ncollision_mask = 0')
        lines.append(f'[node name="CollisionShape3D" type="CollisionShape3D" parent="SolidEnvironment/{item["name"]}"]\nshape = SubResource("ObstacleShape{i}")')
    write_asset(SCENES/"environment.tscn","\n\n".join(lines)+"\n")
    write_asset(ROOT/"assets/environment_obstacles.json",json.dumps({"version":2,"bounds":[-42,-42,42,42],
                "resource_veins":[{"name":f"GoldVein{i+1}","position":[x,0,z],"radius":2.2} for i,(x,z) in enumerate(RESOURCE_VEINS)],
                "obstacles":obstacles},indent=2))


def main():
    global RNG
    RNG=np.random.default_rng(932710)
    models={"headquarters":headquarters(),"enemy_keep":enemy_keep(),"barracks":house(True),"tower":tower(),"house":house(),"ruin":ruin(),"wall":wall(),"palisade":palisade(),"barrel":barrel(),"crate":crate(),"tree":tree(),"rock":rock(),"well":well(),"cart":cart(),"tent":tent(),"sacks":sacks(),"hay_bale":hay_bale(),"campfire":campfire(),"broken_wheel":broken_wheel(),"broken_shield":broken_shield()}
    # Existing military sculpture seeds remain untouched by the new natural set.
    models.update({"gold_vein":gold_vein(),"rock_large":natural_rock(),"rock_medium":natural_rock(False),
                   "tree_oak":oak_tree(),"tree_pine":pine_tree(),"defense_tower":defense_tower(),"scaffolding":scaffolding()})
    manifest={name:model.save(name) for name,model in models.items()}
    # Independent random streams keep later terrain edits from moving houses,
    # trees, navigation blockers or functional prop clusters.
    RNG=np.random.default_rng(932711)
    manifest["terrain"]=terrain().save("terrain",False)
    RNG=np.random.default_rng(932712)
    build_environment(models)
    write_asset(OUT/"model_manifest.json",json.dumps(manifest,indent=2))


if __name__=="__main__":
    main()
