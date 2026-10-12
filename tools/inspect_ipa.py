"""Read-only structural inspection. Never print stream URLs or key material."""
import argparse
import hashlib
import json
import plistlib
import re
import struct
import zipfile


def inspect(path):
    with zipfile.ZipFile(path) as archive:
        root = next(n.rsplit('/', 1)[0] for n in archive.namelist()
                    if re.fullmatch(r'Payload/[^/]+/Info.plist', n))
        info = plistlib.loads(archive.read(root + '/Info.plist'))
        binary = archive.read(root + '/' + info['CFBundleExecutable'])
    if binary[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected little-endian thin Mach-O 64-bit')
    commands, command_bytes = struct.unpack_from('<II', binary, 16)
    cursor = 32
    first_section = len(binary)
    libraries, encryption, symtab = [], [], None
    for _ in range(commands):
        cmd, size = struct.unpack_from('<II', binary, cursor)
        if size < 8 or cursor + size > len(binary):
            raise ValueError('Invalid load command')
        if cmd in (0xc, 0x80000018, 0x8000001f):
            offset, = struct.unpack_from('<I', binary, cursor + 8)
            libraries.append(binary[cursor + offset:cursor + size].split(b'\0')[0].decode())
        if cmd == 0x2c:
            encryption.append(struct.unpack_from('<III', binary, cursor + 8)[2])
        if cmd == 0x19:
            sections, = struct.unpack_from('<I', binary, cursor + 64)
            for i in range(sections):
                offset, = struct.unpack_from('<I', binary, cursor + 72 + i * 80 + 48)
                if offset:
                    first_section = min(first_section, offset)
        if cmd == 2:
            symtab = struct.unpack_from('<IIII', binary, cursor + 8)
        cursor += size
    symbols = []
    if symtab:
        _, _, offset, length = symtab
        strings = binary[offset:offset + length].split(b'\0')
        symbols = sorted(set(s.decode('utf8', 'ignore') for s in strings
                             if re.search(rb'AVPlayer|AVURLAsset|VideoPlayer|PlayerView|M3U|DRM|ClearKey', s)))
    print(json.dumps({
        'app': info.get('CFBundleDisplayName'), 'bundle': info.get('CFBundleIdentifier'),
        'version': info.get('CFBundleShortVersionString'), 'minimumOS': info.get('MinimumOSVersion'),
        'binary_sha256': hashlib.sha256(binary).hexdigest(), 'crypt_ids': encryption,
        'header_slack': first_section - 32 - command_bytes,
        'libraries': libraries, 'player_symbols': symbols[:75]
    }, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('ipa')
    inspect(parser.parse_args().ipa)
