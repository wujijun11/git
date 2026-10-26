"""基于真实曲库的钢琴曲目发现，不按用户演奏记录画像，也不自动上传。

换一批轮换查询页，刷新重新联网但保留离线旧缓存；只保留可下载MIDI的去重结果。
推荐仅表示适合继续查看，未分析前不保证满足25键或1024事件。
"""
import re


def select_items(items, limit=6):
    candidates = []
    seen = set()
    for item in items:
        url = item.get('midiUrl')
        if not url or url in seen:
            continue
        instruments = item.get('instruments', '').lower()
        if not any(key in instruments for key in ('piano', 'keyboard', 'harpsichord', 'clavier')):
            continue
        seen.add(url)
        solo = bool(re.fullmatch(r'(for\s+)?(piano|keyboard|harpsichord|clavier)', instruments.strip()))
        candidates.append((not solo, item))
    candidates.sort(key=lambda value: value[0])
    return [{**item, 'recommendationReason': '优先探索钢琴独奏' if not group else '含键盘声部，可选择旋律音轨'}
            for group, item in candidates[:limit]]


def recommend(catalog, batch=0, refresh=False):
    if type(batch) is not int or not 0 <= batch <= 100000 or type(refresh) is not bool:
        raise ValueError('推荐批次或刷新标记无效')
    offset = batch % 20 * 10
    result = catalog.search('piano', offset, refresh=refresh)
    items = select_items(result['items'])
    # 曲库分页随时可能缩短；回到首页而不是展示一个空白成功页。
    if not items and offset:
        result = catalog.search('piano', 0, refresh=refresh)
        offset = 0
        items = select_items(result['items'])
    return {**result, 'items': items, 'batch': batch, 'sourceOffset': offset,
            'kind': 'piano-discovery', 'capacityChecked': False,
            'note': '推荐尚未检查25键与事件容量，请选音轨和片段后分析。'}
