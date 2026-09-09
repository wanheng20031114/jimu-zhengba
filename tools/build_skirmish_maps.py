"""Author the skirmish buildings and native, editable Godot battlefields.

Run this offline, then run tests/skirmish_maps_bake.gd once with Godot. Geometry
is saved as native ArrayMesh resources; no meshes or navigation are built in a
match. New maps can be authored independently with --maps ID --skip-models;
their seeded obstacle layouts obey the map's two, three or eightfold symmetry.
"""
from __future__ import annotations

import json
import argparse
import math
from collections import deque
from pathlib import Path

import numpy as np
import trimesh as tm
from shapely.geometry import LineString, MultiPoint, Point, Polygon, box
from shapely.ops import unary_union

import build_environment as art

ROOT = Path(__file__).resolve().parents[1]
MAPS = ROOT / "scenes/maps"
LOCAL = ROOT / ".local/skirmish_authoring"
MODEL_DIR = ROOT / "assets/models/environment"
RNG = np.random.default_rng(461904)
MANIFEST: list[dict] = []


def shield(m, x, y, z, size=.68):
    contour = [(-.46,.46),(.46,.46),(.42,-.15),(0,-.62),(-.42,-.15)]
    for factor, depth, material in [(1,.08,"gold"),(.84,.105,"blue")]:
        points=[(x+xx*size*factor,y+yy*size*factor) for xx,yy in contour]
        mesh=art.extruded_contour(points,.07,z+depth)
        m.add(mesh,material)
    m.box((.09*size,.67*size,.035),(x,y,z+.16),"gold")
    m.box((.53*size,.09*size,.035),(x,y+.06*size,z+.17),"gold")


def wall_standard(m, x, y, z, width=1.0, height=1.6, angle=0):
    """Broad actual cloth mesh, attached clear of masonry on each visible side."""
    cloth=art.Model()
    contour=[(-width/2,height/2),(width/2,height/2),(width/2,-height/2),
             (0,-height*.38),(-width/2,-height/2)]
    cloth.add(art.extruded_contour(contour,.045,0),"blue")
    cloth.box((width+.16,.085,.085),(0,height/2+.03,0),"gold",bevel=.01)
    cloth.box((.075,height*.47,.025),(0,.04,.044),"gold")
    cloth.box((width*.49,.075,.025),(0,.12,.045),"gold")
    m.absorb(cloth,(x,y,z),angle)


def sword(m, start, end, width=.10):
    a,b=np.array(start),np.array(end)
    direction=(b-a)/np.linalg.norm(b-a)
    m.beam(a,b,width,"iron_light",depth=.045)
    grip=a-direction*.31
    m.beam(grip,a,.085,"wood_dark")
    cross=np.cross(direction,(0,0,1))*.20
    m.beam(a+cross,a-cross,.075,"gold")
    m.add(tm.creation.icosphere(subdivisions=0),"gold",grip,scale=(.075,.075,.06))
    # A faceted point, rather than an abruptly cut rectangular blade.
    tip=b+direction*.22
    vertices=[b+cross*.27,b-cross*.27,b+np.array((0,0,.026)),tip]
    m.add(tm.convex.convex_hull(np.array(vertices)),"iron_light")


def shell(m,w,d,h,center=(0,0)):
    x,z=center
    m.box((w+.30,.26,d+.30),(x,.13,z),"stone",bevel=.075)
    m.box((w,h-.28,d),(x,(h+.28)/2,z),"plaster",bevel=.045)
    for sign in (-1,1):
        art.stone_rows(m,w,.72,.14,(x,.26,z+sign*d/2),rows=2)
        m.box((w+.13,.15,.19),(x,h-.06,z+sign*(d/2+.025)),"wood_dark",bevel=.018)
        for xx in (-w/2+.08,w/2-.08):
            for row in range(5):
                m.box((.31,.36,.23),(x+xx,.50+row*.57,z+sign*d/2),"stone_light",bevel=.028)
    for sign in (-1,1):
        m.box((.19,.15,d-.14),(x+sign*(w/2+.025),h-.06,z),"wood_dark",bevel=.018)


def factory():
    m=art.Model()
    shell(m,5.05,4.55,3.14,(-.12,-.34))
    art.arched_gate(m,1.55,2.48,.33,(-1.15,.26,1.99))
    # Low workshop roof and tall square chimney distinguish the industrial silhouette.
    art.tiled_roof(m,5.65,5.08,3.27,4.03,(-.12,-.34),False)
    # Thick dressed-stone chimney with an actual open black mouth and coping.
    m.box((.91,5.12,.94),(1.71,2.82,-1.16),"stone",bevel=.065)
    for row in range(11):
        yy=.58+row*.46
        for sign in (-1,1):
            m.box((.99,.075,.095),(1.71,yy,-1.16+sign*.47),"stone_light",bevel=.016)
            m.box((.095,.075,.81),(1.71+sign*.47,yy,-1.16),"stone_light",bevel=.016)
    for sign in (-1,1):
        m.box((1.17,.26,.20),(1.71,5.49,-1.16+sign*.50),"stone_light",bevel=.045)
        m.box((.20,.26,.80),(1.71+sign*.48,5.49,-1.16),"stone_light",bevel=.035)
    m.box((.66,.055,.64),(1.71,5.392,-1.16),"dark")
    # Open forge bay: separate jambs, deep dark hearth and tapered stone hood.
    m.box((1.52,.25,1.17),(1.47,.385,2.11),"stone",bevel=.045)
    m.box((1.23,1.13,.12),(1.47,1.07,2.04),"dark")
    for sign in (-1,1):
        m.box((.25,1.28,.67),(1.47+sign*.67,1.13,2.25),"stone_light",bevel=.03)
    hood=art.extruded_contour([(.69,1.78),(2.25,1.78),(1.96,2.65),(.99,2.65)],.77,2.19)
    m.add(hood,"stone")
    m.box((1.60,.13,.86),(1.47,1.77,2.20),"iron",bevel=.025)
    for x,z,r in [(1.10,2.16,.14),(1.38,2.24,.13),(1.64,2.16,.17),(1.80,2.29,.11)]:
        m.add(tm.creation.icosphere(subdivisions=0),(188,85,31),(x,.59,z),scale=(r,r*.6,r))
    for x in np.arange(.95,2.02,.18):
        m.box((.065,.04,.53),(x,.66,2.24),"iron")
    # Anvil has a tapered horn, waist and splayed foot on a banded stump.
    m.cylinder(.31,.51,(.28,.50,2.33),"wood",sections=10)
    for y in (.30,.68):m.ring(.29,.33,.07,(.28,y,2.33),"iron",sections=10)
    m.box((.58,.10,.34),(.28,.80,2.33),"iron",bevel=.025)
    m.box((.24,.23,.22),(.28,.96,2.33),"iron",bevel=.03)
    m.box((.67,.13,.35),(.29,1.12,2.33),"iron_light",bevel=.024)
    m.cone(.15,0,.42,(.78,1.13,2.33),"iron_light",sections=6,rot=(0,0,-math.pi/2))
    # Stock wheel, spokes, hub and iron rim are modeled rather than painted.
    wheel=art.Model()
    wheel.ring(.57,.67,.16,(0,0,0),"wood_light",sections=14,rot=(math.pi/2,0,0))
    wheel.ring(.655,.70,.19,(0,0,0),"iron",sections=14,rot=(math.pi/2,0,0))
    for angle in np.linspace(0,math.tau,8,endpoint=False):
        wheel.beam((0,0,0),(.61*math.cos(angle),.61*math.sin(angle),0),.09,"wood")
    wheel.cylinder(.16,.23,(0,0,0),"iron",sections=10,rot=(math.pi/2,0,0))
    m.absorb(wheel,(-2.18,.79,2.20),-.15)
    for i in range(6):
        m.add(tm.creation.icosphere(subdivisions=1),"iron",(-.45+(i%3)*.24,.39+(i//3)*.20,2.35-(i//3)*.12),scale=(.13,.13,.13))
    shield(m,-1.11,2.70,2.04,.42)
    # Side bays remain readable from either isometric camera diagonal.
    for sign in (-1,1):
        for z in (-1.47,.40):
            side=art.Model(); art.window(side,0,1.97,0,.66,.82,False)
            m.absorb(side,(-.12+sign*2.56,0,z),sign*math.pi/2)
        m.beam((-.12+sign*2.55,.91,-1.75),(-.12+sign*2.55,2.90,-.54),.13,"wood_dark")
    art.banner(m,-2.09,4.34,-.20,"blue",.67)
    for sign in (-1,1):
        wall_standard(m,-.12+sign*2.58,1.98,-.54,1.15,1.50,sign*math.pi/2)
    return m


def academy():
    m=art.Model()
    shell(m,5.12,4.60,3.58,(0,-.20))
    art.tiled_roof(m,5.72,5.13,3.70,5.13,(0,-.20),True)
    art.arched_gate(m,1.22,2.47,.31,(0,.26,2.13))
    for i,(w,z,y) in enumerate([(1.98,2.44,.27),(2.30,2.73,.14)]):
        m.box((w,.14,.42),(0,y,z),"stone_light",bevel=.027)
    # Two round columns support a sculpted entrance pediment.
    for x in (-1.03,1.03):
        m.box((.49,.15,.48),(x,.38,2.31),"stone_light",bevel=.026)
        m.cylinder(.16,2.34,(x,1.61,2.31),"stone_light",sections=10)
        for yy,r,h in [(.53,.22,.15),(2.73,.23,.16),(2.84,.27,.12)]:
            m.cylinder(r,h,(x,yy,2.31),"stone",sections=10)
    m.box((2.65,.16,.55),(0,2.97,2.27),"stone_light",bevel=.035)
    pediment=art.extruded_contour([(-1.43,3.04),(1.43,3.04),(0,3.62)],.42,2.25)
    m.add(pediment,"stone_light")
    # An open book crest: separately beveled leaves and a golden central spine.
    for sign in (-1,1):
        m.box((.39,.32,.055),(sign*.21,3.24,2.49),"canvas",rot=(0,sign*.18,sign*.12),bevel=.024)
        m.box((.43,.36,.045),(sign*.21,3.24,2.455),"gold",rot=(0,sign*.18,sign*.12),bevel=.02)
        for row in range(3):
            m.box((.24,.015,.025),(sign*.22,3.17+row*.055,2.53),"wood_light",rot=(0,0,sign*.12))
    m.box((.045,.36,.06),(0,3.24,2.55),"gold")
    for sign in (-1,1):
        art.window(m,sign*1.99,2.22,2.12,.57,1.15,False)
        for z in (-1.65,.15):
            side=art.Model();art.window(side,0,2.28,0,.61,1.19,False)
            m.absorb(side,(sign*2.59,0,z),sign*math.pi/2)
        m.box((.30,2.51,.48),(sign*2.60,1.52,-1.66),"stone",bevel=.043)
    # A compact octagonal scholar's lantern and blue pointed cupola.
    m.cylinder(.87,1.45,(0,5.12,-.46),"plaster",sections=8)
    for a in np.linspace(0,math.tau,8,endpoint=False):
        x,z=.80*math.sin(a),-.46+.80*math.cos(a)
        inset=art.Model();art.window(inset,0,5.26,0,.25,.64,False)
        m.absorb(inset,(x,0,z),a)
    for yy,r in [(4.55,.96),(5.81,.97)]:m.cylinder(r,.14,(0,yy,-.46),"stone_light",sections=8)
    m.cone(1.16,.12,1.25,(0,6.47,-.46),"slate",sections=8)
    for a in np.linspace(0,math.tau,8,endpoint=False):
        m.beam((1.14*math.sin(a),5.88,-.46+1.14*math.cos(a)),(.11*math.sin(a),7.07,-.46+.11*math.cos(a)),.045,"slate_light")
    m.cone(.11,0,.29,(0,7.19,-.46),"gold",sections=6)
    m.ring(.14,.18,.045,(0,7.41,-.46),"gold",sections=12,rot=(math.pi/2,0,0))
    art.banner(m,-2.06,3.56,1.17,"blue",.72)
    for sign in (-1,1):
        wall_standard(m,sign*1.62,1.95,2.155,.80,1.48)
        wall_standard(m,sign*2.62,2.02,-.65,1.02,1.65,sign*math.pi/2)
    # A side reading desk and tightly stacked books supply near-camera detail.
    m.box((.61,.10,.46),(2.28,.96,2.38),"wood_light",bevel=.014)
    for yy,w,mat in [(1.06,.42,"blue"),(1.16,.48,"wood"),(1.25,.38,"gold")]:
        m.box((w,.08,.29),(2.28,yy,2.38),mat,rot=(0,.12,0),bevel=.012)
    for x in (2.04,2.50):m.beam((x,.28,2.38),(x,.92,2.38),.08,"wood_dark")
    return m


def player_barracks():
    m=art.Model()
    shell(m,5.22,4.48,3.10,(0,-.32))
    # A fortified flat training hall, unlike the pitched HQ or academy dome.
    m.box((5.34,.20,4.63),(0,3.22,-.32),"stone_light",bevel=.04)
    m.box((4.88,.07,4.18),(0,3.36,-.32),"wood_dark")
    art.battlements(m,0,-.32,5.32,4.60,3.39)
    art.arched_gate(m,1.40,2.28,.34,(0,.26,1.99))
    for sign in (-1,1):
        art.window(m,sign*1.89,2.03,1.99,.53,.84,False)
        m.box((.21,2.74,.21),(sign*1.13,1.70,1.96),"wood_dark",bevel=.014)
        side=art.Model();art.window(side,0,2.06,0,.53,.89,False)
        m.absorb(side,(sign*2.63,0,-.31),sign*math.pi/2)
        m.beam((sign*2.64,1.10,-1.98),(sign*2.64,2.89,-.91),.13,"wood")
        # Training spears stand in a rack, not in inaccessible decorative walls.
        x=sign*2.03
        for z in (2.20,2.57):m.box((.88,.13,.10),(x,.62,z),"wood_dark")
        for offset in (-.27,0,.27):
            m.beam((x+offset,.30,2.56),(x+offset,2.12,2.26),.052,"wood_light")
            m.cone(.087,0,.29,(x+offset,2.26,2.24),"iron_light",sections=4,rot=(-.16,0,0))
        shield(m,x,.99,2.60,.48)
    sword(m,(-.49,2.78,2.16),(.53,3.53,2.16),.09)
    sword(m,(.49,2.78,2.22),(-.53,3.53,2.22),.09)
    shield(m,0,3.20,2.27,.59)
    # Rear watch lantern gives the barracks a military silhouette of its own.
    m.cylinder(.65,1.31,(-1.58,4.27,-1.30),"stone",sections=8)
    for a in (0,math.pi/2,math.pi,math.pi*1.5):
        slit=art.Model();art.window(slit,0,4.38,0,.17,.47,False)
        m.absorb(slit,(-1.58+.61*math.sin(a),0,-1.30+.61*math.cos(a)),a)
    m.cylinder(.75,.14,(-1.58,4.97,-1.30),"stone_light",sections=8)
    art.battlements(m,-1.58,-1.30,1.38,1.38,5.00)
    art.banner(m,1.89,3.84,-.72,"blue",.71)
    for sign in (-1,1):
        wall_standard(m,sign*2.67,2.13,.63,1.18,1.62,sign*math.pi/2)
        wall_standard(m,sign*1.77,2.06,1.97,.84,1.30)
    m.box((1.74,.16,.56),(0,.30,2.38),"stone_light",bevel=.03)
    return m


def player_defense_tower():
    m=art.defense_tower()
    for sign in (-1,1):
        wall_standard(m,sign*1.62,3.13,0,1.14,1.75,sign*math.pi/2)
    wall_standard(m,0,3.30,1.66,.90,1.30)
    return m


def native_model(model, destination: str, limit: float | None = None, shadow=True):
    """Stage deterministic authoring arrays, consumed only by the offline baker."""
    bounds=np.array([np.inf*np.ones(3),-np.inf*np.ones(3)])
    for meshes in model.parts.values():
        for mesh in meshes:
            bounds[0]=np.minimum(bounds[0],mesh.bounds[0]);bounds[1]=np.maximum(bounds[1],mesh.bounds[1])
    factor=1.0 if limit is None else min(1.0,limit/max(bounds[1,0]-bounds[0,0],bounds[1,2]-bounds[0,2]))
    center=(bounds[0]+bounds[1])*.5
    parts=[]
    for family,meshes in model.parts.items():
        if destination.startswith("res://assets/models/environment/"):
            meshes=[mesh.copy() for mesh in meshes]
            for mesh in meshes:
                colors=mesh.visual.vertex_colors.copy()
                colors[:,3]=255 if mesh.metadata.get("heraldry",False) else 0
                mesh.visual.vertex_colors=colors
        merged=tm.util.concatenate(meshes)
        if limit is not None:
            merged.vertices[:,0]=(merged.vertices[:,0]-center[0])*factor
            merged.vertices[:,2]=(merged.vertices[:,2]-center[2])*factor
            merged.vertices[:,1]=np.maximum(merged.vertices[:,1]-bounds[0,1],0)
        triangles=np.round(merged.triangles,8)
        order=np.lexsort((triangles[:,:,2],triangles[:,:,1],triangles[:,:,0]),axis=1)
        canonical=np.take_along_axis(triangles,order[:,:,None],axis=1)
        _,unique=np.unique(canonical.reshape((-1,9)),axis=0,return_index=True)
        merged.update_faces(np.sort(unique));merged.update_faces(merged.nondegenerate_faces(height=1e-7))
        merged.unmerge_vertices()
        srgb=merged.visual.vertex_colors[:,:3].astype(float)/255
        linear=np.where(srgb<=.04045,srgb/12.92,((srgb+.055)/1.055)**2.4)
        rgba=np.concatenate((linear,merged.visual.vertex_colors[:,3:4].astype(float)/255),axis=1)
        parts.append({"name":family,"vertices":np.round(merged.vertices,6).reshape(-1).tolist(),
                      "normals":np.round(merged.vertex_normals,6).reshape(-1).tolist(),
                      "colors":np.round(rgba,6).reshape(-1).tolist(),"indices":merged.faces.reshape(-1).tolist()})
    name=Path(destination).stem
    payload={"destination":destination,"shadow":shadow,"parts":parts,
             "building":destination.startswith("res://assets/models/environment/"),
             "max_height":float(bounds[1,1]-bounds[0,1])}
    staged=LOCAL/f"{name}.json"
    art.write_asset(staged,json.dumps(payload,separators=(",",":")))
    MANIFEST.append({"source":str(staged),"destination":destination})
    tris=sum(len(p["indices"])//3 for p in parts)
    print(f"{name}: {tris:,} triangles, {len(parts)} native material meshes")
    return {"triangles":tris,"meshes":len(parts)}


MAP_DEFINITIONS=[
    {"id":"amber_crossroads_1v1","title":"琥珀十字路","size":[96,96],"spawns":[[-32,32,0],[32,-32,1]],
     "starting_towers":[[-26,10],[26,-10]],
     "mines":[[-32,16],[-16,32],[-10,-8],[32,-16],[16,-32],[10,8]],
     "roads":[{"width":12,"points":[[-32,32],[0,0],[32,-32]]},
              {"width":8,"points":[[-32,32],[-42,16],[-40,-20],[-8,-42],[16,-42],[32,-32]]},
              {"width":8,"points":[[32,-32],[42,-16],[40,20],[8,42],[-16,42],[-32,32]]}]},
    {"id":"twin_valleys_2v2","title":"双谷盟约","size":[128,112],
     "spawns":[[-44,30,0],[-44,-2,0],[44,-30,1],[44,2,1]],
     "starting_towers":[[-52,7],[-52,-25],[52,-7],[52,25]],
     "mines":[[-53,15],[-53,-17],[53,-15],[53,17],[-26,12],[-22,-21],[26,-12],[22,21],[-4,28],[4,-28]],
     "roads":[{"width":12,"points":[[-44,30],[0,16],[44,2]]},
              {"width":12,"points":[[-44,-2],[0,-16],[44,-30]]},
              {"width":8,"points":[[0,-16],[0,16]]},
              {"width":8,"points":[[-44,-2],[-20,-42],[20,-42],[44,-30]]},
              {"width":8,"points":[[44,2],[20,42],[-20,42],[-44,30]]},
              {"width":8,"points":[[-44,30],[-44,-2]]},
              {"width":8,"points":[[44,-30],[44,2]]}]},
]


def rotate_point(point, angle):
    """Godot's positive Y rotation in the X/Z authoring plane."""
    x,z=point
    return [round(x*math.cos(angle)+z*math.sin(angle),6),
            round(-x*math.sin(angle)+z*math.cos(angle),6)]


def large_match_definitions():
    front={"id":"three_frontiers_3v3","title":"三线烽火","size":[160,144],
           "symmetry":2,"seed":80303,
           "spawns":[[-58,-40,0],[-58,0,0],[-58,40,0],[58,40,1],[58,0,1],[58,-40,1]],
           "starting_towers":[[-66,-61],[-66,-21],[-66,19],[66,61],[66,21],[66,-19]],
           "mines":[[-60,-55],[-60,-15],[-60,25],[60,55],[60,15],[60,-25],
                    [-26,-60],[-26,-20],[-26,20],[26,60],[26,20],[26,-20],[-10,-20],[10,20]],
           "roads":[{"width":12,"points":[[-58,z],[58,z]]} for z in (-40,0,40)] +
                   [{"width":8,"points":[[x,-40],[x,40]]} for x in (-44,0,44)]}
    four_front={"id":"four_banners_4v4","title":"四旗会战","size":[192,184],
                "symmetry":2,"seed":90404,
                "spawns":[[-70,z,0] for z in (-60,-20,20,60)] +
                         [[70,z,1] for z in (60,20,-20,-60)],
                "starting_towers":[[-82,z-22] for z in (-60,-20,20,60)] +
                                  [[82,z+22] for z in (60,20,-20,-60)],
                "mines":[[-77,z-15] for z in (-60,-20,20,60)] +
                        [[77,z+15] for z in (60,20,-20,-60)] +
                        [[-40,z-15] for z in (-60,-20,20,60)] +
                        [[40,z+15] for z in (60,20,-20,-60)] +
                        [[-16,-40],[16,40],[-16,40],[16,-40]],
                "roads":[{"width":12,"points":[[-70,z],[70,z]]} for z in (-60,-20,20,60)] +
                        [{"width":8,"points":[[x,-60],[x,60]]} for x in (-56,0,56)]}
    radial=[]
    for name,title,size,radius,teams,symmetry,seed in [
        ("triad_basin_2v2v2","三盟盆地",176,66,[0,0,1,1,2,2],3,80222),
        ("crownfall_ffa","落冠荒原",192,72,list(range(8)),8,90801),
    ]:
        spawns=[];birth_mines=[];towers=[];expansions=[];roads=[]
        # Clockwise consecutive owners make the adjacent two seats one team.
        seats=len(teams)
        angle_step=math.tau/seats
        angles=[math.pi-angle_step/2-i*angle_step for i in range(seats)]
        for owner,angle in enumerate(angles):
            outward=np.array([math.cos(angle),math.sin(angle)])
            front_dir=-outward;left=np.array([front_dir[1],-front_dir[0]])
            spawn=outward*radius
            birth=spawn+outward*5+left*14
            tower=birth+left*8
            expansion=outward*(40 if seats==8 else 34)+left*13
            spawns.append([*np.round(spawn,6).tolist(),teams[owner]])
            birth_mines.append(np.round(birth,6).tolist())
            towers.append(np.round(tower,6).tolist())
            expansions.append(np.round(expansion,6).tolist())
            roads.append({"width":12,"points":[np.round(spawn,6).tolist(),[0,0]]})
        # The ring connects adjacent lanes; reserves a second tactical route
        # without crossing the inward expansion mines on either side.
        ring_radius=60 if seats==8 else 56
        ring=[[round(math.cos(a)*ring_radius,6),round(math.sin(a)*ring_radius,6)] for a in angles]
        roads.extend({"width":8,"points":[ring[i],ring[(i+1)%seats]]} for i in range(seats))
        # Three evenly spaced contested veins lie between radial main lanes.
        contested=[[round(math.cos(math.radians(120-i*120))*22,6),
                    round(math.sin(math.radians(120-i*120))*22,6)] for i in range(3)]
        if seats==8:
            contested=[[round(math.cos(a-angle_step/2)*28,6),
                        round(math.sin(a-angle_step/2)*28,6)] for a in angles]
        radial.append({"id":name,"title":title,"size":[size,size],"symmetry":symmetry,"seed":seed,
                       "spawns":spawns,"starting_towers":towers,"mines":birth_mines+expansions+contested,
                       "mine_rotations":[i*angle_step for i in range(seats)]*2+
                                        [i*math.tau/len(contested) for i in range(len(contested))],"roads":roads})
    return [front,four_front,*radial]


MAP_DEFINITIONS.extend(large_match_definitions())


def road_union(definition,padding=0):
    return unary_union([LineString(r["points"]).buffer(r["width"]/2+padding,cap_style=1,join_style=1) for r in definition["roads"]])


def terrain(definition):
    m=art.Model();w,d=definition["size"]
    field=box(-w/2,-d/2,w/2,d/2)
    roads=road_union(definition).intersection(field)
    m.box((w,.66,d),(0,-.385,0),"earth",bevel=.10)
    # Every ground patch occupies its own polygon. There are no coincident
    # horizontal layers, nor floating colored decals casting contact shadows.
    for z in np.arange(-d/2,d/2,3):
        for x in np.arange(-w/2,w/2,3):
            xx=min(x+3,w/2);zz=min(z+3,d/2)
            for corners in [[(x,z),(x,zz),(xx,z)],[(xx,z),(x,zz),(xx,zz)]]:
                cx,cz=np.mean(corners,axis=0)
                broad=.5+.27*math.sin(abs(cx)*.15)*math.sin(abs(cz)*.12)+.20*math.cos((cx-cz)*.09)
                shade=np.array(art.C["sand"])*(1-broad*.28)+np.array(art.C["earth"])*broad*.28
                art.horizontal_surface(m,Polygon(corners).difference(roads),-.03,tuple(shade),RNG.uniform(-.045,.035))
    art.horizontal_surface(m,roads,-.028,"road",-.02)
    # A restrained narrow paved spine makes travel directions immediately
    # readable while the full 12/8 m shoulders remain available to formations.
    claimed=Polygon()
    for road in definition["roads"]:
        for start,end in zip(road["points"],road["points"][1:]):
            a,b=np.array(start,dtype=float),np.array(end,dtype=float)
            along=(b-a)/np.linalg.norm(b-a);cross=np.array((along[1],-along[0]))
            length=np.linalg.norm(b-a)
            for row in range(math.floor(length/.96)):
                for col in range(4):
                    distance=(row+.5)*.96;across=(col-1.5)*.72+(row%2-.5)*.05
                    center=a+along*distance+cross*across
                    tile=Polygon([center+cross*xc+along*zc for xc,zc in [(-.338,-.448),(.338,-.448),(.338,.448),(-.338,.448)]])
                    if not roads.covers(tile) or claimed.intersects(tile):continue
                    if any(Point(center).distance(Point(s[:2]))<5.6 for s in definition["spawns"]):continue
                    # Flat low paving tops share no plane with their base road.
                    art.horizontal_surface(m,tile,.001,"paving",RNG.uniform(-.06,.055))
            claimed=claimed.union(LineString([start,end]).buffer(1.6,cap_style=2))
    return m


def collision_geometry(kind,model):
    """Use the real three main rock solids; small pebbles and foliage do not block units."""
    if kind.startswith("rock") or kind == "gold_vein":
        vertices=np.concatenate([mesh.vertices for mesh in model.parts["Stone"][:3]])
        vertices[:,1]=np.maximum(vertices[:,1],0)
        hull=tm.convex.convex_hull(vertices)
        points=np.round(hull.vertices,6)
        footprint=list(MultiPoint(points[:,[0,2]]).convex_hull.exterior.coords)[:-1]
        return {"type":"convex","points":points.tolist(),"footprint":footprint}
    radius=.41 if kind=="tree_oak" else .29
    height=3.5 if kind=="tree_oak" else 5.5
    # Match the native circular trunk, never the overhead canopy or decorative roots.
    footprint=[(radius*math.cos(a),radius*math.sin(a)) for a in np.linspace(0,math.tau,20,endpoint=False)]
    return {"type":"cylinder","radius":radius,"height":height,"footprint":footprint}


def scaled_collision(collision,scale):
    result={"type":collision["type"],"footprint":(np.asarray(collision["footprint"])*scale).round(6).tolist()}
    if collision["type"]=="convex":
        result["points"]=(np.asarray(collision["points"])*scale).round(6).tolist()
    else:
        result.update(radius=collision["radius"]*scale,height=collision["height"]*scale)
    return result


def natural_layout(definition):
    w,d=definition["size"]
    safe_roads=road_union(definition,1.35)
    bases=[Point(s[:2]).buffer(11.5) for s in definition["spawns"]]
    mines=[Point(p).buffer(5.1) for p in definition["mines"]]
    towers=[box(x-3.15,z-3.15,x+3.15,z+3.15) for x,z in definition["starting_towers"]]
    reserved=unary_union([safe_roads,*bases,*mines,*towers])
    models={"rock_large":art.natural_rock(True),"rock_medium":art.natural_rock(False),"tree_oak":art.oak_tree(),"tree_pine":art.pine_tree()}
    collisions={kind:collision_geometry(kind,model) for kind,model in models.items()}
    placements=[]; occupied=[]
    def attempt(x,z,kind,scale,angle):
        width,depth,height={"rock_large":(4.05,3.60,3.1),"rock_medium":(2.60,2.31,2.0),"tree_oak":(.92,.92,3.0),"tree_pine":(.70,.70,3.0)}[kind]
        radius=math.hypot(width,depth)*scale/2
        # Keep foliage outside development/mining clearances as well as trunks.
        visual=max(radius,2.5*scale if kind=="tree_oak" else 1.85*scale if kind=="tree_pine" else radius)
        symmetry=definition.get("symmetry",2)
        orbit=[]
        for index in range(symmetry):
            turn=math.tau*index/symmetry
            px,pz=rotate_point((x,z),turn)
            shape=Point(px,pz).buffer(visual)
            if abs(px)+visual>w/2-.65 or abs(pz)+visual>d/2-.65:return False
            if reserved.intersects(shape) or any(shape.distance(p)<.35 for p in occupied):return False
            if any(shape.distance(p[3])<.35 for p in orbit):return False
            orbit.append((px,pz,turn,shape))
        for px,pz,turn,shape in orbit:
            placements.append({"name":f"{kind}_{len(placements):03d}","model":kind,"position":[px,0,pz],
                               "rotation_y":angle+turn,"scale":scale,
                               "size":[width*scale,height*scale,depth*scale],
                               "collision":scaled_collision(collisions[kind],scale)})
            occupied.append(shape)
        return True
    # Art-directed clusters around road islands, then a denser boundary frame.
    candidates=[]
    for z in np.arange(-d/2+4,d/2-3,5.1):
        for x in np.arange(-w/2+4,-1,5.1):
            boundary=abs(x)>w/2-10 or abs(z)>d/2-10
            if not boundary and RNG.random()>.51:continue
            candidates.append((x+RNG.uniform(-1,1),z+RNG.uniform(-1,1),boundary))
    for index,(x,z,boundary) in enumerate(candidates):
        kind=("tree_oak" if index%3==0 else "tree_pine") if boundary or index%4 else ("rock_large" if index%8==0 else "rock_medium")
        attempt(x,z,kind,RNG.uniform(.80,1.04),RNG.uniform(0,math.tau))
    # Smaller boulder groups occupy the remaining reserved-free interior gaps.
    for i in range(105):
        x,z=RNG.uniform(-w/2+6,-2),RNG.uniform(-d/2+6,d/2-6)
        attempt(x,z,"rock_medium",RNG.uniform(.62,.91),RNG.uniform(0,math.tau))
    decor=art.Model()
    for item in placements:
        x,_,z=item["position"];s=item["scale"]
        decor.absorb(models[item["model"]],(x,0,z),item["rotation_y"],(s,s,s))
        # Small stones and grass root the obstacle in the warm ground plane.
        local=np.random.default_rng(int(abs(x*700+z*270)))
        for j in range(3):
            a=local.uniform(0,math.tau);r=local.uniform(.9,1.35)
            art.tuft(decor,x+math.cos(a)*r,z+math.sin(a)*r,local.uniform(.7,1.2))
    return decor,placements


def navigation(definition,obstacles):
    w,d=definition["size"]
    solid=[]
    for item in obstacles:
        x,_,z=item["position"];a=item["rotation_y"]
        points=[]
        for dx,dz in item["collision"]["footprint"]:
            points.append((x+dx*math.cos(a)+dz*math.sin(a),z-dx*math.sin(a)+dz*math.cos(a)))
        solid.append(Polygon(points).buffer(1.15,join_style=1))
    ore=collision_geometry("gold_vein",art.gold_vein())
    for index,(x,z) in enumerate(definition["mines"]):
        angle=definition["mine_rotations"][index] if "mine_rotations" in definition else (0 if x<0 else math.pi)
        points=[rotate_point(p,angle) for p in ore["footprint"]]
        solid.append(Polygon([(x+px,z+pz) for px,pz in points]).buffer(1.15))
    blocked=unary_union(solid)
    vertices=[];lookup={};polygons=[];walkable=set()
    # One polygon per integer cell is the source contract of dynamic building
    # carving. Reusing exact corner vertices also ensures native edge adjacency.
    for z in range(-d//2+2,d//2-2):
        for x in range(-w//2+2,w//2-2):
            if blocked.contains(Point(x+.5,z+.5)):continue
            walkable.add((x,z))
    # Tiny pockets between inflated rocks are not valid destination islands.
    # Keep the shared battlefield component, never disconnected navigable dots.
    start=tuple(math.floor(v) for v in definition["spawns"][0][:2]);reachable={start};pending=deque([start])
    assert start in walkable
    while pending:
        x,z=pending.popleft()
        for neighbor in [(x-1,z),(x+1,z),(x,z-1),(x,z+1)]:
            if neighbor in walkable and neighbor not in reachable:
                reachable.add(neighbor);pending.append(neighbor)
    for x,z,_ in definition["spawns"]:assert (math.floor(x),math.floor(z)) in reachable,"Spawn disconnected"
    for z in range(-d//2+2,d//2-2):
        for x in range(-w//2+2,w//2-2):
            if (x,z) not in reachable:continue
            indices=[]
            for corner in [(x,z),(x,z+1),(x+1,z+1),(x+1,z)]:
                if corner not in lookup:
                    lookup[corner]=len(vertices);vertices.append([corner[0],0,corner[1]])
                indices.append(lookup[corner])
            polygons.append(indices)
    return {"vertices":vertices,"polygons":polygons}


def write_map(definition,obstacles,nav):
    name=definition["id"];w,d=definition["size"]
    nav_path=MAPS/f"{name}_navigation.tres"
    flat=", ".join(str(v) for p in nav["vertices"] for v in p)
    polys=", ".join("PackedInt32Array("+", ".join(map(str,p))+")" for p in nav["polygons"])
    art.write_asset(nav_path,'[gd_resource type="NavigationMesh" format=3]\n\n[resource]\nvertices = PackedVector3Array('+flat+')\npolygons = Array[PackedInt32Array](['+polys+'])\nagent_radius = 1.15\nagent_height = 2.4\ncell_size = 1.0\ncell_height = 0.2\n')
    ext=[f'[ext_resource type="NavigationMesh" path="res://scenes/maps/{name}_navigation.tres" id="1_nav"]',
         f'[ext_resource type="PackedScene" path="res://scenes/maps/{name}_ground.tscn" id="2_ground"]',
         f'[ext_resource type="PackedScene" path="res://scenes/maps/{name}_nature.tscn" id="3_nature"]',
         '[ext_resource type="PackedScene" path="res://scenes/resource_vein.tscn" id="4_mine"]']
    lines=['[gd_scene load_steps='+str(6+len(obstacles))+' format=3]',*ext,
           f'[sub_resource type="BoxShape3D" id="Floor"]\nsize = Vector3({w},1,{d})']
    for i,item in enumerate(obstacles):
        collision=item["collision"]
        if collision["type"]=="convex":
            points=", ".join(f"{value:.6f}" for point in collision["points"] for value in point)
            lines.append(f'[sub_resource type="ConvexPolygonShape3D" id="Shape{i}"]\npoints = PackedVector3Array({points})\nmargin = 0.01')
        else:
            lines.append(f'[sub_resource type="CylinderShape3D" id="Shape{i}"]\nradius = {collision["radius"]:.6f}\nheight = {collision["height"]:.6f}\nmargin = 0.01')
    lines.extend([f'[node name="{name.title().replace("_", "")}" type="Node3D"]\nmetadata/map_id = "{name}"\nmetadata/map_size = Vector2({w},{d})\nmetadata/map_title = "{definition["title"]}"',
                  '[node name="NavigationRegion3D" type="NavigationRegion3D" parent="."]\nnavigation_mesh = ExtResource("1_nav")\nuse_edge_connections = false',
                  '[node name="Environment" type="Node3D" parent="."]',
                  '[node name="GroundVisual" parent="Environment" instance=ExtResource("2_ground")]',
                  '[node name="NaturalScenery" parent="Environment" instance=ExtResource("3_nature")]',
                  '[node name="Ground" type="StaticBody3D" parent="Environment"]\ncollision_layer = 1\ncollision_mask = 0',
                  '[node name="CollisionShape3D" type="CollisionShape3D" parent="Environment/Ground"]\nposition = Vector3(0,-0.53,0)\nshape = SubResource("Floor")',
                  '[node name="NaturalObstacles" type="Node3D" parent="Environment"]'])
    for i,item in enumerate(obstacles):
        x,_,z=item["position"];height=item["collision"].get("height",0);a=item["rotation_y"]
        lines.extend([f'[node name="{item["name"]}" type="StaticBody3D" parent="Environment/NaturalObstacles"]\nposition = Vector3({x:.6f},{height/2:.6f},{z:.6f})\nrotation = Vector3(0,{a:.6f},0)\ncollision_layer = 1\ncollision_mask = 0',
                      f'[node name="CollisionShape3D" type="CollisionShape3D" parent="Environment/NaturalObstacles/{item["name"]}"]\nshape = SubResource("Shape{i}")'])
    lines.append('[node name="SpawnPoints" type="Node3D" parent="."]')
    for i,(x,z,alliance) in enumerate(definition["spawns"]):
        angle=math.atan2(-x,-z)
        tower_x,tower_z=definition["starting_towers"][i]
        lines.append(f'[node name="Player{i}" type="Marker3D" parent="SpawnPoints"]\nposition = Vector3({x},0,{z})\nrotation = Vector3(0,{angle:.6f},0)\nmetadata/alliance_id = {alliance}\nmetadata/player_id = {i}\nmetadata/starting_tower_position = Vector3({tower_x},0,{tower_z})')
    lines.append('[node name="Resources" type="Node3D" parent="."]')
    for i,(x,z) in enumerate(definition["mines"]):
        angle=definition["mine_rotations"][i] if "mine_rotations" in definition else (0 if x<0 else math.pi)
        lines.append(f'[node name="GoldVein{i}" parent="Resources" instance=ExtResource("4_mine")]\nposition = Vector3({x},0,{z})\nrotation = Vector3(0,{angle:.6f},0)')
    art.write_asset(MAPS/f"{name}.tscn","\n\n".join(lines)+"\n")
    report={**definition,"navigation_cell_size":1,"navigation_polygons":len(nav["polygons"]),
            "base_clearance_radius":11.5,"mine_clearance_radius":5.1,"obstacles":obstacles}
    art.write_asset(MAPS/f"{name}_layout.json",json.dumps(report,ensure_ascii=False,indent=2))
    if len(definition["spawns"])>=6:
        art.write_asset(ROOT/f"data/maps/{name}.tres",f'''[gd_resource type="Resource" script_class="MapDefinition" load_steps=3 format=3]

[ext_resource type="Script" path="res://scripts/data/map_definition.gd" id="script"]
[ext_resource type="PackedScene" path="res://scenes/maps/{name}.tscn" id="scene"]

[resource]
script = ExtResource("script")
id = &"{name}"
display_name = "{definition['title']}"
size = Vector2({w}, {d})
slots = {len(definition['spawns'])}
scene = ExtResource("scene")
''')
    print(f'{name}: {len(obstacles)} obstacles, {len(nav["polygons"])} connected-grid polygons, {len(definition["mines"])} mines')


def main():
    global RNG
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--maps",nargs="+",choices=[item["id"] for item in MAP_DEFINITIONS],help="Only author these maps.")
    parser.add_argument("--skip-models",action="store_true",help="Leave every existing building and ore mesh unchanged.")
    args=parser.parse_args()
    MAPS.mkdir(parents=True,exist_ok=True);LOCAL.mkdir(parents=True,exist_ok=True)
    if not args.skip_models:
        ore=collision_geometry("gold_vein",art.gold_vein())
        points=", ".join(f"{value:.6f}" for point in ore["points"] for value in point)
        art.write_asset(MODEL_DIR/"gold_vein_collision.tres",'[gd_resource type="ConvexPolygonShape3D" format=3]\n\n[resource]\npoints = PackedVector3Array('+points+')\nmargin = 0.01\n')
        for name,builder,limit in [("headquarters",art.headquarters,None),("defense_tower",player_defense_tower,None),("factory",factory,6.0),("academy",academy,6.0),("player_barracks",player_barracks,6.0)]:
            native_model(builder(),f"res://assets/models/environment/{name}.tscn",limit)
    for definition in MAP_DEFINITIONS:
        if args.maps and definition["id"] not in args.maps:continue
        if "seed" in definition:
            # Reset both authoring streams so a selected map is byte-for-byte
            # reproducible independently of which earlier maps were requested.
            RNG=np.random.default_rng(definition["seed"])
            art.RNG=np.random.default_rng(definition["seed"]+1000000)
        name=definition["id"]
        for mine in definition["mines"]:
            for road in definition["roads"]:
                clearance=LineString(road["points"]).distance(Point(mine))-road["width"]/2-3.35
                assert clearance>.75,f"{name} mine {mine} pinches a main or flank road"
        native_model(terrain(definition),f"res://scenes/maps/{name}_ground.tscn",shadow=False)
        decor,obstacles=natural_layout(definition)
        native_model(decor,f"res://scenes/maps/{name}_nature.tscn")
        write_map(definition,obstacles,navigation(definition,obstacles))
    art.write_asset(LOCAL/"manifest.json",json.dumps(MANIFEST,indent=2))
    print("Authoring arrays ready. Run Godot --headless --path . --script res://tests/skirmish_maps_bake.gd")


if __name__=="__main__":main()
