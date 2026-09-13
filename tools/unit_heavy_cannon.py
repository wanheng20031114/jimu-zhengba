"""Heavy cannon: a hollow gun on a four-wheel carriage, with saved native clips."""
import math
from build_units import Sculpture, OUT, lathe, ring, polygon, anim_resource, vec

WHEEL_RADIUS = .60
BARREL_FRONT = 2.65
MUZZLE = (0, BARREL_FRONT * math.sin(.065), -BARREL_FRONT * math.cos(.065))


def heavy_wheel(s, part):
    # Thick wooden felloe and a continuous iron tire, with genuinely open spokes.
    axis = (0, 0, -math.pi / 2)
    s.add(part, lathe([(-.115,.46),(-.115,.565),(.115,.565),(.115,.46),(-.115,.46)],16,rot=axis,caps=False), 'woodlight')
    s.add(part, lathe([(-.123,.557),(-.123,.60),(.123,.60),(.123,.557),(-.123,.557)],16,rot=axis,caps=False), 'darksteel')
    for i in range(8):
        a = i * math.tau / 8
        s.r(part,(0,.11*math.cos(a),.11*math.sin(a)),(0,.49*math.cos(a),.49*math.sin(a)),.050,'wood',6)
        for sign in (-1,1):
            s.e(part,(.018,.025,.025),(sign*.127,.525*math.cos(a),.525*math.sin(a)),'steel',sub=0)
    s.r(part,(-.18,0,0),(.18,0,0),.14,'wooddark',12)
    s.r(part,(-.20,0,0),(.20,0,0),.085,'darksteel',10)
    for sign in (-1,1):
        s.r(part,(sign*.16,0,0),(sign*.195,0,0),.13,'bronzelight',10)


def build_heavy_cannon():
    s = Sculpture('heavy_cannon')
    body = s.joint('Body')
    # Splayed hardwood cheeks, iron straps, two axles and a broad slatted bed.
    for sign in (-1,1):
        s.b(body,(.24,.25,2.42),(sign*.62,.55,.10),'wood',bevel=.028)
        s.add(body,polygon([(-1.04,-.18),(1.01,-.18),(.66,.19),(.32,.64),(-.42,.64),(-.87,.32)],.22,(sign*.55,.80,.03),(0,math.pi/2,0)),'woodlight')
        for z in (-.73,.75):
            s.b(body,(.25,.33,.13),(sign*.62,.64,z),'darksteel',bevel=.014)
            s.e(body,(.026,.037,.037),(sign*.755,.69,z),'steel')
        s.b(body,(.06,.38,.13),(sign*.69,1.13,-.12),'darksteel',bevel=.011)
        s.r(body,(sign*.43,1.34,-.12),(sign*.76,1.34,-.12),.13,'steel',12)
    for z in (-.85,0,.85):
        s.b(body,(1.48,.20,.22),(0,.48,z),'wooddark',bevel=.024)
    for x in (-.4,0,.4):
        s.b(body,(.38,.10,2.19),(x,.69,.10),'wood',bevel=.01)
    for end,z in [('Front',-.80),('Rear',.89)]:
        s.r(body,(-1.15,.60,z),(1.15,.60,z),.095,'darksteel',12)
        for side,sign in [('Left',-1),('Right',1)]:
            kick = s.pivot('Wheel'+end+side+'Kick',(sign*1.00,.60,z))
            part = s.joint('Wheel'+end+side,(0,0,0),kick)
            heavy_wheel(s,part)
    # Fixed trunnions hold an elevation cradle; only the gun slides on firing.
    elevation = s.pivot('Elevation',(0,1.34,-.12))
    cradle = s.joint('Cradle',(0,0,0),elevation)
    s.r(cradle,(-.69,0,0),(.69,0,0),.10,'darksteel',12)
    for sign in (-1,1):
        s.b(cradle,(.085,.085,1.12),(sign*.31,-.23,.28),'steel',bevel=.01)
        s.b(cradle,(.07,.15,.20),(sign*.31,-.19,.80),'darksteel',bevel=.015)
    s.b(body,(.34,.18,.27),(0,.90,.69),'wooddark',bevel=.018)
    s.r(body,(0,.85,.71),(0,1.11,.58),.045,'darksteel',10)
    s.add(body,ring(.17,.025,(0,.86,.87),(math.pi/2,0,0),n=12),'steel')
    barrel = s.joint('Barrel',(0,.05,0),elevation)
    axis = (-math.pi/2+.065,0,0)
    # Shorten the exposed tube while retaining the breech, bore and muzzle widths.
    profile=[(-1.00,.28),(-.87,.41),(-.38,.417),(.35,.354),(BARREL_FRONT-.54,.324),(BARREL_FRONT-.28,.413),(BARREL_FRONT-.08,.413),(BARREL_FRONT,.372),(BARREL_FRONT,.262)]
    s.add(barrel,lathe(profile,18,rot=axis,caps=False),'darksteel')
    s.add(barrel,lathe([(BARREL_FRONT,.262),(BARREL_FRONT-.80,.262)],18,rot=axis,caps=False),'black')
    s.add(barrel,lathe([(BARREL_FRONT-.81,.261),(BARREL_FRONT-.80,.261)],18,rot=axis),'black')
    for y,r,color in [(-.70,.424,'steel'),(-.18,.402,'steel'),(.90,.35,'blue'),(BARREL_FRONT-.17,.423,'steel')]:
        s.add(barrel,lathe([(y-.05,r),(y+.05,r)],18,rot=axis,caps=False),color)
    s.add(barrel,lathe([(BARREL_FRONT-.025,.395),(BARREL_FRONT,.372),(BARREL_FRONT,.262),(BARREL_FRONT-.025,.262)],18,rot=axis,caps=False),'edge')
    s.e(barrel,(.29,.29,.10),(0,-.055,1.00),'darksteel')
    s.e(barrel,(.105,.105,.13),(0,-.063,1.13),'bronzelight')
    s.b(barrel,(.11,.065,.13),(0,.393,.47),'bronzelight',bevel=.015)
    s.e(barrel,(.023,.010,.023),(0,.427,.47),'black')
    # A modest cast crest leaves the bore and iron bands as the main silhouette.
    s.b(barrel,(.07,.025,.28),(0,.360,.06),'bronzelight',bevel=.005)
    s.b(barrel,(.23,.026,.055),(0,.363,.01),'bronzelight',bevel=.005)
    # Large fixed team panels between the axles remain readable from above.
    for sign in (-1,1):
        s.b(body,(.055,.40,.69),(sign*.73,.98,.40),'bronzelight',bevel=.024)
        s.b(body,(.06,.33,.61),(sign*.765,.98,.40),'blue',bevel=.015)
        s.b(body,(.068,.25,.04),(sign*.80,.98,.40),'goldlight',bevel=.004)
        s.b(body,(.068,.04,.34),(sign*.80,1.025,.40),'goldlight',bevel=.004)
    s.b(body,(1.13,.065,.32),(0,.77,1.08),'blue',bevel=.012)
    for x in (-.40,0,.40):
        s.e(body,(.14,.14,.14),(x,.92,.98),'darksteel')
    for sign in (-1,1):
        s.b(body,(.13,.23,.15),(sign*.62,.62,1.35),'darksteel',bevel=.018)
        s.add(body,ring(.115,.025,(sign*.62,.57,1.45),(math.pi/2,0,0),n=10),'steel')
    s.r(body,(.81,.46,-.34),(.81,.46,1.26),.026,'woodlight',8)
    s.e(body,(.055,.055,.13),(.81,.46,1.25),'rope')
    return s


def write_heavy_cannon_scene(s):
    parts=list(s.parts)
    lines=['[gd_scene format=3]','[ext_resource type="Script" path="res://scripts/unit_visual.gd" id="script"]']
    for part in parts:
        lines.append(f'[ext_resource type="ArrayMesh" path="res://assets/models/units/heavy_cannon/{part}.res" id="{part}"]')
    walk=[]
    # Five quarter-turn keys avoid ambiguous 180-degree quaternion interpolation.
    for part in parts:
        if part.startswith('Wheel'):
            walk.append((s.part_path(part)+':rotation',[(-i*math.pi/2,0,0) for i in range(5)]))
    times=[0,.22,.40,.45,.51,.68,1.05,1.7,2.8,3.8,4.2]
    recoil=[0,0,0,0,.52,.43,.33,.24,.11,0,0]
    strike=[(s.part_path('Barrel')+':position',[(0,.05-d*math.sin(.065),d*math.cos(.065)) for d in recoil],times),
            (s.part_path('Elevation')+':rotation',[(x,0,0) for x in [0,.014,.028,.028,.052,.016,.024,.012,.006,0,0]],times),
            ('Rig/Action:position',[(0,0,z) for z in [0,0,0,0,.075,.058,.025,0,0,0,0]],times)]
    for pivot in s.pivots:
        if pivot.endswith('Kick'):
            strike.append((s.part_path(pivot)+':rotation',[(z/WHEEL_RADIUS,0,0) for z in [0,0,0,0,.075,.058,.025,0,0,0,0]],times))
    lines += [anim_resource('idle',2.6,[('Rig:position',[(0,0,0)]*2)],True),
              anim_resource('walk',math.tau*WHEEL_RADIUS/1.8,walk,True),anim_resource('strike',4.2,strike),
              '[sub_resource type="AnimationLibrary" id="locomotion"]\n_data = {&"idle": SubResource("Animation_idle"), &"walk": SubResource("Animation_walk")}',
              '[sub_resource type="AnimationLibrary" id="attack"]\n_data = {&"strike": SubResource("Animation_strike")}',
              '[node name="HeavyCannon" type="Node3D"]\nscript = ExtResource("script")\nkind = "heavy_cannon"\nprojectile_socket = NodePath("Rig/Action/Elevation/Barrel/ProjectileSocket")',
              '[node name="Rig" type="Node3D" parent="."]','[node name="Action" type="Node3D" parent="Rig"]']
    emitted=set()
    def emit(part):
        if part in emitted:return
        parent_part=s.parents[part]
        if parent_part:emit(parent_part)
        parent=s.part_path(parent_part) if parent_part else 'Rig/Action'
        if part in s.pivots:
            lines.append(f'[node name="{part}" type="Node3D" parent="{parent}"]\nposition = {vec(s.joints[part])}')
        else:
            lines.append(f'[node name="{part}" type="MeshInstance3D" parent="{parent}"]\nposition = {vec(s.joints[part])}\nmesh = ExtResource("{part}")')
        emitted.add(part)
    for part in parts:emit(part)
    lines += [f'[node name="ProjectileSocket" type="Marker3D" parent="Rig/Action/Elevation/Barrel"]\nposition = {vec(MUZZLE)}',
              '[node name="Locomotion" type="AnimationPlayer" parent="."]\ncallback_mode_process = 0\nlibraries = {&"": SubResource("locomotion")}\nautoplay = "idle"',
              '[node name="Attack" type="AnimationPlayer" parent="."]\ncallback_mode_process = 0\nlibraries = {&"": SubResource("attack")}',
              '[node name="VisibilityNotifier" type="VisibleOnScreenNotifier3D" parent="."]\naabb = AABB(-1.6,-0.3,-3.3,3.2,2.7,5.6)',
              '[connection signal="screen_entered" from="VisibilityNotifier" to="." method="_on_screen_entered"]',
              '[connection signal="screen_exited" from="VisibilityNotifier" to="." method="_on_screen_exited"]']
    (OUT/'heavy_cannon.tscn').write_text('\n\n'.join(lines)+'\n',encoding='utf-8')
