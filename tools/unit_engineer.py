"""Engineer sculpture and saved rigid animations. Imported by build_units.py."""
from build_units import Sculpture, OUT, lathe, polygon, anim_resource, vec, farmer_arm_pose


def build_engineer():
    s = Sculpture('engineer')
    body = s.joint('Body', (0, 1.05, 0))
    head = s.joint('Head', (0, 1.64, 0))
    left = s.joint('ArmLeft', (-.32, 1.32, 0))
    right = s.joint('ArmRight', (.32, 1.32, 0))
    s.add(body, lathe([(-.29,.265),(-.08,.24),(.23,.30),(.29,.23)], 8), 'blue')
    # The heavy chest bib ends above the moving thighs; a separate belt and
    # rolled tool pack distinguish this smith from the farmer's linen uniform.
    s.add(body, polygon([(-.17,.22),(.17,.22),(.20,-.28),(.15,-.35),(-.15,-.35),(-.20,-.28)], .055, (0,0,-.252)), 'leather')
    s.b(body, (.27,.15,.025), (0,-.09,-.294), 'leatherlight', bevel=.018)
    for sign in (-1,1):
        s.b(body, (.048,.27,.035), (sign*.12,.22,-.270), 'leatherlight', rot=(0,0,sign*.20), bevel=.006)
        s.b(body, (.045,.065,.018), (sign*.14,.15,-.292), 'steel', bevel=.008)
        s.b(body, (.036,.30,.031), (sign*.18,.12,.238), 'leather', rot=(0,0,-sign*.22), bevel=.008)
    s.b(body, (.53,.095,.37), (0,-.055,0), 'leatherlight', bevel=.016)
    s.b(body, (.095,.082,.032), (0,-.05,-.304), 'steel', bevel=.007)
    s.b(body, (.047,.037,.016), (0,-.05,-.325), 'leather', bevel=.003)
    # Leather roll across the back, with two retaining straps and exposed tools.
    s.r(body, (-.21,-.06,.26), (.21,-.06,.26), .11, 'leatherlight', 8)
    for x in (-.14,.14):
        s.b(body, (.037,.22,.13), (x,-.06,.292), 'leather', bevel=.008)
        s.b(body, (.045,.045,.014), (x,-.045,.363), 'steel', bevel=.006)
    for x in (-.075,.04):
        s.r(body, (x,-.02,.27), (x,.24,.27), .023, 'woodlight', 6)
        s.r(body, (x,.22,.27), (x,.32,.27), .017, 'darksteel', 6)
    s.b(body, (.18,.22,.155), (-.28,-.16,.04), 'leather', bevel=.022)
    s.b(body, (.18,.08,.03), (-.28,-.085,-.05), 'leatherlight', bevel=.012)
    s.b(body, (.034,.05,.017), (-.28,-.10,-.07), 'steel', bevel=.004)
    # Open face with eyes at the same relative height as the infantry heads.
    s.e(head, (.235,.253,.22), (0,-.015,-.01), 'skin', sub=2)
    s.e(head, (.247,.15,.232), (0,.12,.022), 'mane')
    s.add(head, lathe([(.115,.25),(.17,.264),(.25,.21),(.29,.06)], 10), 'blue')
    s.add(head, lathe([(.104,.254),(.143,.265)], 10, caps=False), 'leatherlight')
    s.b(head, (.26,.037,.07), (0,.144,-.238), 'leather', bevel=.012)
    for sign in (-1,1):
        s.e(head, (.044,.072,.057), (sign*.226,-.022,0), 'skin')
        s.b(head, (.046,.028,.016), (sign*.084,.026,-.229), 'black', bevel=.003)
        s.b(head, (.077,.027,.018), (sign*.084,.071,-.215), 'mane', rot=(0,0,sign*.07), bevel=.003)
        s.b(head, (.045,.105,.05), (sign*.202,.025,.0), 'mane', bevel=.01)
    s.e(head, (.042,.056,.068), (0,-.027,-.231), 'skin')
    s.b(head, (.13,.025,.018), (0,-.115,-.217), 'leather', bevel=.007)
    for part,sign in ((left,-1),(right,1)):
        s.e(part, (.156,.139,.168), (sign*.014,.005,0), 'blue')
        s.r(part, (0,-.06,0), (sign*.045,-.24,0), .096, 'blue', 8)
        s.add(part, lathe([(-.03,.103),(.03,.105)],8,(sign*.035,-.19,0)), 'ivory')
        fore = s.joint('ForearmLeft' if sign < 0 else 'ForearmRight', (sign*.045,-.24,0), part)
        s.r(fore, (0,0,0), (sign*.025,-.20,-.045), .075, 'skin', 8)
        s.b(fore, (.14,.10,.14), (sign*.025,-.20,-.048), 'leatherlight', bevel=.018)
        s.e(fore, (.081,.078,.09), (sign*.025,-.235,-.055), 'leatherlight')
    for name,x in (('LegLeft',-.155),('LegRight',.155)):
        leg = s.joint(name,(x,.74,0))
        s.r(leg,(0,0,0),(0,-.34,.005),.103,'black',8)
        s.b(leg,(.182,.23,.16),(0,-.43,.003),'leather',bevel=.022)
        s.b(leg,(.214,.17,.32),(0,-.637,-.075),'leatherlight',bevel=.027)
        s.b(leg,(.219,.039,.33),(0,-.707,-.075),'wooddark',bevel=.009)
        s.b(leg,(.19,.036,.166),(0,-.35,0),'leatherlight',bevel=.007)
    waist=s.pivot('Waist',(0,1.05,0))
    for part in (body,head,left,right): s.reparent(part,waist)
    hammer=s.joint('Hammer',(.39,-.19,-.09),waist)
    s.r(hammer,(0,-.18,0),(0,.42,0),.033,'woodlight',8)
    s.r(hammer,(0,-.13,0),(0,.12,0),.039,'leather',8)
    s.b(hammer,(.34,.19,.18),(0,.43,0),'darksteel',bevel=.025)
    s.b(hammer,(.058,.177,.168),(-.15,.43,0),'steel',bevel=.009)
    s.b(hammer,(.048,.16,.16),(.15,.43,0),'edge',bevel=.008)
    s.b(hammer,(.045,.023,.08),(0,.536,0),'woodlight',bevel=.003)
    return s


def engineer_action(s, repair):
    duration=1.0 if repair else .72
    times=[0,.25,.53,.77,.94,1] if repair else [0,.12,.22,.30,.40,.72]
    positions=[(.33,-.02,-.33),(.34,.14,-.29),(.29,.31,-.19),(.29,.23,-.22),(.32,.0,-.35),(.33,-.02,-.33)]
    rotations=[(-1.2,0,-.1),(-.35,0,-.15),(.25,0,-.15),(-.05,0,-.12),(-1.1,0,-.10),(-1.2,0,-.1)]
    if not repair:
        positions=[(.39,-.19,-.09),(.34,.20,-.22),(.30,.28,-.22),(.31,.01,-.37),(.33,-.06,-.31),(.39,-.19,-.09)]
        rotations=[(0,0,0),(.2,0,-.15),(.25,0,-.14),(-1.25,0,-.1),(-.95,0,-.08),(0,0,0)]
    path=lambda part,prop:s.part_path(part)+':'+prop
    tracks=[(path('Hammer','position'),positions,times),(path('Hammer','rotation'),rotations,times)]
    for side in ('Left','Right'):
        shoulders=[]; forearms=[]
        for position in positions:
            target=position if side=='Right' else (-.22,-.05,-.30)
            shoulder,forearm=farmer_arm_pose(s,side,target)
            shoulders.append(shoulder);forearms.append(forearm)
        tracks.extend([(path('Arm'+side,'rotation'),shoulders,times),(path('Forearm'+side,'rotation'),forearms,times)])
    tracks += [(path('Waist','rotation'),[(.07,0,0)]*6 if repair else [(0,0,0),(.08,0,0),(.10,0,0),(.18,0,0),(.12,0,0),(0,0,0)],times),
               (path('Head','rotation'),[(.10,0,0)]*6 if repair else [(0,0,0)]*6,times),
               ('Rig:position',[(0,0,0)]*6,times)]
    for part in ('LegLeft','LegRight'): tracks.append((path(part,'rotation'),[(0,0,0)]*6,times))
    return duration,tracks


def write_engineer_scene(s):
    parts=list(s.parts)
    lines=[f'[gd_scene load_steps={len(parts)+8} format=3]', '[ext_resource type="Script" path="res://scripts/unit_visual.gd" id="1_script"]']
    for i,p in enumerate(parts): lines.append(f'[ext_resource type="ArrayMesh" path="res://assets/models/units/engineer/{p}.res" id="{i+2}_{p}"]')
    path=lambda part,prop:s.part_path(part)+':'+prop
    idle=[];walk=[]
    for part,sign in (('LegLeft',1),('LegRight',-1)):
        idle.append((path(part,'rotation'),[(0,0,0)]*2))
        walk.append((path(part,'rotation'),[(sign*a,0,0) for a in (0,.46,0,-.46,0)]))
    for side in ('Left','Right'):
        shoulder,forearm=farmer_arm_pose(s,side,(.39,-.19,-.09) if side=='Right' else (-.39,-.19,-.09))
        for part,pose in (('Arm'+side,shoulder),('Forearm'+side,forearm)):
            idle.append((path(part,'rotation'),[pose]*2));walk.append((path(part,'rotation'),[pose]*2))
    for tracks in (idle,walk):
        for part in ('Waist','Head'): tracks.append((path(part,'rotation'),[(0,0,0)]*2))
        tracks += [(path('Hammer','position'),[(.39,-.19,-.09)]*2),(path('Hammer','rotation'),[(0,0,0)]*2)]
    idle.append(('Rig:position',[(0,0,0),(0,.012,0),(0,0,0)]))
    walk.append(('Rig:position',[(0,y,0) for y in (0,.035,0,.035,0)]))
    repair_t,repair=engineer_action(s,True);strike_t,strike=engineer_action(s,False)
    lines += [anim_resource('idle',2.6,idle,True),anim_resource('walk',.76,walk,True),anim_resource('repair',repair_t,repair,True),anim_resource('strike',strike_t,strike),
        '[sub_resource type="AnimationLibrary" id="AnimationLibrary_locomotion"]\n_data = {&"idle": SubResource("Animation_idle"), &"walk": SubResource("Animation_walk")}',
        '[sub_resource type="AnimationLibrary" id="AnimationLibrary_attack"]\n_data = {&"strike": SubResource("Animation_strike"), &"repair": SubResource("Animation_repair")}',
        '[node name="Engineer" type="Node3D"]\nscript = ExtResource("1_script")\nkind = "engineer"\nprojectile_socket = NodePath("Rig/Action/Waist/Hammer/ToolContact")',
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
    lines += ['[node name="ToolContact" type="Marker3D" parent="Rig/Action/Waist/Hammer"]\nposition = Vector3(0,0.43,-0.1)',
        '[node name="Locomotion" type="AnimationPlayer" parent="."]\ncallback_mode_process = 0\nlibraries = {&"": SubResource("AnimationLibrary_locomotion")}\nautoplay = "idle"',
        '[node name="Attack" type="AnimationPlayer" parent="."]\ncallback_mode_process = 0\nlibraries = {&"": SubResource("AnimationLibrary_attack")}',
        '[node name="VisibilityNotifier" type="VisibleOnScreenNotifier3D" parent="."]\naabb = AABB(-2,-1,-2,4,4,4)',
        '[connection signal="screen_entered" from="VisibilityNotifier" to="." method="_on_screen_entered"]',
        '[connection signal="screen_exited" from="VisibilityNotifier" to="." method="_on_screen_exited"]']
    (OUT/'engineer.tscn').write_text('\n\n'.join(lines)+'\n',encoding='utf-8')
