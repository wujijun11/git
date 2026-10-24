"""Exercise actual Android download/export/file ownership with deterministic doubles.

No phone is used. URLStreamHandlerFactory supplies HTTPS response timing without
network access; the real production activity and executor are compiled and run.
"""
import argparse
import ast
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--java-home', required=True)
parser.add_argument('--android-jar', required=True)
parser.add_argument('--activity-source', type=pathlib.Path)
parser.add_argument('--case', choices=['downloads', 'export', 'file'], required=True)
args = parser.parse_args()
JAVA = pathlib.Path(args.java_home)
SDK = pathlib.Path(args.android_jar)
# Reuse only the declarative runtime doubles, without executing that test runner.
tree = ast.parse((ROOT / 'mobile/tests/test_android_callbacks.py').read_text(encoding='utf-8'))
STUBS = ast.literal_eval(next(n.value for n in tree.body if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'STUBS' for t in n.targets)))
STUBS.pop('CallbackHarness.java')
STUBS['android/webkit/WebView.java'] = STUBS['android/webkit/WebView.java'].replace('public void evaluateJavascript', 'public void removeJavascriptInterface(String name){}public void destroy(){}\n    public void evaluateJavascript')
STUBS.update({
 'android/content/Context.java': 'package android.content;public class Context {public Context(){}}',
 'android/view/ContextThemeWrapper.java': 'package android.view;public class ContextThemeWrapper extends android.content.Context {public ContextThemeWrapper(){}}',
 'android/bluetooth/BluetoothGattCallback.java': 'package android.bluetooth;public class BluetoothGattCallback {public BluetoothGattCallback(){}}',
 'android/webkit/WebChromeClient.java': r'''package android.webkit;
public class WebChromeClient {public static class FileChooserParams {}public boolean onShowFileChooser(WebView v,ValueCallback<android.net.Uri[]> cb,FileChooserParams p){return false;}}
''',
 'android/app/Activity.java': r'''package android.app;
public class Activity extends android.view.ContextThemeWrapper {
 public static final java.util.List<Integer> requests=new java.util.ArrayList<>();
 public static boolean failStarts;
 public Activity(){super();}
 public int checkSelfPermission(String p){return 0;}
 public android.content.pm.PackageManager getPackageManager(){return new android.content.pm.PackageManager();}
 public void startActivityForResult(android.content.Intent i,int code){if(failStarts)throw new IllegalStateException("picker unavailable");requests.add(code);}
 protected void onActivityResult(int request,int result,android.content.Intent data){}
 protected void onDestroy(){}
 public android.content.ContentResolver getContentResolver(){return new android.content.ContentResolver();}
}
''',
 'android/content/Intent.java': r'''package android.content;
public class Intent {
 private android.net.Uri data;
 public Intent(String action){}
 public Intent setType(String s){return this;}public Intent addCategory(String s){return this;}
 public Intent putExtra(String key,String value){return this;}
 public Intent setData(android.net.Uri uri){data=uri;return this;}public android.net.Uri getData(){return data;}
}
''',
 'android/net/Uri.java': r'''package android.net;
public class Uri {private final String value;private Uri(String s){value=s;}public static Uri parse(String s){return new Uri(s);}public String toString(){return value;}public String getScheme(){return "content";}public String getAuthority(){return "test";}public String getPath(){return "/test";}}
''',
 'android/content/ContentResolver.java': r'''package android.content;
public class ContentResolver {
 public static final java.util.Map<String,java.io.ByteArrayOutputStream> files=new java.util.HashMap<>();
 public static String mode;
 public static boolean failWrites;
 public java.io.OutputStream openOutputStream(android.net.Uri uri){return openOutputStream(uri,"w");}
 public java.io.OutputStream openOutputStream(android.net.Uri uri,String m){if(failWrites)throw new IllegalStateException("provider write failed");mode=m;java.io.ByteArrayOutputStream out=new java.io.ByteArrayOutputStream();files.put(uri.toString(),out);return out;}
}
''',
 'AsyncHarness.java': r'''import cn.tangsynth.remote.MainActivity;
import android.os.*;import android.webkit.*;import android.content.*;import android.net.Uri;
import java.lang.reflect.*;import java.net.*;import java.io.*;import java.nio.charset.StandardCharsets;
import java.util.concurrent.*;import java.util.concurrent.atomic.*;import sun.misc.Unsafe;
public final class AsyncHarness {
 static Unsafe unsafe;static MainActivity activity;static MainActivity.Bridge bridge;static ThreadPoolExecutor executor;
 static final AtomicInteger active=new AtomicInteger(),maximum=new AtomicInteger(),opened=new AtomicInteger();
 static final CountDownLatch oldEntered=new CountDownLatch(1),oldReleased=new CountDownLatch(1);
 static void field(Object o,String n,Object v)throws Exception{Field f=o.getClass().getDeclaredField(n);f.setAccessible(true);f.set(o,v);}
 static Object field(Object o,String n)throws Exception{Field f=o.getClass().getDeclaredField(n);f.setAccessible(true);return f.get(o);}
 static void expect(boolean yes,String m){if(!yes)throw new AssertionError(m+" calls="+WebView.calls);}
 static void request(String url,int id)throws Exception{
  try{bridge.getClass().getMethod("loadScoreUrl",String.class,int.class).invoke(bridge,url,id);}
  catch(NoSuchMethodException old){bridge.getClass().getMethod("loadScoreUrl",String.class).invoke(bridge,url);}
 }
 static final class MockConnection extends HttpURLConnection {
  boolean counted=false;
  MockConnection(URL url){super(url);opened.incrementAndGet();}
  public void connect(){}public boolean usingProxy(){return false;}
  public int getResponseCode()throws IOException{
   counted=true;int count=active.incrementAndGet();maximum.accumulateAndGet(count,Math::max);
   if(url.getPath().equals("/old")){oldEntered.countDown();try{if(!oldReleased.await(3,TimeUnit.SECONDS))throw new IOException("test release timeout");}catch(InterruptedException e){Thread.currentThread().interrupt();throw new InterruptedIOException("interrupted");}}
   return 200;
  }
  public InputStream getInputStream(){return new ByteArrayInputStream(("{\"title\":\""+url.getPath()+"\"}").getBytes(StandardCharsets.UTF_8));}
  public void disconnect(){if(url.getPath().equals("/old"))oldReleased.countDown();if(counted){counted=false;active.decrementAndGet();}}
 }
 static void waitFor(java.util.function.BooleanSupplier condition,String message)throws Exception{for(int i=0;i<500;i++){if(condition.getAsBoolean())return;Thread.sleep(5);}throw new AssertionError(message);}
 static void downloads()throws Exception{
  URL.setURLStreamHandlerFactory(protocol->protocol.equals("https")?new URLStreamHandler(){protected URLConnection openConnection(URL u){return new MockConnection(u);}}:null);
  request("https://test/old",1);Handler.drain();expect(oldEntered.await(1,TimeUnit.SECONDS),"Old download never started");
  for(int i=2;i<=31;i++)request("https://test/new-"+i,i);
  Handler.drain();Thread.sleep(150);oldReleased.countDown();
  waitFor(()->active.get()==0&&(executor==null||executor.getActiveCount()==0&&executor.getQueue().isEmpty()),"Downloads did not settle");Handler.drain();
  expect(maximum.get()==1,"Unbounded concurrent download workers: max="+maximum.get());
  expect(executor.getCorePoolSize()==1&&executor.getMaximumPoolSize()==1&&executor.getQueue() instanceof ArrayBlockingQueue&&executor.getQueue().size()+executor.getQueue().remainingCapacity()==1,"Production executor is not bounded to one worker and one pending task");
  expect(WebView.calls.size()==1&&WebView.calls.get(0).contains("new-31")&&WebView.calls.get(0).contains(",31)"),"Stale downloads reached WebView or latest request lost");
  System.out.println("PASS native download supersession: 31 requests; max workers="+maximum.get()+"; actual production queue capacity=1; opened="+opened.get()+"; only request 31 delivered");
  // The real worker completes, but its UI task is intentionally held back.
  Method start=MainActivity.class.getDeclaredMethod("startScoreDownload",String.class,int.class);start.setAccessible(true);
  Method cancel=MainActivity.class.getDeclaredMethod("cancelScoreDownload");cancel.setAccessible(true);WebView.calls.clear();
  int priorOpened=opened.get();start.invoke(activity,"https://test/queued",32);
  waitFor(()->opened.get()>priorOpened&&executor.getActiveCount()==0&&executor.getQueue().isEmpty(),"Queued result did not finish");cancel.invoke(activity);Handler.drain();
  expect(WebView.calls.isEmpty(),"Completed but cancelled result reached WebView");
  System.out.println("PASS completed result cancelled before UI delivery");
  int beforeDestroy=opened.get();start.invoke(activity,"https://test/destroyed",33);
  waitFor(()->opened.get()>beforeDestroy&&executor.getActiveCount()==0&&executor.getQueue().isEmpty(),"Destroyed result did not finish");
  Method destroy=MainActivity.class.getDeclaredMethod("onDestroy");destroy.setAccessible(true);destroy.invoke(activity);Handler.drain();
  expect(WebView.calls.isEmpty()&&executor.isShutdown(),"Destroyed activity retained work or delivered result");
  request("https://test/late-start",34);bridge.exportJson("late-export");Handler.drain();expect(opened.get()==beforeDestroy+1&&android.app.Activity.requests.isEmpty(),"Queued bridge operation restarted destroyed activity");
  System.out.println("PASS destruction cancels executor, queued result and late bridge operations");
 }
 static void export()throws Exception{
  bridge.exportJson("snapshot-A");bridge.exportJson("snapshot-B");Handler.drain();
  expect(android.app.Activity.requests.size()==1,"Opened overlapping export pickers");
  Method result=MainActivity.class.getDeclaredMethod("onActivityResult",int.class,int.class,Intent.class);result.setAccessible(true);
  result.invoke(activity,13,-1,new Intent("result").setData(Uri.parse("content://export/A")));
  String saved=android.content.ContentResolver.files.get("content://export/A").toString("UTF-8");expect(saved.equals("snapshot-A"),"Second export replaced first snapshot: "+saved);
  expect("wt".equals(android.content.ContentResolver.mode),"Export did not request truncation of old longer file");
  System.out.println("PASS export picker owner/snapshot and truncating write mode");
  bridge.exportJson("cancel-me");Handler.drain();result.invoke(activity,13,0,null);expect(field(activity,"exportJson")==null,"Cancelled export retained snapshot");
  bridge.exportJson("after-cancel");Handler.drain();result.invoke(activity,13,-1,new Intent("null-result"));expect(field(activity,"exportJson")==null,"Missing URI retained export lock");
  bridge.exportJson("after-null");Handler.drain();result.invoke(activity,13,-1,new Intent("result").setData(Uri.parse("content://export/B")));
  expect(android.content.ContentResolver.files.get("content://export/B").toString("UTF-8").equals("after-null"),"Export could not restart after cancellation");
  System.out.println("PASS export cancellation/null URI release and retry");
  android.bluetooth.BluetoothGatt healthy=new android.bluetooth.BluetoothGatt();field(activity,"gatt",healthy);field(activity,"ready",true);WebView.calls.clear();
  android.app.Activity.failStarts=true;bridge.exportJson("failed-open");Handler.drain();android.app.Activity.failStarts=false;
  expect(field(activity,"exportJson")==null,"Failed export picker retained owner");
  bridge.exportJson("failed-write");Handler.drain();android.content.ContentResolver.failWrites=true;
  result.invoke(activity,13,-1,new Intent("result").setData(Uri.parse("content://export/failure")));android.content.ContentResolver.failWrites=false;
  expect(field(activity,"exportJson")==null&&(Boolean)field(activity,"ready")&&field(activity,"gatt")==healthy,"Export failure changed healthy GATT owner");
  expect(WebView.calls.size()==2&&WebView.calls.stream().allMatch(s->s.contains("nativeBleState(\"info\"")&&s.contains("导出失败")),"File errors dispatched BLE-disconnect error state");
  System.out.println("PASS export picker/provider failures preserve healthy GATT and release export owner");
 }
 static void file(String classes)throws Exception{
  WebChromeClient chooser=null;
  try(java.util.stream.Stream<java.nio.file.Path> files=java.nio.file.Files.list(java.nio.file.Paths.get(classes,"cn/tangsynth/remote"))){
   for(java.nio.file.Path p:(Iterable<java.nio.file.Path>)files::iterator){String n=p.getFileName().toString();if(n.startsWith("MainActivity$")&&n.endsWith(".class")){
    Class<?> c=Class.forName("cn.tangsynth.remote."+n.substring(0,n.length()-6));if(c.getSuperclass()==WebChromeClient.class){Constructor<?> ctor=c.getDeclaredConstructor(MainActivity.class);ctor.setAccessible(true);chooser=(WebChromeClient)ctor.newInstance(activity);}
   }}
  }
  expect(chooser!=null,"Production file chooser callback missing");
  java.util.List<Uri[]> first=new java.util.ArrayList<>(),second=new java.util.ArrayList<>();
  chooser.onShowFileChooser(null,first::add,null);chooser.onShowFileChooser(null,second::add,null);
  expect(android.app.Activity.requests.size()==1&&first.isEmpty()&&second.size()==1&&second.get(0)==null,"Overlapping file chooser replaced its owner");
  Method result=MainActivity.class.getDeclaredMethod("onActivityResult",int.class,int.class,Intent.class);result.setAccessible(true);
  result.invoke(activity,12,-1,new Intent("result").setData(Uri.parse("content://score/A")));
  expect(first.size()==1&&first.get(0)[0].toString().equals("content://score/A")&&second.size()==1,"Old URI reached new chooser callback");
  chooser.onShowFileChooser(null,second::add,null);result.invoke(activity,12,-1,new Intent("null-result"));expect(second.size()==2&&second.get(1)==null,"Missing URI not treated as cancelled file choice");
  System.out.println("PASS file chooser owner, duplicate rejection, URI result and null cancellation");
  android.bluetooth.BluetoothGatt healthy=new android.bluetooth.BluetoothGatt();field(activity,"gatt",healthy);field(activity,"ready",true);WebView.calls.clear();
  java.util.List<Uri[]> failed=new java.util.ArrayList<>();android.app.Activity.failStarts=true;chooser.onShowFileChooser(null,failed::add,null);android.app.Activity.failStarts=false;
  expect(failed.size()==1&&failed.get(0)==null&&field(activity,"fileChoice")==null,"Failed file picker retained callback");
  expect((Boolean)field(activity,"ready")&&field(activity,"gatt")==healthy&&WebView.calls.size()==1&&WebView.calls.get(0).contains("nativeBleState(\"info\""),"File picker failure dispatched BLE-disconnect error state");
  System.out.println("PASS file picker failure preserves healthy GATT and returns cancelled callback");
 }
 public static void main(String[] args)throws Exception{
  Field singleton=Unsafe.class.getDeclaredField("theUnsafe");singleton.setAccessible(true);unsafe=(Unsafe)singleton.get(null);
  // Construct the production Activity: its actual bounded executor initializer
  // is exercised, rather than supplying an executor with an assumed capacity.
  activity=new MainActivity();field(activity,"web",unsafe.allocateInstance(WebView.class));bridge=activity.new Bridge();
  try{executor=(ThreadPoolExecutor)field(activity,"scoreExecutor");}catch(NoSuchFieldException old){executor=null;}
  try{if(args[0].equals("downloads"))downloads();else if(args[0].equals("export"))export();else file(args[1]);}
  finally{oldReleased.countDown();if(executor!=null)executor.shutdownNow();}
 }
}
'''
})

scratch = ROOT.parent / 'tmp/android-async-test'
scratch.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='run-', dir=scratch) as temporary:
    temporary = pathlib.Path(temporary)
    production, runtime, sources = (temporary / name for name in ('production', 'runtime', 'sources'))
    production.mkdir(); runtime.mkdir()
    paths = []
    for name, text in STUBS.items():
        path = sources / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')
        paths.append(str(path))
    native = ROOT / 'mobile/android/app/src/main/java/cn/tangsynth/remote'
    activity_source = args.activity_source or native / 'MainActivity.java'
    subprocess.run([str(JAVA / 'bin/javac.exe'), '-encoding', 'UTF-8', '-classpath', str(SDK), '-d', str(production), str(native / 'Protocol.java'), str(activity_source)], check=True)
    subprocess.run([str(JAVA / 'bin/javac.exe'), '-encoding', 'UTF-8', '-classpath', str(production) + ';' + str(SDK), '-d', str(runtime), *paths], check=True)
    subprocess.run([str(JAVA / 'bin/java.exe'), '-classpath', str(runtime) + ';' + str(production) + ';' + str(SDK), 'AsyncHarness', args.case, str(production)], check=True)
