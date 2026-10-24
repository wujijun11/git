"""Run actual MainActivity callbacks against a deterministic host UI queue.

This checks queue ordering, not Android hardware. The installed Android SDK is
used only to compile the production class; minimal runtime doubles implement
the UI queue and WebView so reconnect interleavings can be forced reliably.
"""
import argparse
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--java-home", required=True)
parser.add_argument("--android-jar", required=True)
args = parser.parse_args()
java_home = pathlib.Path(args.java_home)
android_jar = pathlib.Path(args.android_jar)

STUBS = {
    "android/os/Looper.java": r"""package android.os;
public final class Looper {
    private static final Thread MAIN_THREAD=Thread.currentThread();
    private static final Looper MAIN=new Looper();
    public static Looper getMainLooper(){return MAIN;}
    public static Looper myLooper(){return Thread.currentThread()==MAIN_THREAD?MAIN:null;}
}
""",
    "android/os/Handler.java": r"""package android.os;
import java.util.ArrayDeque;
public final class Handler {
    private static final ArrayDeque<Runnable> QUEUE=new ArrayDeque<>();
    private static final java.util.ArrayList<Runnable> DELAYED=new java.util.ArrayList<>();
    public Handler(Looper looper){}
    public boolean post(Runnable task){synchronized(QUEUE){QUEUE.add(task);}return true;}
    public boolean postDelayed(Runnable task,long delay){DELAYED.add(task);return true;}
    public void removeCallbacks(Runnable task){synchronized(QUEUE){QUEUE.remove(task);}DELAYED.remove(task);}
    public static void deadlines(){java.util.ArrayList<Runnable> due=new java.util.ArrayList<>(DELAYED);DELAYED.clear();for(Runnable r:due)r.run();drain();}
    public static int deadlineCount(){return DELAYED.size();}
    public static void drain(){for(;;){Runnable task;synchronized(QUEUE){task=QUEUE.poll();}if(task==null)return;task.run();}}
    public static void clear(){synchronized(QUEUE){QUEUE.clear();}DELAYED.clear();}
}
""",
    "android/app/Activity.java": r"""package android.app;
public class Activity extends android.view.ContextThemeWrapper {
    public Activity(){super();}
    public int checkSelfPermission(String permission){return 0;}
    public android.content.pm.PackageManager getPackageManager(){return new android.content.pm.PackageManager();}
}
""",
    "android/webkit/WebView.java": r"""package android.webkit;
import java.util.ArrayList;
import java.util.List;
public class WebView extends android.view.View {
    public static int session=1;
    public static final List<String> calls=new ArrayList<>();
    public WebView(android.content.Context context){super(context);}
    public void evaluateJavascript(String script,ValueCallback<String> result){calls.add(session+":"+script);}
}
""",
    "android/bluetooth/BluetoothGattCharacteristic.java": r"""package android.bluetooth;
public class BluetoothGattCharacteristic {
    private byte[] value;
    public BluetoothGattCharacteristic(byte[] value){this.value=value;}
    public byte[] getValue(){return value;}
    public boolean setValue(byte[] bytes){value=bytes;return true;}
    public void setWriteType(int type){}
    public BluetoothGattDescriptor getDescriptor(java.util.UUID uuid){return new BluetoothGattDescriptor(uuid);}
}
""",
    "android/os/Build.java": r"""package android.os;public final class Build {public static final class VERSION {public static int SDK_INT=35;}}""",
    "android/os/ParcelUuid.java": r"""package android.os;public final class ParcelUuid {public ParcelUuid(java.util.UUID uuid){}}""",
    "android/content/pm/PackageManager.java": r"""package android.content.pm;public class PackageManager {public boolean hasSystemFeature(String feature){return true;}}""",
    "android/bluetooth/BluetoothGatt.java": r"""package android.bluetooth;
public class BluetoothGatt {
    public static final int GATT_SUCCESS=0;
    public int disconnects,closes;
    public boolean discoverServices(){return true;}
    public BluetoothGattService getService(java.util.UUID uuid){return new BluetoothGattService();}
    public boolean setCharacteristicNotification(BluetoothGattCharacteristic characteristic,boolean enabled){return true;}
    public boolean writeDescriptor(BluetoothGattDescriptor descriptor){return true;}
    public boolean writeCharacteristic(BluetoothGattCharacteristic characteristic){return true;}
    public void disconnect(){disconnects++;}
    public void close(){closes++;}
}
""",
    "android/bluetooth/BluetoothGattDescriptor.java": r"""package android.bluetooth;
public class BluetoothGattDescriptor {public static final byte[] ENABLE_NOTIFICATION_VALUE={1,0};private java.util.UUID uuid;public BluetoothGattDescriptor(java.util.UUID u){uuid=u;}public java.util.UUID getUuid(){return uuid;}public boolean setValue(byte[] value){return true;}}
""",
    "android/bluetooth/BluetoothGattService.java": r"""package android.bluetooth;
public class BluetoothGattService {public BluetoothGattCharacteristic getCharacteristic(java.util.UUID uuid){return new BluetoothGattCharacteristic(new byte[16]);}}
""",
    "android/bluetooth/BluetoothAdapter.java": r"""package android.bluetooth;
public class BluetoothAdapter {public boolean isEnabled(){return true;}public android.bluetooth.le.BluetoothLeScanner getBluetoothLeScanner(){return new android.bluetooth.le.BluetoothLeScanner();}}
""",
    "android/bluetooth/BluetoothDevice.java": r"""package android.bluetooth;
public class BluetoothDevice {public String getAddress(){return "test-device";}public String getName(){return "Tang-Synth-C3";}public BluetoothGatt connectGatt(android.content.Context c,boolean auto,BluetoothGattCallback callback,int transport){return new BluetoothGatt();}}
""",
    "android/bluetooth/le/BluetoothLeScanner.java": r"""package android.bluetooth.le;
public class BluetoothLeScanner {public void startScan(java.util.List<ScanFilter> filters,ScanSettings settings,ScanCallback callback){}public void stopScan(ScanCallback callback){}}
""",
    "android/bluetooth/le/ScanCallback.java": r"""package android.bluetooth.le;
public abstract class ScanCallback {public ScanCallback(){}public void onScanResult(int type,ScanResult result){}public void onScanFailed(int error){}}
""",
    "android/bluetooth/le/ScanFilter.java": r"""package android.bluetooth.le;
public class ScanFilter {public static class Builder {public Builder setServiceUuid(android.os.ParcelUuid uuid){return this;}public ScanFilter build(){return new ScanFilter();}}}
""",
    "android/bluetooth/le/ScanSettings.java": r"""package android.bluetooth.le;
public class ScanSettings {public static class Builder {public Builder setScanMode(int mode){return this;}public ScanSettings build(){return new ScanSettings();}}}
""",
    "android/bluetooth/le/ScanResult.java": r"""package android.bluetooth.le;
public class ScanResult {private android.bluetooth.BluetoothDevice device;public ScanResult(android.bluetooth.BluetoothDevice d){device=d;}public android.bluetooth.BluetoothDevice getDevice(){return device;}}
""",
    "android/app/AlertDialog.java": r"""package android.app;
public class AlertDialog {public static AlertDialog last;public boolean dismissed;public android.content.DialogInterface.OnClickListener click;
    public void dismiss(){dismissed=true;}
    public void choose(int i){click.onClick(null,i);}
    public static class Builder {private android.content.DialogInterface.OnClickListener listener;public Builder(android.content.Context c){}public Builder setTitle(CharSequence s){return this;}public Builder setItems(CharSequence[] s,android.content.DialogInterface.OnClickListener l){listener=l;return this;}public Builder setOnCancelListener(android.content.DialogInterface.OnCancelListener l){return this;}public AlertDialog show(){last=new AlertDialog();last.click=listener;return last;}}
}
""",
    "org/json/JSONObject.java": r"""package org.json;
public final class JSONObject {
    public static String quote(String value){return "\""+value.replace("\\", "\\\\").replace("\"", "\\\"")+"\"";}
}
""",
    "CallbackHarness.java": r"""import android.bluetooth.*;
import android.os.*;
import android.webkit.WebView;
import cn.tangsynth.remote.MainActivity;
import java.lang.reflect.*;
import java.nio.file.*;
import sun.misc.Unsafe;

public final class CallbackHarness {
    private static Unsafe unsafe;
    private static MainActivity activity;
    private static Handler ui;
    private static BluetoothGattCallback callback;
    private static Method js;

    private static void field(Object target,String name,Object value)throws Exception{
        Field f=target.getClass().getDeclaredField(name);f.setAccessible(true);f.set(target,value);
    }
    private static Object field(Object target,String name)throws Exception{
        Field f=target.getClass().getDeclaredField(name);f.setAccessible(true);return f.get(target);
    }
    private static BluetoothGatt gatt()throws Exception{return (BluetoothGatt)unsafe.allocateInstance(BluetoothGatt.class);}
    private static void reset(BluetoothGatt owner)throws Exception{
        Handler.clear();WebView.calls.clear();WebView.session=1;
        field(activity,"gatt",owner);field(activity,"web",unsafe.allocateInstance(WebView.class));field(activity,"writing",true);field(activity,"ready",false);field(activity,"rx",null);field(activity,"scanning",false);field(activity,"deviceDialog",null);field(activity,"setupTimeoutTask",null);field(activity,"chooseDeviceTask",null);
    }
    private static void expect(boolean condition,String message){if(!condition)throw new AssertionError(message+" calls="+WebView.calls);}

    public static void main(String[] args)throws Exception{
        Field singleton=Unsafe.class.getDeclaredField("theUnsafe");singleton.setAccessible(true);unsafe=(Unsafe)singleton.get(null);
        ui=new Handler(Looper.getMainLooper());activity=(MainActivity)unsafe.allocateInstance(MainActivity.class);field(activity,"ui",ui);
        js=MainActivity.class.getDeclaredMethod("js",String.class);js.setAccessible(true);
        Path classes=Paths.get(args[0],"cn/tangsynth/remote");
        try(java.util.stream.Stream<Path> files=Files.list(classes)){
            for(Path p:(Iterable<Path>)files::iterator){String n=p.getFileName().toString();if(n.startsWith("MainActivity$")&&n.endsWith(".class")){
                Class<?> c=Class.forName("cn.tangsynth.remote."+n.substring(0,n.length()-6));
                if(BluetoothGattCallback.class.isAssignableFrom(c)){callback=(BluetoothGattCallback)unsafe.allocateInstance(c);field(callback,"this$0",activity);break;}
            }}
        }
        expect(callback!=null,"Production GATT callback not found");
        field(activity,"gattCallback",callback);field(activity,"adapter",new BluetoothAdapter());field(activity,"found",new java.util.LinkedHashMap<String,BluetoothDevice>());
        BluetoothGatt old=gatt(),replacement=gatt();
        BluetoothGattCharacteristic notification=new BluetoothGattCharacteristic(new byte[]{(byte)0xA5,0x5A});

        // Old callback is ahead of reconnect, but its second UI post used to
        // land behind reconnect and inject old bytes into the new JS session.
        reset(old);callback.onCharacteristicChanged(old,notification);
        ui.post(()->{try{field(activity,"gatt",replacement);WebView.session=2;}catch(Exception e){throw new RuntimeException(e);}});
        Handler.drain();
        expect(WebView.calls.size()==1&&WebView.calls.get(0).startsWith("1:window.nativeBleReceive("),"Old notification crossed reconnect");

        // Already stale callbacks must be discarded when their UI task runs.
        reset(old);ui.post(()->{try{field(activity,"gatt",replacement);WebView.session=2;}catch(Exception e){throw new RuntimeException(e);}});
        field(activity,"rx",notification);
        callback.onCharacteristicChanged(old,notification);callback.onCharacteristicWrite(old,notification,BluetoothGatt.GATT_SUCCESS);
        Handler.drain();expect(WebView.calls.isEmpty(),"Stale GATT callback was delivered");
        expect((Boolean)field(activity,"writing"),"Stale write completed replacement transport");

        // A valid old write completion belongs to the old JS session, even if
        // reconnect is queued immediately after the callback.
        reset(old);callback.onCharacteristicWrite(old,notification,BluetoothGatt.GATT_SUCCESS);
        field(activity,"rx",notification);
        ui.post(()->{try{field(activity,"gatt",replacement);field(activity,"writing",true);WebView.session=2;}catch(Exception e){throw new RuntimeException(e);}});
        Handler.drain();
        expect(WebView.calls.size()==1&&WebView.calls.get(0).startsWith("1:window.nativeBleWriteComplete("),"Old write result completed new JS write");
        expect((Boolean)field(activity,"writing"),"Replacement write was cleared");

        // Download-thread JS is still marshalled onto the UI queue.
        reset(old);Thread background=new Thread(()->{try{js.invoke(activity,"download-result");}catch(Exception e){throw new RuntimeException(e);}});
        background.start();background.join();expect(WebView.calls.isEmpty(),"Background JS evaluated before UI dispatch");
        Handler.drain();expect(WebView.calls.size()==1&&WebView.calls.get(0).equals("1:download-result"),"Background JS was not delivered");

        // A destroyed Activity drops a background result already in the queue.
        reset(old);background=new Thread(()->{try{js.invoke(activity,"late-download");}catch(Exception e){throw new RuntimeException(e);}});
        background.start();background.join();field(activity,"web",null);Handler.drain();expect(WebView.calls.isEmpty(),"Result reached destroyed WebView");
        // Three setup stages have independent deadlines. A cancelled stage or
        // a previous connection's deadline cannot tear down its replacement.
        Method arm=MainActivity.class.getDeclaredMethod("armSetupTimeout",BluetoothGatt.class,String.class);arm.setAccessible(true);
        reset(old);field(activity,"writing",false);arm.invoke(activity,old,"connect");Runnable connectDeadline=(Runnable)field(activity,"setupTimeoutTask");
        callback.onConnectionStateChange(old,0,2);Handler.drain();
        expect(Handler.deadlineCount()==1,"Service discovery did not replace connection deadline");
        Runnable discoveryDeadline=(Runnable)field(activity,"setupTimeoutTask");connectDeadline.run();
        expect(field(activity,"gatt")==old,"Cancelled connection deadline closed discovery");
        callback.onServicesDiscovered(old,0);Handler.drain();
        expect(Handler.deadlineCount()==1,"CCCD did not replace discovery deadline");discoveryDeadline.run();
        expect(field(activity,"gatt")==old,"Cancelled discovery deadline closed CCCD");
        callback.onDescriptorWrite(old,new BluetoothGattDescriptor(java.util.UUID.randomUUID()),0);Handler.drain();
        expect(!(Boolean)field(activity,"ready"),"Unrelated descriptor enabled BLE readiness");
        callback.onDescriptorWrite(old,new BluetoothGattDescriptor(java.util.UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")),0);Handler.drain();
        expect((Boolean)field(activity,"ready")&&Handler.deadlineCount()==0,"CCCD success did not clear deadline");
        for(String stage:new String[]{"GATT connection","Service discovery","CCCD subscription"}){
            reset(gatt());field(activity,"writing",false);BluetoothGatt owner=(BluetoothGatt)field(activity,"gatt");arm.invoke(activity,owner,stage);Handler.deadlines();
            expect(field(activity,"gatt")==null&&owner.disconnects==1&&owner.closes==1,"Missing "+stage+" timeout cleanup");
            expect(WebView.calls.stream().anyMatch(s->s.contains(stage)&&s.contains("超时")),"Missing stage-specific timeout error");
        }
        reset(old);field(activity,"writing",false);arm.invoke(activity,old,"old");Runnable staleDeadline=(Runnable)field(activity,"setupTimeoutTask");
        field(activity,"gatt",replacement);staleDeadline.run();expect(field(activity,"gatt")==replacement,"Old owner timeout closed replacement");

        // Reconnect starts a fresh scan owner. Results/failures/chooser tasks
        // already queued from an earlier scan cannot modify the new attempt.
        Method connect=MainActivity.class.getDeclaredMethod("connect");connect.setAccessible(true);
        Method disconnect=MainActivity.class.getDeclaredMethod("disconnect",boolean.class);disconnect.setAccessible(true);
        reset(null);field(activity,"writing",false);connect.invoke(activity);
        android.bluetooth.le.ScanCallback oldScan=(android.bluetooth.le.ScanCallback)field(activity,"scanCallback");Runnable oldChooser=(Runnable)field(activity,"chooseDeviceTask");
        connect.invoke(activity);oldScan.onScanResult(0,new android.bluetooth.le.ScanResult(new BluetoothDevice()));oldScan.onScanFailed(7);oldChooser.run();Handler.drain();
        expect((Boolean)field(activity,"scanning"),"Stale scan failure or chooser stopped new attempt");
        expect(((java.util.Map<?,?>)field(activity,"found")).isEmpty(),"Stale scan result contaminated new attempt");
        android.bluetooth.le.ScanCallback activeScan=(android.bluetooth.le.ScanCallback)field(activity,"scanCallback");
        activeScan.onScanResult(0,new android.bluetooth.le.ScanResult(new BluetoothDevice()));Handler.drain();Handler.deadlines();
        android.app.AlertDialog oldDialog=android.app.AlertDialog.last;expect(oldDialog!=null,"Device chooser was not displayed");
        int scanMessages=WebView.calls.size();activeScan.onScanFailed(9);Handler.drain();expect(WebView.calls.size()==scanMessages,"Stopped scan reported a late failure over device chooser");
        disconnect.invoke(activity,false);expect(oldDialog.dismissed,"Cancelled chooser remained visible");
        connect.invoke(activity);oldDialog.choose(0);expect(field(activity,"gatt")==null&&(Boolean)field(activity,"scanning"),"Stale chooser connected into new scan");
        disconnect.invoke(activity,false);
        System.out.println("ALL ANDROID CALLBACK QUEUE TESTS PASSED (GATT reconnect/write ownership, 3 setup deadlines, stage cancellation, CCCD filtering, stale scans/chooser, background dispatch, destruction)");
    }
}
""",
}

scratch = ROOT.parent / "tmp" / "android-callback-test"
scratch.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="run-", dir=scratch) as temporary:
    temporary = pathlib.Path(temporary)
    production = temporary / "production"
    runtime = temporary / "runtime"
    sources = temporary / "sources"
    production.mkdir()
    runtime.mkdir()
    paths = []
    for name, text in STUBS.items():
        path = sources / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        paths.append(str(path))
    javac = java_home / "bin" / "javac.exe"
    java = java_home / "bin" / "java.exe"
    native = ROOT / "mobile/android/app/src/main/java/cn/tangsynth/remote"
    subprocess.run([str(javac), "-encoding", "UTF-8", "-classpath", str(android_jar), "-d", str(production), str(native / "Protocol.java"), str(native / "MainActivity.java")], check=True)
    subprocess.run([str(javac), "-encoding", "UTF-8", "-classpath", str(production) + ";" + str(android_jar), "-d", str(runtime), *paths], check=True)
    subprocess.run([str(java), "-classpath", str(runtime) + ";" + str(production) + ";" + str(android_jar), "CallbackHarness", str(production)], check=True)
