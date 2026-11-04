#!/usr/bin/env python3
"""Regenerate app-owned Pebrel snapshots from the pinned GPL source excerpts.
No network. Run from repository root: python3 tool/pebrel/generate.py.
Adapted 2026-11-04; see assets/pebrel/NOTICE.md.
"""
import json, re
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
UP = ROOT / 'tool/pebrel/upstream'
src = (UP/'themes.rs').read_text()
lib = (UP/'terminal_excerpt.rs').read_text()
def numbers(text):
    return [int(x, 0) for x in re.findall(r'0x[0-9a-fA-F]+|\b\d+\b', text)]
def hx(values): return '#' + ''.join(f'{v:02X}' for v in values)
def rgb(n): return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
names = re.findall(r'Self::(\w+)', src.split('pub const BUILTIN:')[1].split('];')[0])
assert len(names) == 16
palettes = {}
for name, body in re.findall(r'Self::(\w+) => ReviewedPalette \{(.*?)\n            \}', src, re.S):
    palettes[name] = {key: numbers(value) for key, value in re.findall(r'(\w+): \[([^\]]+)\]', body)}
ansi_src = src.split('let ansi = match name {')[1].split('}.map(rgb)')[0]
ansi = {name: [rgb(n) for n in numbers(body)] for name, body in re.findall(r'ThemeName::(\w+) => \[(.*?)\]', ansi_src, re.S)}
light_fallback = [rgb(n) for n in numbers(re.search(r'_ if palette.is_light => \[(.*?)\]', ansi_src,re.S)[1])]
dark_fallback = [rgb(n) for n in numbers(re.search(r'_ => \[(.*?)\]', ansi_src,re.S)[1])]
light_ansi = [numbers(line.split('//')[0]) for line in lib.split('pub const LIGHT_ANSI:')[1].split('];')[0].splitlines()[1:] if '[' in line]
assert len(light_ansi) == 16
nord = lib.split('Self::Nord => TermTheme {')[1].split('// Nord')[0]
nord_ansi = [numbers(x) for x in re.findall(r'\[([^\[\]]+)\]',nord.split('ansi: [')[1].split('],\n                    cursor:')[0])]
assert len(nord_ansi) == 16
legacy_light={'SilverLight','LimestoneLight','LinenLight'}
light={'BreezeLight','MintLight','SilverLight','NordLight','Paper','LimestoneLight','LinenLight','CatppuccinLatte','GlassLight'}
all_themes=[]
for name in names:
    p=palettes[name]
    canonical={'Paper':'WarmSand','GlassLight':'SlateLight'}.get(name,name)
    label=re.sub(r'(?<=[a-z])(?=[A-Z])',' ',canonical)
    ui={k:hx(p[v]) for k,v in {'shell':'shell','background':'background','foreground':'foreground','muted':'muted','accent':'accent','selection':'selected','line':'line','frame':'frame','error':'red','success':'green','warning':'yellow','info':'blue'}.items()}
    ui['derive']=False
    colors=list(ansi.get(name, light_fallback if name in light else dark_fallback))
    t={'background':hx(p['background']),'foreground':hx(p['foreground']),'cursor':hx(p['accent']),'cursor_text':hx(p['background']),'cursor_stroke':hx(p['accent']),'selection_foreground':hx(p['foreground']),'selection_background':hx(p['shell'])}
    if name in legacy_light:
        colors=list(light_ansi)
        t.update(background='#FFFFFF',foreground='#24292F')
        for k in ['cursor','cursor_text','cursor_stroke','selection_foreground','selection_background']: t[k]=None
    elif name=='Paper':
        for k in ['cursor','cursor_text','cursor_stroke','selection_foreground','selection_background']: t[k]=None
    elif name=='Nord':
        colors=list(nord_ansi)
        t.update(background='#2E3440',foreground='#F1F6FF',cursor='#E5E9F0',cursor_text='#2E3440',cursor_stroke='#88C0D0',selection_foreground='#2E3440',selection_background='#E5E9F0')
    assert len(colors)==16, name
    levels=[0,95,135,175,215,255]
    colors += [[r,g,b] for r in levels for g in levels for b in levels]
    colors += [[8+10*i]*3 for i in range(24)]
    t['palette']=[hx(c) for c in colors]
    definition={'name':label,'base':canonical,'appearance':'light' if name in light else 'dark','terminal':t,'ui':ui,'typography':{**dict.fromkeys(['font_family','font_size','line_height','letter_spacing','font_weight','ui_font_family','ui_font_size']), 'ligatures':True},'layout':{'card':{'radius':0.0,'gutter':0.0,'shadow':False,'divider':1.0},'padding_x':None,'padding_y':None},'effects':dict.fromkeys(['opacity','blur','cursor_shape','background_image','background_media_kind','background_image_opacity','background_image_fit','background_image_alignment','background_image_cover_chrome'])}
    all_themes.append(definition)
(ROOT/'assets/pebrel/catalog.json').write_text(json.dumps({'source_revision':'e4a4c02ebbae8d73ea99b0818708633d004ce4a5','themes':all_themes},indent=2)+'\n')
print(f'Generated {len(all_themes)} Pebrel definitions with independent UI and terminal colors.')
