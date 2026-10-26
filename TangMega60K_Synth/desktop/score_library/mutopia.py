"""Mutopia公开曲库提供器。保留逐曲授权链接，只下载站内的乐谱数据。"""
import hashlib
import json
import time
import tempfile
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlencode, urljoin, urlsplit
from urllib.request import Request, urlopen, HTTPRedirectHandler, build_opener

BASE = "https://www.mutopiaproject.org/"


def checked_url(url):
    """拒绝本机、其他主机及非HTTP资源，重定向也必须通过同一检查。"""
    part = urlsplit(url)
    if (part.scheme not in ("http", "https") or part.hostname not in
            ("www.mutopiaproject.org", "mutopiaproject.org") or part.port not in (None, 80, 443)
            or part.username or part.password):
        raise ValueError("曲库只允许访问Mutopia官方网站")
    return "https://www.mutopiaproject.org" + part.path + ("?" + part.query if part.query else "")


class _Redirects(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        return super().redirect_request(request, response, code, message, headers, checked_url(url))


def download(url, limit=4 * 1024 * 1024):
    request = Request(checked_url(url), headers={"User-Agent": "TangSynthScoreLibrary/1.1 (educational MIDI client)"})
    with build_opener(_Redirects()).open(request, timeout=20) as response:
        checked_url(response.url)
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("文件超过4MiB限制，请改用较小的本地MIDI文件")
    return data


class ListingParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.depth = 0
        self.cells = []
        self.links = []
        self.cell = None
        self.anchor = None
        self.results = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "table":
            if self.depth or "result-table" in attrs.get("class", "").split():
                self.depth += 1
        if not self.depth:
            return
        if tag == "td":
            self.cell = []
        if tag == "a":
            self.anchor = [attrs.get("href", ""), []]

    def handle_data(self, text):
        if self.cell is not None:
            self.cell.append(text)
        if self.anchor is not None:
            self.anchor[1].append(text)

    def handle_endtag(self, tag):
        if not self.depth:
            return
        if tag == "a" and self.anchor is not None:
            self.links.append((urljoin(BASE + "cgibin/", self.anchor[0]), " ".join(self.anchor[1]).strip()))
            self.anchor = None
        if tag == "td" and self.cell is not None:
            self.cells.append(" ".join(" ".join(self.cell).split()))
            self.cell = None
        if tag == "table":
            self.depth -= 1
            if not self.depth:
                midi = next((url for url, label in self.links if ".mid" in label.lower()), None)
                license_link = next(((url, label) for url, label in self.links
                                     if "legal.html" in url or "creativecommons.org" in url), ("", "未标明"))
                detail = next((url for url, _ in self.links if "piece-info.cgi" in url), BASE)
                if self.cells:
                    self.results.append({"title": self.cells[0], "composer": self.cells[1],
                                         "instruments": self.cells[4], "license": license_link[1],
                                         "licenseUrl": license_link[0], "detailUrl": detail,
                                         "midiUrl": midi})
                self.cells, self.links = [], []


class MutopiaCatalog:
    def __init__(self, cache_root):
        self.cache_root = Path(cache_root)
        self.cache_root.mkdir(parents=True, exist_ok=True)

    def search(self, query, offset=0, refresh=False):
        query = str(query).strip()
        if not 1 <= len(query) <= 80 or type(offset) is not int or not 0 <= offset <= 5000 or offset % 10:
            raise ValueError("请输入1–80字的曲名或作者；分页必须为10的整数倍")
        url = BASE + "cgibin/make-table.cgi?" + urlencode({"searchingfor": query, "startat": offset})
        cache = self.cache_root / (hashlib.sha256(url.encode()).hexdigest() + ".json")
        old = None
        if cache.exists():
            try:
                old = json.loads(cache.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                pass
        if type(refresh) is not bool:
            raise ValueError("刷新标记必须为布尔值")
        if old and not refresh and time.time() - old.get("savedAt", 0) < 86400:
            return {**old, "cached": True, "offline": False}
        try:
            parser = ListingParser()
            parser.feed(download(url).decode("utf-8", errors="replace"))
            result = {"items": parser.results[:10], "query": query, "offset": offset,
                      "hasNext": len(parser.results) >= 10, "savedAt": time.time(),
                      "provider": "Mutopia", "cached": False, "offline": False}
            # 推荐和手动搜索可能同时读同页，用独立临时文件避免互相替换临时路径。
            temporary = None
            try:
                with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=self.cache_root,
                                                 suffix='.tmp', delete=False) as output:
                    temporary = Path(output.name)
                    json.dump(result, output, ensure_ascii=False)
                temporary.replace(cache)
            except OSError:
                pass  # 缓存写失败不影响已获得的本次曲库结果。
            finally:
                if temporary is not None and temporary.exists():
                    try:
                        temporary.unlink()
                    except OSError:
                        pass
            return result
        except Exception as error:
            if old:
                # 缓存可继续使用，但不能把“有卡片”解释为实时联网成功。
                reason = getattr(error, "reason", error)
                return {**old, "cached": True, "offline": True,
                        "offlineReason": f"{type(reason).__name__}: {reason}"[:500]}
            raise
