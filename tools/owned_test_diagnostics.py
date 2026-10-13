"""Export only owned test summaries/CKHost crash reports,never user diagnostics."""
from pathlib import Path
import subprocess
import sys


def run(bundle, prefix):
    bundle, prefix = Path(bundle), Path(prefix)
    if not bundle.is_dir():
        return
    summary = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle)],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    prefix.with_suffix('.log').write_bytes(summary.stdout)
    output = prefix.with_name(prefix.name + '-raw')
    result = subprocess.run(['xcrun', 'xcresulttool', 'export', 'diagnostics', '--path', str(bundle),
                             '--output-path', str(output)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    with prefix.with_suffix('.log').open('ab') as log:
        log.write(b'\nOwned diagnostics export:\n' + result.stdout)
        if output.is_dir():
            for path in sorted(output.rglob('*')):
                if not path.is_file():
                    continue
                if path.suffix.lower() in ['.ips', '.crash']:
                    text = path.read_text(errors='replace')
                    if 'CKHost' in text and len(text) <= 2 * 1024 * 1024:
                        log.write(b'\nOWNED CKHost CRASH:\n' + text.encode())
    print('Exported owned test summary/crashes only:', prefix.with_suffix('.log').name)


if __name__ == '__main__':
    run(*sys.argv[1:])
