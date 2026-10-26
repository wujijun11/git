"""曲库业务层：缓存与本地文件分离，界面仅使用随机令牌而非任意下载URL。"""
import hashlib
import io
import secrets
import threading
import zipfile
from collections import OrderedDict
from .mutopia import MutopiaCatalog, download
from .midi_import import inspect_midi, convert
from .recommendations import recommend


class ScoreLibrary:
    def __init__(self, cache_root):
        self.catalog = MutopiaCatalog(cache_root)
        self._items = OrderedDict()
        self._files = OrderedDict()
        self._lock = threading.RLock()

    def _remember(self, storage, value):
        token = secrets.token_hex(16)
        with self._lock:
            storage[token] = value
            while len(storage) > (128 if storage is self._items else 32):
                storage.popitem(last=False)
        return token

    def search(self, query, offset=0):
        result = self.catalog.search(query, offset)
        items = []
        for item in result["items"]:
            items.append({**item, "token": self._remember(self._items, item)})
        return {**result, "items": items}

    def fetch(self, token):
        with self._lock:
            item = self._items.get(token)
        if item is None or not item.get("midiUrl"):
            raise ValueError("曲目已失效或没有MIDI文件，请重新搜索")
        return self.load_bytes(download(item["midiUrl"]), item["title"], item)

    def recommend(self, batch=0, refresh=False):
        result = recommend(self.catalog, batch, refresh)
        return {**result, 'items': [{**item, 'token': self._remember(self._items, item)} for item in result['items']]}

    def load_bytes(self, data, name, attribution=None):
        if len(data) > 4 * 1024 * 1024:
            raise ValueError("MIDI/ZIP文件必须小于4MiB")
        candidates = [(name, data)]
        if data.startswith(b"PK"):
            candidates = []
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                names = [entry for entry in archive.infolist() if entry.filename.lower().endswith((".mid", ".midi"))]
                if not names or len(names) > 32 or sum(entry.file_size for entry in names) > 4 * 1024 * 1024:
                    raise ValueError("ZIP应含1–32个MIDI，解压总量不超过4MiB")
                for entry in names:
                    # 只从内存读取，不按ZIP中的路径写入本机文件。
                    with archive.open(entry) as stream:
                        content = stream.read(4 * 1024 * 1024 + 1)
                    if len(content) > 4 * 1024 * 1024:
                        raise ValueError("解压MIDI超过大小限制")
                    candidates.append((entry.filename, content))
        files = []
        for filename, content in candidates:
            info, _ = inspect_midi(content)
            credit = {**(attribution or {}), "file": filename, "sha256": hashlib.sha256(content).hexdigest()}
            token = self._remember(self._files, (content, filename, credit))
            files.append({**info, "token": token, "name": filename, "attribution": credit})
        return {"files": files}

    def prepare(self, token, options):
        with self._lock:
            entry = self._files.get(token)
        if entry is None:
            raise ValueError("MIDI预览已失效，请重新打开曲目")
        content, title, attribution = entry
        return convert(content, title, options, attribution)
