"""Local-only packaging: preserve the supplied app and all old binary fixes."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import zipfile

BASE_SHA256 = '07764306f533fecb881bdda81555e11ec2630af75a1780883372b4ee0e90f453'
LOAD_PATH = '@rpath/CKBridge.framework/CKBridge'


def add_command(binary, command):
    if binary[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Only the audited thin arm64 Mach-O is supported')
    cpu, = struct.unpack_from('<I', binary, 4)
    if cpu != 0x100000c:
        raise ValueError('Expected arm64')
    count, size = struct.unpack_from('<II', binary, 16)
    cursor, first = 32, len(binary)
    for _ in range(count):
        cmd, length = struct.unpack_from('<II', binary, cursor)
        if length < 8 or cursor + length > 32 + size:
            raise ValueError('Malformed load commands')
        if cmd == 0x2c and struct.unpack_from('<I', binary, cursor + 16)[0] != 0:
            raise ValueError('Encrypted app executable: refuse patch')
        if cmd == 0x19:
            sections, = struct.unpack_from('<I', binary, cursor + 64)
            for i in range(sections):
                offset, = struct.unpack_from('<I', binary, cursor + 72 + i * 80 + 48)
                if offset:
                    first = min(first, offset)
        cursor += length
    if cursor != 32 + size or cursor + len(command) > first:
        raise ValueError('Insufficient verified header padding')
    if any(binary[cursor:cursor + len(command)]):
        raise ValueError('Refuse to overwrite nonzero header padding')
    result = bytearray(binary)
    result[cursor:cursor + len(command)] = command
    struct.pack_into('<II', result, 16, count + 1, size + len(command))
    if result[first:] != binary[first:]:
        raise ValueError('Executable sections changed unexpectedly')
    return bytes(result)


def dylib_command(path):
    name = path.encode() + b'\0'
    size = (24 + len(name) + 7) // 8 * 8
    return struct.pack('<IIIIII', 0xc, size, 24, 0, 0x10000, 0x10000) + name + bytes(size - 24 - len(name))


def package(base, module, output, report):
    base, module, output, report = map(Path, (base, module, output, report))
    digest = hashlib.sha256(base.read_bytes()).hexdigest()
    if digest != BASE_SHA256:
        raise ValueError('Base does not match the previously patched, audited IPA')
    if output.exists() or output.resolve() == base.resolve():
        raise ValueError('Never overwrite an existing artifact or the base IPA')
    hashes = json.loads((module / 'SHA256.json').read_text())
    for name, expected in hashes.items():
        path = (module / name).resolve()
        if module.resolve() not in path.parents or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('Module integrity mismatch or unsafe path')
    if not (module / 'CKBridge.framework/CKBridge').is_file():
        raise ValueError('Missing compiled playback module')
    changed, removed, added = [], [], []
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(base) as old, zipfile.ZipFile(output, 'x', zipfile.ZIP_DEFLATED, compresslevel=6) as new:
        app = 'Payload/MonPlayer.app/'
        for entry in old.infolist():
            name = entry.filename
            if '/_CodeSignature/' in name or name.startswith(app + 'SC_Info/'):
                removed.append(name); continue
            data = old.read(name)
            if name == app + 'MonPlayer':
                data = add_command(data, dylib_command(LOAD_PATH)); changed.append(name)
            elif name == app + 'Info.plist':
                info = plistlib.loads(data)
                info['CFBundleIdentifier'] += '.cktest'
                info['CFBundleDisplayName'] = 'MonPlayer CK TEST'
                info['CFBundleVersion'] = '132001'
                data = plistlib.dumps(info, fmt=plistlib.FMT_BINARY); changed.append(name)
            new.writestr(entry, data)
        for path in sorted(module.rglob('*')):
            if not path.is_file() or path.name == 'SHA256.json' or '_CodeSignature' in path.parts:
                continue
            relative = path.relative_to(module)
            if relative.parts[0].endswith('.framework'):
                name = app + 'Frameworks/' + relative.as_posix()
            elif relative.parts[0].endswith('.bundle'):
                name = app + relative.as_posix()
            else:
                raise ValueError('Unapproved module file: ' + relative.as_posix())
            if name in old.namelist():
                raise ValueError('Module collides with an existing app file')
            item = zipfile.ZipInfo(name)
            item.compress_type = zipfile.ZIP_DEFLATED
            item.external_attr = (0o100755 if path.name == path.parent.stem else 0o100644) << 16
            new.writestr(item, path.read_bytes()); added.append(name)
    with zipfile.ZipFile(base) as old, zipfile.ZipFile(output) as new:
        if new.testzip() is not None:
            raise ValueError('Output ZIP integrity failed')
        for name in old.namelist():
            if name not in changed and name not in removed and old.read(name) != new.read(name):
                raise ValueError('Unrelated app entry changed: ' + name)
    if hashlib.sha256(base.read_bytes()).hexdigest() != digest:
        raise ValueError('Original base was modified')
    result = {'base_sha256': digest, 'output_sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
              'changed': changed, 'removed_signatures': removed, 'added': added,
              'scope': 'unsigned experimental arm64 IPA; physical playback not established'}
    report.write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k not in ('removed_signatures', 'added')}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for field in ('base', 'module', 'output', 'report'):
        parser.add_argument(field)
    package(**vars(parser.parse_args()))
