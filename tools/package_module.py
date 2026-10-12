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
