"""真实官方曲库联网检查，结果留本机；不连接硬件，不播放或上传。"""
import json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'desktop'))
from score_library.service import ScoreLibrary


def main():
    output=ROOT/'verification/recommendations'
    service=ScoreLibrary(output/'live-cache')
    first=service.recommend(0,True)
    cached=service.recommend(0,False)
    next_batch=service.recommend(1,True)
    if not first['items'] or not next_batch['items']:
        raise RuntimeError('真实曲库没有返回可推荐MIDI')
    selected=service.fetch(first['items'][0]['token'])
    report={'provider':'Mutopia','first':first,'cachedRead':cached['cached'],'next':next_batch,
            'downloadedFileInspection':[{key:file[key] for key in ('name','durationMs','tracks','attribution')} for file in selected['files']],
            'firstVsNextDifferent':{item['midiUrl'] for item in first['items']}!={item['midiUrl'] for item in next_batch['items']},
            'hardwareAccessed':False}
    (output/'live-result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'first':len(first['items']),'next':len(next_batch['items']),'cachedRead':cached['cached'],
                      'different':report['firstVsNextDifferent'],'downloaded':len(selected['files'])},indent=2))


if __name__=='__main__':
    main()
