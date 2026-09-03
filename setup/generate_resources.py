from pathlib import Path
import os
import re
import struct

ROOT = Path(__file__).resolve().parent
ICO = ROOT / 'payload' / 'Wallhaven-Rotator.ico'
MANIFEST = ROOT / 'app.manifest'
OUT = ROOT / 'resources_amd64.syso'

VERSION = os.environ.get('WALLHAVEN_VERSION', '1.0.1').strip()
if not re.fullmatch(r'\d+\.\d+\.\d+', VERSION):
    raise SystemExit(f'Invalid WALLHAVEN_VERSION: {VERSION!r}')
MAJOR, MINOR, PATCH = map(int, VERSION.split('.'))
FILE_VERSION = f'{VERSION}.0'
ORIGINAL_FILENAME = f'WallhavenRotator-Setup-v{VERSION}.exe'


def u16z(s):
    return s.encode('utf-16le') + b'\x00\x00'


def align4(buf):
    while len(buf) % 4:
        buf.append(0)


def align(n, a=4):
    return (n + a - 1) & ~(a - 1)


def block(key, value=b'', value_len=0, typ=1, children=()):
    b = bytearray(b'\x00' * 6)
    b += u16z(key)
    align4(b)
    b += value
    align4(b)
    for child in children:
        b += child
        align4(b)
    struct.pack_into('<HHH', b, 0, len(b), value_len, typ)
    return bytes(b)


ico = ICO.read_bytes()
reserved, icon_type, count = struct.unpack_from('<HHH', ico, 0)
assert (reserved, icon_type) == (0, 1)
icons = []
for i in range(count):
    p = 6 + i * 16
    w, h, colors, rsv, planes, bpp, size, off = struct.unpack_from('<BBBBHHII', ico, p)
    icons.append(dict(id=i + 1, w=w, h=h, colors=colors, rsv=rsv,
                      planes=planes, bpp=bpp, size=size, data=ico[off:off + size]))

strings = {
    'CompanyName': 'Wallhaven Rotator Project',
    'FileDescription': 'Wallhaven Rotator Setup',
    'FileVersion': FILE_VERSION,
    'InternalName': 'WallhavenRotatorSetup',
    'LegalCopyright': 'Copyright 2026',
    'OriginalFilename': ORIGINAL_FILENAME,
    'ProductName': 'Wallhaven Rotator',
    'ProductVersion': VERSION,
}
string_blocks = [block(k, u16z(v), len(v) + 1, 1) for k, v in strings.items()]
string_table = block('040904B0', children=string_blocks)
string_info = block('StringFileInfo', children=[string_table])
translation = block('Translation', struct.pack('<HH', 0x0409, 1200), 4, 0)
var_info = block('VarFileInfo', children=[translation])
fixed = struct.pack('<13I',
    0xFEEF04BD, 0x00010000,
    (MAJOR << 16) | MINOR, (PATCH << 16),
    (MAJOR << 16) | MINOR, (PATCH << 16),
    0x3F, 0,
    0x00040004, 1, 0, 0, 0)
version = block('VS_VERSION_INFO', fixed, len(fixed), 0, [string_info, var_info])
manifest = MANIFEST.read_bytes()

group = bytearray(struct.pack('<HHH', 0, 1, len(icons)))
for ic in icons:
    group += struct.pack('<BBBBHHIH', ic['w'], ic['h'], ic['colors'], ic['rsv'],
                         ic['planes'], ic['bpp'], ic['size'], ic['id'])

types = [3, 14, 16, 24]
cursor = 16 + 8 * len(types)
icon_type_off = cursor; cursor += 16 + 8 * len(icons)
icon_name_dirs = []
for _ in icons:
    icon_name_dirs.append(cursor); cursor += 24
group_type_off = cursor; cursor += 24
group_name_off = cursor; cursor += 24
version_type_off = cursor; cursor += 24
version_name_off = cursor; cursor += 24
manifest_type_off = cursor; cursor += 24
manifest_name_off = cursor; cursor += 24
icon_entries = []
for _ in icons:
    icon_entries.append(cursor); cursor += 16
group_entry = cursor; cursor += 16
version_entry = cursor; cursor += 16
manifest_entry = cursor; cursor += 16
cursor = align(cursor)

data_items = []
for idx, ic in enumerate(icons):
    cursor = align(cursor)
    data_items.append((icon_entries[idx], cursor, ic['data']))
    cursor += len(ic['data'])
cursor = align(cursor); data_items.append((group_entry, cursor, bytes(group))); cursor += len(group)
cursor = align(cursor); data_items.append((version_entry, cursor, version)); cursor += len(version)
cursor = align(cursor); data_items.append((manifest_entry, cursor, manifest)); cursor += len(manifest)
raw_size = align(cursor)
sec = bytearray(raw_size)


def dirhdr(off, ids):
    struct.pack_into('<IIHHHH', sec, off, 0, 0, 0, 0, 0, ids)


def entry(off, ident, target, is_dir):
    struct.pack_into('<II', sec, off, ident, target | (0x80000000 if is_dir else 0))


dirhdr(0, 4)
for i, (tid, target) in enumerate([(3, icon_type_off), (14, group_type_off),
                                   (16, version_type_off), (24, manifest_type_off)]):
    entry(16 + i * 8, tid, target, True)

dirhdr(icon_type_off, len(icons))
for idx, ic in enumerate(icons):
    entry(icon_type_off + 16 + idx * 8, ic['id'], icon_name_dirs[idx], True)
    dirhdr(icon_name_dirs[idx], 1)
    entry(icon_name_dirs[idx] + 16, 0x0409, icon_entries[idx], False)

for type_off, name_off, data_entry in [
    (group_type_off, group_name_off, group_entry),
    (version_type_off, version_name_off, version_entry),
    (manifest_type_off, manifest_name_off, manifest_entry),
]:
    dirhdr(type_off, 1); entry(type_off + 16, 1, name_off, True)
    dirhdr(name_off, 1); entry(name_off + 16, 0x0409, data_entry, False)

relocs = []
for data_entry, data_off, data in data_items:
    struct.pack_into('<IIII', sec, data_entry, data_off, len(data), 0, 0)
    relocs.append(data_entry)
    sec[data_off:data_off + len(data)] = data

raw_ptr = 20 + 40
reloc_ptr = raw_ptr + raw_size
symbol_ptr = reloc_ptr + 10 * len(relocs)
name = b'.rsrc\x00\x00\x00'
coff = bytearray(struct.pack('<HHIIIHH', 0x8664, 1, 0, symbol_ptr, 1, 0, 0x0004))
coff += struct.pack('<8sIIIIIIHHI', name, 0, 0, raw_size, raw_ptr, reloc_ptr, 0,
                    len(relocs), 0, 0xC0300040)
coff += sec
for va in relocs:
    coff += struct.pack('<IIH', va, 0, 3)
coff += struct.pack('<8sIhHBB', name, 0, 1, 0, 3, 0)
coff += struct.pack('<I', 4)
OUT.write_bytes(coff)
print(f'generated {OUT.name}: {len(coff)} bytes, {len(relocs)} relocations; version={VERSION}')
