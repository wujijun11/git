"""准备独立Arduino/ESP32编译工具，不访问串口、不刷写、不改全局SDK。

官方CLI压缩包固定SHA256；核心固定3.3.5，由Arduino CLI核对官方索引中的工具校验值。
工具目录使用英文临时路径，避免Windows编译器对中文路径的兼容问题。
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request
import zipfile

CLI_VERSION = '1.5.1'
CLI_SHA = 'fabe42e0eb04d00e776a66178299ff95a46c623dbc260f997e58fd514853dd40'
CORE = 'esp32:esp32@3.3.5'
INDEX = 'https://espressif.github.io/arduino-esp32/package_esp32_index.json'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tool-root', type=Path,
                        default=Path(tempfile.gettempdir()) / 'TangSynthBleTools_20261025')
    args = parser.parse_args()
    root = args.tool_root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    cli = root / 'arduino-cli.exe'
    archive = root / 'arduino-cli.zip'
    if not archive.exists():
        url = f'https://github.com/arduino/arduino-cli/releases/download/v{CLI_VERSION}/arduino-cli_{CLI_VERSION}_Windows_64bit.zip'
        print('Downloading official Arduino CLI', flush=True)
        with urllib.request.urlopen(url, timeout=60) as response, archive.open('wb') as output:
            while data := response.read(1024 * 1024):
                output.write(data)
    with archive.open('rb') as source:
        if hashlib.file_digest(source, 'sha256').hexdigest() != CLI_SHA:
            raise RuntimeError('Arduino CLI SHA256 mismatch; archive was retained for diagnosis')
    with zipfile.ZipFile(archive) as package:
        cli.write_bytes(package.read('arduino-cli.exe'))
    config = root / 'arduino-cli.yaml'
    settings = {
        'board_manager': {'additional_urls': [INDEX]},
        'directories': {'data': str(root / 'data'), 'downloads': str(root / 'downloads'),
                        'user': str(root / 'user')},
        'updater': {'enable_notification': False},
    }
    # Python读取Windows系统代理，Go程序未必自动读取；沿用相同本机代理。
    proxy = urllib.request.getproxies().get('https') or urllib.request.getproxies().get('http')
    if proxy:
        settings['network'] = {'proxy': proxy, 'connection_timeout': '120s'}
    config.write_text(json.dumps(settings, indent=2), encoding='utf-8')
    common = [str(cli), '--config-file', str(config), '--no-color']
    subprocess.run(common + ['core', 'update-index'], check=True)
    subprocess.run(common + ['core', 'install', CORE], check=True)
    subprocess.run(common + ['core', 'list'], check=True)
    (root / 'tool-manifest.json').write_text(json.dumps({
        'cliVersion': CLI_VERSION, 'cliArchiveSha256': CLI_SHA, 'core': CORE,
        'index': INDEX, 'toolRoot': str(root), 'uploaded': False,
    }, indent=2), encoding='utf-8')
    print('Local toolchain ready:', root, flush=True)


if __name__ == '__main__':
    main()
