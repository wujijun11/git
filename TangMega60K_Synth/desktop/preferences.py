"""客户端偏好存储：电脑快捷键写入AppData，避免随机HTTP端口导致重启丢失。

这里只存25个键盘event.code或null；不修改FPGA键位、通信和演奏参数。
"""
import json
import os
from pathlib import Path
import re
import tempfile
import threading

SYMBOLS = {'Comma', 'Period', 'Slash', 'Semicolon', 'Quote', 'BracketLeft', 'BracketRight',
           'Backslash', 'Minus', 'Equal', 'Backquote', 'NumpadAdd', 'NumpadSubtract',
           'NumpadMultiply', 'NumpadDivide', 'NumpadDecimal'}


def validate_bindings(codes):
    if not isinstance(codes, list) or len(codes) != 25:
        raise ValueError('快捷键必须对应25个琴键')
    seen = set()
    for code in codes:
        if code is None:
            continue
        if not isinstance(code, str) or not (re.fullmatch(r'Key[A-Z]|Digit[0-9]|Numpad[0-9]', code) or code in SYMBOLS):
            raise ValueError('不支持的快捷键；Esc和组合键不能分配')
        if code in seen:
            raise ValueError('快捷键重复，请先清除原绑定')
        seen.add(code)
    return codes.copy()


class Preferences:
    def __init__(self, directory=None):
        self.directory = Path(directory) if directory is not None else Path(
            os.environ.get('LOCALAPPDATA', tempfile.gettempdir())) / 'TangNeonStudio/preferences'
        self.path = self.directory / 'keyboard-shortcuts.json'
        self.lock = threading.RLock()

    def load_bindings(self):
        with self.lock:
            if not self.path.exists():
                return {'ok': True, 'codes': None}
            try:
                with self.path.open('rb') as source:
                    data = source.read(16385)
                if len(data) > 16384:
                    raise ValueError('配置文件过大')
                doc = json.loads(data.decode('utf-8'))
                if type(doc.get('version')) is not int or doc['version'] != 1:
                    raise ValueError('不支持的快捷键配置版本')
                return {'ok': True, 'codes': validate_bindings(doc.get('codes'))}
            except (OSError, ValueError, TypeError, AttributeError) as error:
                # 保留损坏原文件；只有用户明确保存时才替换，避免自动覆盖。
                return {'ok': True, 'codes': None, 'warning': '快捷键配置不可用，已使用默认布局：' + str(error)}

    def save_bindings(self, codes):
        codes = validate_bindings(codes)
        with self.lock:
            self.directory.mkdir(parents=True, exist_ok=True)
            temporary = None
            try:
                with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=self.directory,
                                                 prefix='keys-', suffix='.tmp', delete=False) as output:
                    temporary = Path(output.name)
                    json.dump({'version': 1, 'codes': codes}, output, ensure_ascii=False)
                    output.flush()
                    os.fsync(output.fileno())
                temporary.replace(self.path)
            finally:
                if temporary is not None and temporary.exists():
                    temporary.unlink()
        return {'ok': True, 'codes': codes}
