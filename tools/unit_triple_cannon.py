"""Three short hollow barrels on a low two-wheel carriage; saved native clips."""
import math
from build_units import Sculpture, OUT, lathe, ring, polygon, anim_resource, vec, wheel

WHEEL_RADIUS = .50
PITCH = .035
MUZZLE = (0, .95*math.sin(PITCH), -.95*math.cos(PITCH))

def build_triple_cannon():
    s=Sculpture('triple_cannon')
    body=s.joint('Body')
    for sign in (-1,1):
        s.b(body,(.16,.19,1.70),(sign*.62,.48,.19),'wood',bevel=.024)
        s.add(body,polygon([(-.72,-.17),(.72,-.17),(.60,.12),(.19,.37),(-.49,.37)],.16,(sign*.68,.59,.15),(0,math.pi/2,0)),'woodlight')
        s.b(body,(.17,.16,.28),(sign*.37,.22,1.16),'darksteel',bevel=.016)
        s.r(body,(sign*.62,.48,.62),(sign*.37,.23,1.16),.08,'wood',6)
        s.b(body,(.04,.27,.50),(sign*.79,.63,.42),'bronzelight',bevel=.016)
        s.b(body,(.045,.22,.43),(sign*.815,.63,.42),'blue',bevel=.012)
        s.b(body,(.052,.17,.035),(sign*.842,.63,.42),'goldlight',bevel=.003)
        s.b(body,(.052,.035,.22),(sign*.842,.665,.42),'goldlight',bevel=.003)
        part=s.joint('WheelLeft' if sign<0 else 'WheelRight',(sign*.93,.50,.17))
        wheel(s,part,WHEEL_RADIUS,.17)
    for z in (-.51,.13,.73):
        s.b(body,(1.54,.14,.17),(0,.44,z),'wooddark',bevel=.022)
    s.r(body,(-1.05,.50,.17),(1.05,.50,.17),.075,'darksteel',12)
    s.b(body,(1.32,.07,1.46),(0,.60,.14),'wood',bevel=.018)
    s.b(body,(1.50,.09,.21),(0,.82,.03),'darksteel',bevel=.016)
    s.b(body,(1.38,.05,.24),(0,.66,.86),'blue',bevel=.013)
    for x in (-.50,0,.50):
        for z in (-.44,.47):
            s.b(body,(.12,.25,.16),(x,.70,z),'bronze',bevel=.015)
        s.b(body,(.25,.06,.99),(x,.79,.07),'steel',bevel=.010)
        s.e(body,(.105,.105,.105),(x,.80,.89),'darksteel',sub=1)
    s.b(body,(.75,.11,.16),(0,.24,1.20),'wooddark',bevel=.012)
    s.add(body,ring(.11,.023,(0,.24,1.33),(math.pi/2,0,0),n=10),'darksteel')
    for i,x in enumerate((-.50,0,.50)):
        barrel=s.joint('Barrel'+str(i),(x,1.00,-.10))
        axis=(-math.pi/2+PITCH,0,0)
        profile=[(-.43,.145),(-.33,.204),(.09,.204),(.68,.178),(.77,.214),(.90,.214),(.95,.194),(.95,.128)]
        s.add(barrel,lathe(profile,14,rot=axis,caps=False),'darksteel')
        s.add(barrel,lathe([(.95,.128),(.52,.128)],14,rot=axis,caps=False),'black')
        s.add(barrel,lathe([(.51,.127),(.52,.127)],14,rot=axis),'black')
        for y,r,color in [(-.25,.211,'steel'),(.35,.202,'blue'),(.83,.221,'bronzelight')]:
            s.add(barrel,lathe([(y-.028,r),(y+.028,r)],14,rot=axis,caps=False),color)
        s.add(barrel,lathe([(.927,.207),(.95,.194),(.95,.128),(.927,.128)],14,rot=axis,caps=False),'edge')
        s.e(barrel,(.15,.15,.065),(0,-.015,.44),'bronze')
        s.e(barrel,(.058,.058,.067),(0,-.020,.50),'bronzelight')
        s.b(barrel,(.06,.032,.09),(0,.213,.16),'bronzelight',bevel=.007)
    return s

def write_triple_cannon_scene(s):
    lines=['[gd_scene format=3]','[ext_resource type="Script" path="res://scripts/unit_visual.gd" id="script"]']
    for part in s.parts:
        lines.append(f'[ext_resource type="ArrayMesh" path="res://assets/models/units/triple_cannon/{part}.res" id="{part}"]')
    walk=[(s.part_path(part)+':rotation',[(-i*math.pi/2,0,0) for i in range(5)]) for part in s.parts if part.startswith('Wheel')]
    lines += [anim_resource('idle',2.4,[('Rig:position',[(0,0,0)]*2)],True),anim_resource('walk',math.tau*WHEEL_RADIUS/2.4,walk,True)]
    for mask in range(8):
        tracks=[]
        for i in range(3):
            at=.25+i*.10
            times=[0,at,at+.05,at+.16,at+.40,1.25,1.95,2.4]
            recoil=[0,0,.24,.19,.12,.04,0,0] if mask&(1<<i) else [0]*8
            base=s.joints['Barrel'+str(i)]
            tracks.append((s.part_path('Barrel'+str(i))+':position',[(base[0],base[1]-d*math.sin(PITCH),base[2]+d*math.cos(PITCH)) for d in recoil],times))
        lines.append(anim_resource('volley_'+str(mask),2.4,tracks))
    clips=', '.join(f'&"volley_{i}": SubResource("Animation_volley_{i}")' for i in range(8))
    lines += ['[sub_resource type="AnimationLibrary" id="locomotion"]\n_data = {&"idle": SubResource("Animation_idle"), &"walk": SubResource("Animation_walk")}',
              '[sub_resource type="AnimationLibrary" id="attack"]\n_data = {&"strike": SubResource("Animation_volley_7"), '+clips+'}',
              '[node name="TripleCannon" type="Node3D"]\nscript = ExtResource("script")\nkind = "triple_cannon"\nprojectile_socket = NodePath("Rig/Action/Barrel0/ProjectileSocket")\nextra_projectile_sockets = Array[NodePath]([NodePath("Rig/Action/Barrel1/ProjectileSocket"), NodePath("Rig/Action/Barrel2/ProjectileSocket")])',
              '[node name="Rig" type="Node3D" parent="."]','[node name="Action" type="Node3D" parent="Rig"]']
    for part in s.parts:
        lines.append(f'[node name="{part}" type="MeshInstance3D" parent="Rig/Action"]\nposition = {vec(s.joints[part])}\nmesh = ExtResource("{part}")')
    for i in range(3):
        lines.append(f'[node name="ProjectileSocket" type="Marker3D" parent="Rig/Action/Barrel{i}"]\nposition = {vec(MUZZLE)}')
    lines += ['[node name="Locomotion" type="AnimationPlayer" parent="."]\ncallback_mode_process = 0\nlibraries = {&"": SubResource("locomotion")}\nautoplay = "idle"',
              '[node name="Attack" type="AnimationPlayer" parent="."]\ncallback_mode_process = 0\nlibraries = {&"": SubResource("attack")}',
              '[node name="VisibilityNotifier" type="VisibleOnScreenNotifier3D" parent="."]\naabb = AABB(-1.3,-0.2,-1.5,2.6,1.8,3.2)',
              '[connection signal="screen_entered" from="VisibilityNotifier" to="." method="_on_screen_entered"]',
              '[connection signal="screen_exited" from="VisibilityNotifier" to="." method="_on_screen_exited"]']
    (OUT/'triple_cannon.tscn').write_text('\n\n'.join(lines)+'\n',encoding='utf-8')
