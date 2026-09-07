"""Author the editable Godot UI and initial battle scene. No runtime node generation."""
from pathlib import Path
import json
import math
from build_navigation import build as build_navigation

ROOT = Path(__file__).resolve().parents[1]
SCENES = ROOT / 'scenes'
SCENES.mkdir(exist_ok=True)
(ROOT / 'artifacts').mkdir(exist_ok=True)

def q(text):
    return json.dumps(text, ensure_ascii=False)

class Scene:
    def __init__(self):
        self.resources = []
        self.nodes = []
    def ext(self, type, path, id):
        self.resources.append(f'[ext_resource type="{type}" path="res://{path}" id="{id}"]')
    def sub(self, type, id, **props):
        self.resources.append(f'[sub_resource type="{type}" id="{id}"]\n' + '\n'.join(f'{k} = {v}' for k, v in props.items()))
    def node(self, name, type, parent=None, **props):
        header = f'[node name="{name}" type="{type}"'
        if parent is not None: header += f' parent="{parent}"'
        header += ']'
        self.nodes.append(header + '\n' + '\n'.join(f'{k} = {v}' for k, v in props.items()))
    def instance(self, name, parent, id, **props):
        self.nodes.append(f'[node name="{name}" parent="{parent}" instance=ExtResource("{id}")]\n' + '\n'.join(f'{k} = {v}' for k, v in props.items()))
    def save(self, name):
        (SCENES / name).write_text('[gd_scene load_steps=%d format=3]\n\n' % (len(self.resources)+1) + '\n\n'.join(self.resources+self.nodes) + '\n', encoding='utf-8')

def rect(x,y,w,h, anchor_bottom=False, anchor_right=False):
    p = {'layout_mode':'0','offset_left':str(x),'offset_top':str(y),'offset_right':str(x+w),'offset_bottom':str(y+h)}
    if anchor_bottom: p.update(anchor_top='1.0',anchor_bottom='1.0',grow_vertical='0')
    if anchor_right: p.update(anchor_left='1.0',anchor_right='1.0',grow_horizontal='0')
    return p

s=Scene()
s.ext('Script','scripts/hud.gd','hud')
s.ext('Script','scripts/minimap.gd','minimap')
s.ext('PackedScene','scenes/model_previews.tscn','previews')
s.sub('SystemFont','font',font_names='PackedStringArray("Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC")',font_weight='500')
s.sub('SystemFont','bold',font_names='PackedStringArray("Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC")',font_weight='700')
for id, bg, border in [('panel','Color(0.075,0.085,0.085,0.96)','Color(0.40,0.34,0.23,0.9)'),('normal','Color(0.15,0.155,0.145,0.96)','Color(0.40,0.36,0.27,0.7)'),('hover','Color(0.25,0.245,0.18,1)','Color(0.8,0.65,0.36,1)'),('pressed','Color(0.34,0.28,0.16,1)','Color(0.92,0.77,0.43,1)'),('disabled','Color(0.105,0.115,0.11,0.95)','Color(0.27,0.28,0.23,0.8)')]:
    s.sub('StyleBoxFlat',id,bg_color=bg,border_color=border,border_width_left='1',border_width_top='1',border_width_right='1',border_width_bottom='1',corner_radius_top_left='3',corner_radius_top_right='3',corner_radius_bottom_left='3',corner_radius_bottom_right='3',content_margin_left='8.0',content_margin_right='8.0')
s.sub('StyleBoxFlat','hp_bg',bg_color='Color(0.055,0.065,0.06,1)',corner_radius_top_left='2',corner_radius_top_right='2',corner_radius_bottom_left='2',corner_radius_bottom_right='2')
s.sub('StyleBoxFlat','hp_fg',bg_color='Color(0.49,0.65,0.40,1)',corner_radius_top_left='2',corner_radius_top_right='2',corner_radius_bottom_left='2',corner_radius_bottom_right='2')
s.sub('Theme','theme',default_font='SubResource("font")',default_font_size='15',**{'Button/colors/font_color':'Color(0.9,0.88,0.79,1)','Button/colors/font_hover_color':'Color(1,0.94,0.74,1)','Button/colors/font_disabled_color':'Color(0.43,0.46,0.44,1)','Button/styles/normal':'SubResource("normal")','Button/styles/hover':'SubResource("hover")','Button/styles/pressed':'SubResource("pressed")','Button/styles/disabled':'SubResource("disabled")','Button/styles/focus':'SubResource("hover")','Label/colors/font_color':'Color(0.90,0.90,0.84,1)','Label/colors/font_shadow_color':'Color(0.04,0.04,0.035,0.8)','Label/constants/shadow_offset_x':'1','Label/constants/shadow_offset_y':'1','Panel/styles/panel':'SubResource("panel")','ProgressBar/styles/background':'SubResource("hp_bg")','ProgressBar/styles/fill':'SubResource("hp_fg")','TooltipPanel/styles/panel':'SubResource("panel")','TooltipLabel/colors/font_color':'Color(0.94,0.91,0.79,1)'})
s.node('Interface','Control',None,layout_mode='3',anchors_preset='15',anchor_right='1.0',anchor_bottom='1.0',grow_horizontal='2',grow_vertical='2',mouse_filter='2',theme='SubResource("theme")',script='ExtResource("hud")',process_mode='3')
s.instance('ModelPreviews','.','previews')

def label(name,parent,text,x,y,w,h,font_size=15,color=None,bold=False,unique=False,**kwargs):
    props=rect(x,y,w,h)
    props.update(text=q(text),mouse_filter='2',vertical_alignment='1',**{'theme_override_font_sizes/font_size':str(font_size)})
    if bold: props['theme_override_fonts/font']='SubResource("bold")'
    if color: props['theme_override_colors/font_color']=color
    if unique: props['unique_name_in_owner']='true'
    props.update(kwargs)
    s.node(name,'Label',parent,**props)

def button(name,parent,text,x,y,w,h,**kwargs):
    props=rect(x,y,w,h)
    props.update(text=q(text),unique_name_in_owner='true',focus_mode='0')
    props.update(kwargs)
    s.node(name,'Button',parent,**props)

# A light upper HUD floats over the game, keeping almost all screen real estate for 3D.
s.node('TopLeft','Control','.',**rect(28,22,420,120),mouse_filter='2')
label('Eyebrow','TopLeft','ASHEN CROWN  /  边境战役',0,0,400,20,11,'Color(0.92,0.81,0.56,1)')
label('Title','TopLeft','灰烬王国',0,21,340,42,31,bold=True)
label('Location','TopLeft','第一章   ·   沙石镇',1,66,340,24,13,'Color(0.84,0.82,0.72,1)')
label('Objective','TopLeft','摧毁敌方军事建筑  0 / 4',0,103,390,26,16,unique=True)
label('EnemyCount','TopLeft','敌军 30    击败 0',0,133,330,22,12,'Color(0.82,0.79,0.66,1)',unique=True)
s.node('Resources','Panel','.',**rect(-364,24,340,76,anchor_right=True))
label('GoldCaption','Resources','◈  金币',18,8,130,22,12,'Color(0.87,0.74,0.45,1)')
label('GoldValue','Resources','320',18,29,128,36,28,'Color(1,0.86,0.53,1)',True,True)
label('Income','Resources','+1 / 秒',104,41,75,21,11,'Color(0.69,0.66,0.51,1)')
label('ArmyCaption','Resources','军队',204,8,115,22,12,'Color(0.67,0.77,0.8,1)')
label('ArmyValue','Resources','16 / 160',202,34,130,26,19,unique=True)
label('TimeValue','.','00:00',-240,108,76,24,13,'Color(0.84,0.81,0.70,1)',unique=True,anchor_left='1.0',anchor_right='1.0')
button('HelpButton','.','?  操作',-153,108,75,30,anchor_left='1.0',anchor_right='1.0')
button('PauseButton','.','Ⅱ',-68,108,44,30,anchor_left='1.0',anchor_right='1.0')

# Lower command surface.
s.node('CommandBar','Panel','.',layout_mode='0',anchor_top='1.0',anchor_bottom='1.0',anchor_right='1.0',offset_left='238.0',offset_top='-180.0',offset_right='-24.0',offset_bottom='-22.0',grow_vertical='0')
s.node('MapFrame','Panel','.',**rect(24,-226,196,204,anchor_bottom=True))
label('MapTitle','MapFrame','沙石镇',12,6,170,24,12,'Color(0.8,0.77,0.63,1)')
s.node('Minimap','Control','MapFrame',**rect(11,32,174,160),script='ExtResource("minimap")',unique_name_in_owner='true',clip_contents='true',mouse_default_cursor_shape='2')

s.node('Selection','Control','CommandBar',**rect(16,13,300,136),mouse_filter='2')
label('SelectionCaption','CommandBar','所选部队',16,-28,180,24,12,'Color(0.91,0.85,0.69,1)')
s.node('SelectedPortrait','TextureRect','CommandBar/Selection',**rect(0,5,94,112),expand_mode='1',stretch_mode='5',mouse_filter='2',unique_name_in_owner='true')
label('SelectedRole','CommandBar/Selection','蓝旗军团',107,0,190,20,10,'Color(0.53,0.72,0.84,1)',unique=True)
label('SelectedName','CommandBar/Selection','大本营',106,21,190,26,20,bold=True,unique=True)
s.node('SelectionHP','ProgressBar','CommandBar/Selection',**rect(108,58,174,7),show_percentage='false',value='100.0',unique_name_in_owner='true')
label('SelectionHPText','CommandBar/Selection','2200 / 2200',108,68,174,18,10,'Color(0.72,0.77,0.62,1)',unique=True)
label('SelectedStats','CommandBar/Selection','每秒 +1 金币\n右键设置集结点',108,91,186,40,11,'Color(0.72,0.74,0.7,1)',unique=True,autowrap_mode='2')
s.node('Separator1','ColorRect','CommandBar',**rect(323,17,1,124),color='Color(0.45,0.39,0.27,0.55)',mouse_filter='2')
s.node('Recruitment','Control','CommandBar',**rect(342,0,566,156),mouse_filter='2')
label('RecruitTitle','CommandBar/Recruitment','即时招募',0,-28,180,24,12,'Color(0.91,0.85,0.69,1)')
label('RecruitHint','CommandBar/Recruitment','消耗金币 · 即刻出兵',318,-28,224,24,11,'Color(0.80,0.76,0.63,1)',unique=True,horizontal_alignment='2')
for index, (name, hotkey, cost) in enumerate(zip(['剑士','弓箭手','骑士','投石车','加农炮'],['Q','E','R','T','Y'],[45,60,100,140,180])):
    path='CommandBar/Recruitment/Recruit'+str(index)
    button('Recruit'+str(index),'CommandBar/Recruitment','',index*111,12,101,130)
    s.node('Portrait','TextureRect',path,**rect(4,4,93,82),expand_mode='1',stretch_mode='5',mouse_filter='2')
    label('Hotkey',path,hotkey,8,4,22,20,10,'Color(0.75,0.78,0.72,1)')
    label('Name',path,name,4,83,93,23,13,bold=True,horizontal_alignment='1')
    label('Cost',path,'◈ '+str(cost),4,105,93,19,12,'Color(0.92,0.79,0.49,1)',horizontal_alignment='1')
s.node('Separator2','ColorRect','CommandBar',**rect(906,17,1,124),color='Color(0.45,0.39,0.27,0.55)',mouse_filter='2')
s.node('Orders','Control','CommandBar',layout_mode='0',anchor_right='1.0',offset_left='926.0',offset_top='0.0',offset_right='-16.0',offset_bottom='150.0',mouse_filter='2')
label('OrdersCaption','CommandBar/Orders','战场指令',0,-28,160,24,12,'Color(0.91,0.85,0.69,1)')
button('AttackButton','CommandBar/Orders','攻击前进  A',0,16,122,42,toggle_mode='true')
button('StopButton','CommandBar/Orders','停止  S',134,16,105,42)
button('HoldButton','CommandBar/Orders','坚守  H',0,68,122,34)
button('BaseButton','CommandBar/Orders','大本营  B',134,68,105,34)
button('ArmyButton','CommandBar/Orders','选择全部军队  G',0,112,239,29,**{'theme_override_font_sizes/font_size':'11'})

s.node('Groups','Control','.',layout_mode='0',anchor_top='1.0',anchor_bottom='1.0',offset_left='240.0',offset_top='-254.0',offset_right='1050.0',offset_bottom='-218.0',mouse_filter='2')
for index in range(1,10):
    button('Group'+str(index),'Groups',str(index),(index-1)*66,0,57,29,**{'theme_override_font_sizes/font_size':'12'})
label('GroupHint','Groups','Ctrl + 数字  建队    Shift + 数字  追加',609,0,290,29,11,'Color(0.81,0.78,0.65,1)')
label('BottomHint','.','框选部队    右键移动 / 攻击    中键拖动视角    滚轮缩放    F1 操作说明',0,-20,1600,18,10,'Color(0.76,0.75,0.67,0.85)',anchor_top='1.0',anchor_bottom='1.0',anchor_right='1.0',offset_right='0.0',horizontal_alignment='1')
label('Toast','.','集结军队，夺回沙石镇',-360,164,720,38,17,'Color(1.0,0.91,0.68,1)',unique=True,anchor_left='0.5',anchor_right='0.5',horizontal_alignment='1')

def overlay(name):
    s.node(name,'ColorRect','.',anchors_preset='15',anchor_right='1.0',anchor_bottom='1.0',grow_horizontal='2',grow_vertical='2',color='Color(0.025,0.035,0.035,0.72)',visible='false',unique_name_in_owner='true',mouse_filter='0')

overlay('HelpOverlay')
s.node('Paper','Panel','HelpOverlay',layout_mode='0',anchor_left='0.5',anchor_right='0.5',anchor_top='0.5',anchor_bottom='0.5',offset_left='-365',offset_top='-298',offset_right='365',offset_bottom='298')
label('Eyebrow','HelpOverlay/Paper','FIELD MANUAL   /   战地手册',34,25,650,25,12,'Color(0.82,0.69,0.44,1)')
label('Title','HelpOverlay/Paper','指挥你的军队',34,62,650,42,30,bold=True)
label('Intro','HelpOverlay/Paper','摧毁四座敌方军事建筑，保卫你的大本营。',34,118,650,30,15)
left='左键 / 拖动\nShift + 左键 / 框选\n双击单位\n右键 / Shift + 右键\nA + 左键 / S / H\nCtrl + 1—9\nShift + 1—9\n1—9 / 双按数字\n屏幕边缘 / 中键 / 方向键\n滚轮 / 空格\nB / G\nF12 / F10\nF11 / M'
right='选择 / 框选部队\n追加或取消选择\n选择视野内同类单位\n移动或攻击 / 追加路线；大本营设集结点\n攻击前进 / 停止 / 坚守\n建立或覆盖编队\n将所选部队追加到编队\n召回编队 / 镜头定位\n移动镜头（四角可斜向移动）\n缩放 / 定位所选部队\n大本营 / 全部军队\n调试金币 +100 / 隐藏界面\n全屏切换 / 静音切换'
label('Keys','HelpOverlay/Paper',left,38,169,245,331,14,'Color(0.88,0.76,0.50,1)',**{'theme_override_constants/line_spacing':'7'})
label('Actions','HelpOverlay/Paper',right,283,169,417,331,14,**{'theme_override_constants/line_spacing':'7'})
label('Economy','HelpOverlay/Paper','每秒自动获得 1 金币 · 选中大本营即可即时招募 · 摧毁敌方建筑获得战利品',36,523,670,28,11,'Color(0.65,0.70,0.65,1)')
button('CloseHelp','HelpOverlay/Paper','返回战场',529,554,166,31)

overlay('PauseOverlay')
s.node('Paper','Panel','PauseOverlay',layout_mode='0',anchor_left='0.5',anchor_right='0.5',anchor_top='0.5',anchor_bottom='0.5',offset_left='-240',offset_top='-160',offset_right='240',offset_bottom='160')
label('Eyebrow','PauseOverlay/Paper','ASHEN CROWN',32,25,416,24,12,'Color(0.82,0.69,0.44,1)',horizontal_alignment='1')
label('Title','PauseOverlay/Paper','战斗已暂停',32,74,416,46,29,bold=True,horizontal_alignment='1')
button('ResumeButton','PauseOverlay/Paper','继续战斗  [Esc]',54,169,372,44)
button('RestartButton','PauseOverlay/Paper','重新开始',54,230,372,40)

overlay('ResultOverlay')
s.node('Paper','Panel','ResultOverlay',layout_mode='0',anchor_left='0.5',anchor_right='0.5',anchor_top='0.5',anchor_bottom='0.5',offset_left='-340',offset_top='-205',offset_right='340',offset_bottom='205')
label('ResultEyebrow','ResultOverlay/Paper','VICTORY  /  胜利',32,39,616,25,14,'Color(0.91,0.76,0.42,1)',unique=True,horizontal_alignment='1')
label('ResultHeading','ResultOverlay/Paper','沙石镇已解放',32,94,616,53,35,bold=True,unique=True,horizontal_alignment='1')
label('ResultBody','ResultOverlay/Paper','蓝旗再次升起。',44,179,592,100,16,unique=True,horizontal_alignment='1')
button('ResultRestart','ResultOverlay/Paper','再次出征',216,323,248,44)
s.save('hud.tscn')

# Authored destructible fortifications; navigation is built after saving their transforms.
buildings=[('Headquarters','headquarters',0,-22,23,9,8),('EnemyKeep','enemy_keep',1,22,-24,9,8),('NorthBarracks','barracks',1,9,-21,6,5),('Watchtower','tower',1,25,-7,4,4),('WestBarracks','barracks',1,-4,-12,6,5)]

m=Scene()
for type,path,id in [('Script','scripts/game.gd','game'),('Script','scripts/rts_camera.gd','camera'),('Script','scripts/selection_overlay.gd','selection'),('PackedScene','scenes/environment.tscn','environment'),('PackedScene','scenes/unit.tscn','unit'),('PackedScene','scenes/building.tscn','building'),('PackedScene','scenes/hud.tscn','hud'),('NavigationMesh','assets/battle_navigation.tres','nav')]:m.ext(type,path,id)
for name,*_ in buildings:m.ext('NavigationMesh',f'assets/navigation/{name}_cleared.tres','patch_'+name)
m.ext('PackedScene','scenes/rally_marker.tscn','rally')
m.ext('PackedScene','scenes/audio.tscn','audio')
m.sub('ProceduralSkyMaterial','sky_material',sky_top_color='Color(0.32,0.41,0.48,1)',sky_horizon_color='Color(0.81,0.73,0.55,1)',ground_bottom_color='Color(0.29,0.25,0.19,1)',ground_horizon_color='Color(0.8,0.72,0.53,1)')
m.sub('Sky','sky',sky_material='SubResource("sky_material")')
m.sub('Environment','world',background_mode='2',sky='SubResource("sky")',ambient_light_source='3',ambient_light_color='Color(0.76,0.81,0.85,1)',ambient_light_energy='0.62',reflected_light_source='2',tonemap_mode='2',**{'ssao_enabled':'true','ssao_radius':'1.7','ssao_intensity':'1.8','ssao_power':'1.5','ssao_detail':'0.5','ssil_enabled':'true','ssil_radius':'3.0','ssil_intensity':'0.4','glow_enabled':'true','glow_intensity':'0.3','glow_bloom':'0.03','fog_enabled':'true','fog_light_color':'Color(0.62,0.52,0.35,1)','fog_light_energy':'0.5','fog_density':'0.0012','adjustment_enabled':'true','adjustment_brightness':'1.0','adjustment_contrast':'1.06','adjustment_saturation':'0.93'})
m.sub('Shader','vignette',code=q('shader_type canvas_item;\nvoid fragment() {\n vec2 d = (UV - vec2(0.5, 0.43)) * vec2(1.12, 1.0);\n float edge = smoothstep(0.31, 0.76, length(d));\n float top = pow(1.0 - UV.y, 5.0) * 0.22;\n COLOR = vec4(0.085, 0.066, 0.047, edge * 0.43 + top);\n}'))
m.sub('ShaderMaterial','vignette_material',shader='SubResource("vignette")')
m.node('AshenCrown','Node3D',None,script='ExtResource("game")')
m.node('WorldEnvironment','WorldEnvironment','.',environment='SubResource("world")')
m.node('Sun','DirectionalLight3D','.',rotation_degrees='Vector3(-54,-31,0)',light_color='Color(1,0.89,0.72,1)',light_energy='1.15',shadow_enabled='true',directional_shadow_max_distance='135.0',shadow_bias='0.06',shadow_normal_bias='2.0',directional_shadow_blend_splits='true',directional_shadow_mode='2',light_angular_distance='1.6')
m.node('CameraRig','Node3D','.',position='Vector3(-12,0,18)',script='ExtResource("camera")')
m.node('Camera3D','Camera3D','CameraRig',position='Vector3(-12.053,42,33.115)',rotation_degrees='Vector3(-50,-20,0)',projection='1',size='31.0',near='0.1',far='220.0',current='true')
m.instance('Environment','.','environment')
m.node('NavigationRegion3D','NavigationRegion3D','.',navigation_mesh='ExtResource("nav")')
m.node('ClearedNavigation','Node3D','.')
for name,*_ in buildings:m.node(name,'NavigationRegion3D','ClearedNavigation',navigation_mesh=f'ExtResource("patch_{name}")',enabled='false')
m.instance('RallyMarker','.','rally',position='Vector3(-10,0,24)')
m.node('Buildings','Node3D','.')
for name,kind,team,x,z,w,d in buildings:m.instance(name,'Buildings','building',position=f'Vector3({x},0,{z})',building_type=q(kind),team=str(team))
m.node('Units','Node3D','.')
starts=[]
for i in range(6):starts.append(('swordsman',0,-9+(i%3)*1.8,12.5+(i//3)*1.8))
for i in range(4):starts.append(('archer',0,-9+(i%2)*1.7,18+(i//2)*1.7))
starts += [('knight',0,-4,16),('knight',0,-2,18),('catapult',0,-14,18),('cannon',0,-12,22)]
for i in range(7):starts.append(('swordsman',1,-1+(i%4)*1.7,-4-(i//4)*1.6))
for i in range(4):starts.append(('archer',1,2+(i%4)*1.6,-9))
for x,z in [(15.5,-15.5),(22.5,-14.5),(23.5,-13.5),(17.5,-17.5),(24.5,-16.5)]:starts.append(('swordsman',1,x,z))
for x,z in [(24.5,-14.5),(25.5,-15.5),(24,-18),(25.5,-18)]:starts.append(('archer',1,x,z))
starts += [('knight',1,12,-13),('knight',1,15,-11),('catapult',1,15,-18),('cannon',1,22,-12),('swordsman',1,-8,-6),('swordsman',1,-10,-5),('archer',1,-10,-10)]
for i,(kind,team,x,z) in enumerate(starts):
    m.instance(('Blue' if team==0 else 'Red')+str(i),'Units','unit',position=f'Vector3({x},0,{z})',unit_type=q(kind),team=str(team),rotation_degrees=f'Vector3(0,{0 if team==0 else 180},0)')
m.node('Effects','Node3D','.')
m.instance('Audio','.','audio')
m.node('IncomeTimer','Timer','.',wait_time='1.0')
m.node('EnemyTimer','Timer','.',wait_time='100.0')
m.node('Atmosphere','CanvasLayer','.',layer='1')
m.node('Vignette','ColorRect','Atmosphere',material='SubResource("vignette_material")',anchors_preset='15',anchor_right='1.0',anchor_bottom='1.0',mouse_filter='2')
m.node('HUD','CanvasLayer','.',layer='10')
m.instance('Interface','HUD','hud')
m.node('SelectionOverlay','Control','HUD',layout_mode='3',anchors_preset='15',anchor_right='1.0',anchor_bottom='1.0',mouse_filter='2',script='ExtResource("selection")')
m.save('main.tscn')
navigation = build_navigation()
print('Authored HUD, main scene and %d navigation polygons.' % navigation['base']['polygons'])
