"""普通JVM执行实际Android链路策略，蓝牙对象为可控替身，不触及手机。"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCES = {
    'android/bluetooth/BluetoothGatt.java': '''package android.bluetooth;
public class BluetoothGatt { public static final int CONNECTION_PRIORITY_HIGH=1;
 public int requested=-1; public boolean accept=true;
 public boolean requestConnectionPriority(int value){requested=value;return accept;}}''',
    'android/bluetooth/BluetoothGattCharacteristic.java': '''package android.bluetooth;
public class BluetoothGattCharacteristic {public static final int PROPERTY_WRITE_NO_RESPONSE=4;
 public static final int WRITE_TYPE_NO_RESPONSE=1,WRITE_TYPE_DEFAULT=2;}''',
    'cn/tangsynth/remote/PolicyProbe.java': '''package cn.tangsynth.remote;
import android.bluetooth.*;
public class PolicyProbe {
 public static void main(String[] args){
  if(BlePerformanceLink.writeTypeFor(8)!=2)throw new AssertionError("legacy fallback");
  if(BlePerformanceLink.writeTypeFor(4|8)!=1)throw new AssertionError("optional no-response");
  BluetoothGatt g=new BluetoothGatt();
  if(!BlePerformanceLink.requestHighPriority(g)||g.requested!=1)throw new AssertionError("priority request");
  g.accept=false;if(BlePerformanceLink.requestHighPriority(g))throw new AssertionError("refusal visible");
  System.out.println("ANDROID BLE POLICY PASS fallback, capability selection, priority request and refusal; no RF tested");
 }}''',
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--java-home', type=Path, default=Path('C:/Program Files/Java/jdk-17'))
    args = parser.parse_args()
    output = ROOT / 'verification/ble-latency'
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='TangBlePolicy_') as temporary:
        folder = Path(temporary)
        sources = []
        for name, content in SOURCES.items():
            path = folder / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding='utf-8')
            sources.append(path)
        sources.append(ROOT / 'mobile/android/app/src/main/java/cn/tangsynth/remote/BlePerformanceLink.java')
        subprocess.run([str(args.java_home / 'bin/javac.exe'), '-encoding', 'UTF-8',
                        '-d', str(folder), *map(str, sources)], check=True)
        result = subprocess.run([str(args.java_home / 'bin/java.exe'), '-cp', str(folder),
                                 'cn.tangsynth.remote.PolicyProbe'], capture_output=True, text=True, check=True)
        (output / 'android-policy.log').write_text(result.stdout, encoding='utf-8')
        print(result.stdout)


if __name__ == '__main__':
    main()
