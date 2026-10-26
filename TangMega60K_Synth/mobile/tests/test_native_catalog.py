"""真实曲库HTML + Windows独立解析器对照，编译并运行Android曲库的纯Java核心。"""
import hashlib
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'desktop'))
from score_library.mutopia import ListingParser, download


def main():
    output = ROOT / 'verification/mobile/native-catalog'
    output.mkdir(parents=True, exist_ok=True)
    dependency = ROOT / 'tmp/test-dependencies/json-20240303.jar'
    dependency.parent.mkdir(parents=True, exist_ok=True)
    url = 'https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar'
    if not dependency.exists():
        with urllib.request.urlopen(url, timeout=30) as response:
            dependency.write_bytes(response.read())
    with urllib.request.urlopen(url + '.sha1', timeout=30) as response:
        expected = response.read().decode().strip().split()[0]
    if hashlib.sha1(dependency.read_bytes()).hexdigest() != expected:
        raise RuntimeError('org.json测试依赖校验失败')
    html_path = output / 'mutopia-bach.html'
    if not html_path.exists():
        html_path.write_bytes(download('https://www.mutopiaproject.org/cgibin/make-table.cgi?searchingfor=bach&startat=0'))
    parser = ListingParser()
    parser.feed(html_path.read_text(encoding='utf-8'))
    reference = output / 'reference.json'
    reference.write_text(json.dumps(parser.results[:10], ensure_ascii=False), encoding='utf-8')
    sdk = ROOT / 'tmp/android-build/sdk/platforms/android-35/android.jar'
    jdk = Path('C:/Program Files/Java/jdk-17/bin')
    classpath = f'{dependency};{sdk}'
    sources = [ROOT / 'mobile/android/app/src/main/java/cn/tangsynth/remote/MusicCatalog.java',
               ROOT / 'mobile/android/app/src/main/java/cn/tangsynth/remote/MusicRecommendations.java',
               ROOT / 'mobile/tests/CatalogProbe.java']
    subprocess.run([str(jdk / 'javac.exe'), '-encoding', 'UTF-8', '-cp', classpath,
                    '-d', str(output), *map(str, sources)], check=True)
    result = subprocess.run([str(jdk / 'java.exe'), '-cp', f'{output};{classpath}',
                             'cn.tangsynth.remote.CatalogProbe', str(html_path), str(reference), str(output / 'cache')],
                            check=True, capture_output=True, text=True, encoding='utf-8')
    (output / 'result.log').write_text(result.stdout, encoding='utf-8')
    print(result.stdout)


if __name__ == '__main__':
    main()
