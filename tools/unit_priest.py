"""Priest sculpture and saved rigid clips; builds only this unit when selected."""
import math
import numpy as np
import trimesh as tm
from build_units import Sculpture, OUT, lathe, anim_resource, vec, farmer_arm_pose


def cloth_shell(profile, start, end, sections, thickness=.018):
    """A thick, open arc; its front opening leaves the face or moving legs free."""
    outer = [(y, rx, rz) for y, rx, rz in profile]
    inner = [(y, rx-thickness, rz-thickness) for y, rx, rz in profile]
    rows = outer + inner[::-1] + outer[:1]
    angles = np.linspace(math.radians(start), math.radians(end), sections+1)
    vertices = [(rx*math.sin(a),y,rz*math.cos(a)) for y,rx,rz in rows for a in angles]
    faces = []
    width = sections+1
    for row in range(len(rows)-1):
        for col in range(sections):
            a=row*width+col; b=a+1; c=a+width; d=c+1
            faces.extend([(a,b,c),(b,d,c)])
    for col in (0,sections):
        for row in range(len(outer)-1):
            a=row*width+col; b=(row+1)*width+col
            c=(2*len(outer)-1-row)*width+col; d=c-width
            faces.extend([(a,c,b),(b,c,d)])
    mesh=tm.Trimesh(vertices=vertices,faces=faces,process=False)
    mesh.fix_normals()
    return mesh


def build_priest():
    s=Sculpture('priest')
    body=s.joint('Body',(0,1.05,0))
    head=s.joint('Head',(0,1.64,0))
    s.add(body,lathe([(-.29,.265),(-.05,.24),(.23,.285),(.29,.22)],10),'ivory')
    # The two stoles and the back panel supply team color without tinting skin.
    for sign in (-1,1):
        s.b(body,(.11,.49,.034),(sign*.135,.035,-.276),'blue',rot=(0,0,sign*.08),bevel=.009)
        s.b(body,(.12,.035,.039),(sign*.15,-.205,-.281),'bronzelight',bevel=.004)
    s.b(body,(.16,.46,.04),(0,.015,.275),'blue',bevel=.008)
    s.add(body,lathe([(-.24,.275),(-.17,.27)],10,caps=False),'leather')
    s.b(body,(.075,.067,.035),(0,-.205,-.28),'bronzelight',bevel=.007)
    s.r(body,(-.08,.245,-.23),(0,.095,-.29),.013,'bronzelight',6)
    s.r(body,(.08,.245,-.23),(0,.095,-.29),.013,'bronzelight',6)
    s.b(body,(.031,.13,.023),(0,.044,-.303),'bronzelight',bevel=.004)
    s.b(body,(.095,.028,.026),(0,.063,-.305),'bronzelight',bevel=.004)
    # A book in a leather case on the hip, leaving both hands entirely free.
    s.b(body,(.18,.25,.17),(-.28,-.24,.065),'leather',rot=(0,0,-.12),bevel=.018)
    s.b(body,(.144,.21,.13),(-.285,-.223,.067),'ivory',rot=(0,0,-.12),bevel=.004)
    for z in (-.011,.141):
        s.b(body,(.19,.255,.021),(-.282,-.225,z),'wooddark',rot=(0,0,-.12),bevel=.005)
    s.b(body,(.05,.09,.026),(-.29,-.20,-.033),'bronzelight',rot=(0,0,-.12),bevel=.005)
    s.r(body,(-.20,-.145,.01),(-.27,-.12,.02),.021,'leather',6)

    s.e(head,(.235,.253,.22),(0,-.015,-.01),'skin',sub=2)
    # A linen hood forms a real open shell around the crown, not a face mask.
    hood_profile=[(-.19,.258,.242),(.08,.285,.27),(.235,.233,.23),(.295,.105,.125),(.315,.032,.04)]
    s.add(head,cloth_shell(hood_profile,-125,125,10),'ivory')
    for sign in (-1,1):
        edge=[(sign*rx*math.sin(math.radians(125)),y,rz*math.cos(math.radians(125))) for y,rx,rz in hood_profile]
        for a,b in zip(edge,edge[1:]): s.r(head,a,b,.020,'blue',6)
        for point in edge: s.e(head,(.023,.023,.023),point,'blue',sub=0)
        s.e(head,(.037,.067,.05),(sign*.223,-.034,-.02),'skin')
        s.b(head,(.047,.028,.018),(sign*.084,.026,-.229),'black',bevel=.003)
        s.b(head,(.074,.025,.018),(sign*.084,.07,-.216),'mane',rot=(0,0,sign*.08),bevel=.003)
    s.r(head,(-.0262,.315,-.0229),(.0262,.315,-.0229),.020,'blue',6)
    s.e(head,(.043,.058,.07),(0,-.028,-.232),'skin')
    s.e(head,(.15,.095,.085),(0,-.184,-.145),'mane')
    s.b(head,(.117,.024,.018),(0,-.112,-.218),'leather',bevel=.004)

    for side,sign in (('Left',-1),('Right',1)):
        arm=s.joint('Arm'+side,(sign*.31,1.32,0))
        s.e(arm,(.143,.132,.152),(sign*.013,0,0),'ivory')
        s.r(arm,(0,-.02,0),(sign*.045,-.24,0),.106,'ivory',8)
        fore=s.joint('Forearm'+side,(sign*.045,-.24,0),arm)
        s.e(fore,(.106,.105,.106),(0,0,0),'ivory')
        s.r(fore,(0,0,0),(sign*.023,-.185,-.041),.102,'ivory',8,r2=.075)
        s.r(fore,(sign*.02,-.142,-.03),(sign*.025,-.177,-.040),.088,'blue',8)
        s.r(fore,(sign*.025,-.175,-.04),(sign*.025,-.216,-.051),.056,'skin',8)
        s.e(fore,(.074,.071,.079),(sign*.025,-.235,-.055),'skin')
        s.b(fore,(.049,.073,.064),(sign*-.018,-.234,-.1),'skin',bevel=.013)
    for name,x in (('LegLeft',-.15),('LegRight',.15)):
        leg=s.joint(name,(x,.74,0))
        s.r(leg,(0,0,0),(0,-.51,0),.09,'leather',8)
        s.b(leg,(.19,.18,.27),(0,-.635,-.07),'leather',bevel=.024)
        s.b(leg,(.20,.038,.29),(0,-.711,-.07),'wooddark',bevel=.008)
    for name,angles,sign in [('RobeFront',(90,270),-1),('RobeBack',(-90,90),1)]:
        skirt=s.joint(name,(0,.80,0))
        s.add(skirt,cloth_shell([(0,.265,.23),(-.54,.355,.30)],*angles,8),'ivory')
        s.b(skirt,(.15,.48,.026),(0,-.262,sign*.276),'blue',rot=(-sign*.129,0,0),bevel=.006)
        s.b(skirt,(.158,.032,.03),(0,-.499,sign*.307),'bronzelight',bevel=.004)
    waist=s.pivot('Waist',(0,1.05,0))
    for part in (body,head,'ArmLeft','ArmRight','RobeFront','RobeBack'): s.reparent(part,waist)
    return s


def arm_tracks(s,targets,times):
    tracks=[]
    for side,sign in (('Left',-1),('Right',1)):
        poses=[farmer_arm_pose(s,side,position) for position in targets[side]]
        tracks.append((s.part_path('Arm'+side)+':rotation',[p[0] for p in poses],times))
        tracks.append((s.part_path('Forearm'+side)+':rotation',[p[1] for p in poses],times))
    return tracks


def write_priest_scene(s):
    parts=list(s.parts)
    lines=['[gd_scene format=3]', '[ext_resource type="Script" path="res://scripts/unit_visual.gd" id="1_script"]',
           '[ext_resource type="PackedScene" path="res://scenes/healing_hand_particles.tscn" id="hand_particles"]']
    for i,p in enumerate(parts): lines.append(f'[ext_resource type="ArrayMesh" path="res://assets/models/units/priest/{p}.res" id="{i+2}_{p}"]')
    path=lambda part,prop:s.part_path(part)+':'+prop
    idle_targets={side:[(sign*.36,-.16,-.12)]*3 for side,sign in [('Left',-1),('Right',1)]}
    idle=arm_tracks(s,idle_targets,[0,1.3,2.6])
    walk_targets={side:[(sign*.36,-.16,-.12+sign*z) for z in [0,.025,0,-.025,0]] for side,sign in [('Left',-1),('Right',1)]}
    walk=arm_tracks(s,walk_targets,[0,.195,.39,.585,.78])
    heal_targets={side:[(sign*x,y,z) for x,y,z in [(.36,-.16,-.12),(.18,.16,-.36),(.25,.25,-.35),(.30,.22,-.47),(.29,.17,-.39),(.36,-.16,-.12)]] for side,sign in [('Left',-1),('Right',1)]}
    heal_times=[0,.18,.42,.6,.82,1]
    heal=arm_tracks(s,heal_targets,heal_times)
    strike_targets={'Right':[(.36,-.16,-.12),(.23,.15,-.20),(.34,.13,-.47),(.32,.13,-.40),(.36,-.16,-.12)],
                    'Left':[(-.36,-.16,-.12),(-.23,.12,-.30),(-.23,.12,-.30),(-.25,.08,-.27),(-.36,-.16,-.12)]}
    strike_times=[0,.12,.25,.39,.70]
    strike=arm_tracks(s,strike_targets,strike_times)
    for part,sign in [('LegLeft',1),('LegRight',-1)]:
        idle.append((path(part,'rotation'),[(0,0,0)]*2))
        walk.append((path(part,'rotation'),[(sign*a,0,0) for a in [0,.26,0,-.26,0]]))
        heal.append((path(part,'rotation'),[(0,0,0)]*2))
        strike.append((path(part,'rotation'),[(0,0,0)]*2))
    for part,sign in [('RobeFront',1),('RobeBack',-1)]:
        idle.append((path(part,'rotation'),[(0,0,0)]*2))
        walk.append((path(part,'rotation'),[(sign*a,0,0) for a in [0,.065,0,-.065,0]]))
        heal.append((path(part,'rotation'),[(0,0,0)]*2))
        strike.append((path(part,'rotation'),[(0,0,0)]*2))
    for tracks in (idle,walk):
        for part in ('Waist','Head'): tracks.append((path(part,'rotation'),[(0,0,0)]*2))
    idle.append(('Rig:position',[(0,0,0),(0,.01,0),(0,0,0)]))
    walk.append(('Rig:position',[(0,y,0) for y in [0,.016,0,.016,0]]))
    heal.extend([(path('Waist','rotation'),[(a,0,0) for a in [0,.04,.06,.10,.06,0]],heal_times),
                 (path('Head','rotation'),[(.04,0,0)]*2),('Rig:position',[(0,0,0)]*2)])
    strike.extend([(path('Waist','rotation'),[(0,0,0),(.05,.10,0),(.08,-.14,0),(.06,-.08,0),(0,0,0)],strike_times),
                   (path('Head','rotation'),[(0,0,0)]*2),('Rig:position',[(0,0,0)]*2)])
    lines += [anim_resource('idle',2.6,idle,True),anim_resource('walk',.78,walk,True),anim_resource('heal',1,heal,True),anim_resource('strike',.7,strike),
              '[sub_resource type="AnimationLibrary" id="AnimationLibrary_locomotion"]\n_data = {&"idle": SubResource("Animation_idle"), &"walk": SubResource("Animation_walk")}',
              '[sub_resource type="AnimationLibrary" id="AnimationLibrary_attack"]\n_data = {&"strike": SubResource("Animation_strike"), &"heal": SubResource("Animation_heal")}',
              '[node name="Priest" type="Node3D"]\nscript = ExtResource("1_script")\nkind = "priest"\nprojectile_socket = NodePath("Rig/Action/Waist/ArmRight/ForearmRight/Palm")\nsupport_particle_paths = Array[NodePath]([NodePath("Rig/Action/Waist/ArmLeft/ForearmLeft/HealingHand"), NodePath("Rig/Action/Waist/ArmRight/ForearmRight/HealingHand")])',
              '[node name="Rig" type="Node3D" parent="."]','[node name="Action" type="Node3D" parent="Rig"]']
    emitted=set()
    def emit(part):
        if part in emitted:return
        parent_part=s.parents[part]
        if parent_part:emit(parent_part)
        parent=s.part_path(parent_part) if parent_part else 'Rig/Action'
        if part in s.pivots: lines.append(f'[node name="{part}" type="Node3D" parent="{parent}"]\nposition = {vec(s.joints[part])}')
        else:lines.append(f'[node name="{part}" type="MeshInstance3D" parent="{parent}"]\nposition = {vec(s.joints[part])}\nmesh = ExtResource("{parts.index(part)+2}_{part}")')
        emitted.add(part)
    for part in parts:emit(part)
    for side,sign in [('Left',-1),('Right',1)]:
        parent=s.part_path('Forearm'+side)
        lines.append(f'[node name="HealingHand" parent="{parent}" instance=ExtResource("hand_particles")]\nposition = {vec((sign*.025,-.235,-.10))}')
    lines += ['[node name="Palm" type="Marker3D" parent="Rig/Action/Waist/ArmRight/ForearmRight"]\nposition = Vector3(0.025,-0.235,-0.12)',
        '[node name="Locomotion" type="AnimationPlayer" parent="."]\ncallback_mode_process = 0\nlibraries = {&"": SubResource("AnimationLibrary_locomotion")}\nautoplay = "idle"',
        '[node name="Attack" type="AnimationPlayer" parent="."]\ncallback_mode_process = 0\nlibraries = {&"": SubResource("AnimationLibrary_attack")}',
        '[node name="VisibilityNotifier" type="VisibleOnScreenNotifier3D" parent="."]\naabb = AABB(-2,-1,-2,4,4,4)',
        '[connection signal="screen_entered" from="VisibilityNotifier" to="." method="_on_screen_entered"]',
        '[connection signal="screen_exited" from="VisibilityNotifier" to="." method="_on_screen_exited"]']
    (OUT/'priest.tscn').write_text('\n\n'.join(lines)+'\n',encoding='utf-8')
