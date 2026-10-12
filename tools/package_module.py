import hashlib
import json
from pathlib import Path
import shutil
import sys


def package(products, output):
    products, output = Path(products), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    framework = products / 'CKBridge.framework'
    if not framework.is_dir():
        raise RuntimeError('Compiled CKBridge framework is missing')
    shutil.copytree(framework, output / framework.name, dirs_exist_ok=True)
    notice = output / 'CKBridge.framework/THIRD_PARTY'
    notice.mkdir(exist_ok=True)
    license = Path('build/ffmpeg-lgpl/output/device/LICENSE.LGPLv2.1')
    shutil.copy2(license, notice / 'FFmpeg-LGPLv2.1.txt')
    (notice / 'SOURCE.txt').write_text(
        'FFmpeg6.1 official source SHA256:488c76e57dd9b3bee901f71d5c95eaf1db4a5a31fe46a28654e837144207c270\n'
        'Source:https://ffmpeg.org/releases/ffmpeg-6.1.tar.xz\n'
        'Configuration:tools/build_lgpl_core.py in this bridge source repository.\n'
        'KSPlayer LGPL2.1 source:https://github.com/kingslay/KSPlayer/tree/3558c7645240a191c3e4672eabe7b6ae1ee4f4ae\n'
        'FFmpegKit Swift wrapper:https://github.com/kingslay/FFmpegKit/tree/6.1.0\n'
        'Bridge sources/relinking instructions:https://github.com/bjenki33/monplayer-clearkey-lab\n')
    for bundle in products.glob('*.bundle'):
        shutil.copytree(bundle, output / bundle.name, dirs_exist_ok=True)
    # SPM may link libraries statically or copy dynamic XCFramework products.
    for framework in products.rglob('*.framework'):
        if framework.name == 'CKBridge.framework' or framework.parent.name.endswith('.framework'):
            continue
        binary = framework / framework.stem
        if not binary.exists():
            continue
        data = binary.read_bytes()
        if data[:4] == b'\xcf\xfa\xed\xfe' and int.from_bytes(data[12:16], 'little') == 6:
            shutil.copytree(framework, output / framework.name, dirs_exist_ok=True)
    files = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in output.rglob('*') if p.is_file()}
    (output / 'SHA256.json').write_text(json.dumps(files, indent=2))
    print(f'Packaged {len(files)} module files. No IPA or user data included.')


if __name__ == '__main__':
    package(*sys.argv[1:])
