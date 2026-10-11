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
    public Handler(Looper looper){}
    public boolean post(Runnable task){synchronized(QUEUE){QUEUE.add(task);}return true;}
    public boolean postDelayed(Runnable task,long delay){return post(task);}
    public void removeCallbacks(Runnable task){synchronized(QUEUE){QUEUE.remove(task);}}
    public static void drain(){for(;;){Runnable task;synchronized(QUEUE){task=QUEUE.poll();}if(task==null)return;task.run();}}
    public static void clear(){synchronized(QUEUE){QUEUE.clear();}}
}
""",
    "android/app/Activity.java": r"""package android.app;
public class Activity extends android.view.ContextThemeWrapper {public Activity(){super();}}
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
    private final byte[] value;
    public BluetoothGattCharacteristic(byte[] value){this.value=value;}
    public byte[] getValue(){return value;}
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
        field(activity,"gatt",owner);field(activity,"web",unsafe.allocateInstance(WebView.class));field(activity,"writing",true);
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
        callback.onCharacteristicChanged(old,notification);callback.onCharacteristicWrite(old,notification,BluetoothGatt.GATT_SUCCESS);
        Handler.drain();expect(WebView.calls.isEmpty(),"Stale GATT callback was delivered");
        expect((Boolean)field(activity,"writing"),"Stale write completed replacement transport");

        // A valid old write completion belongs to the old JS session, even if
        // reconnect is queued immediately after the callback.
        reset(old);callback.onCharacteristicWrite(old,notification,BluetoothGatt.GATT_SUCCESS);
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
        System.out.println("ALL ANDROID CALLBACK QUEUE TESTS PASSED (notification/write reconnect, stale callbacks, background dispatch, destruction)");
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
