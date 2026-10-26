package cn.tangsynth.remote;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.*;
import android.webkit.*;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

/** Native Android GATT transport, with a local-only WebView control UI. */
public final class MainActivity extends Activity {
    private final Handler ui=new Handler(Looper.getMainLooper());
    private Runnable chooseDeviceTask,setupTimeoutTask;
    private WebView web;
    private MusicCatalog musicCatalog;
    private BluetoothAdapter adapter;
    private BluetoothLeScanner scanner;
    private ScanCallback scanCallback;
    private AlertDialog deviceDialog;
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic rx;
    private boolean scanning=false,ready=false,writing=false;
    private long writeGeneration=0,connectionGeneration=0,setupGeneration=0;
    private final LinkedHashMap<String,BluetoothDevice> found=new LinkedHashMap<>();
    private ValueCallback<Uri[]> fileChoice;
    private String exportJson;
    private final ThreadPoolExecutor scoreExecutor=new ThreadPoolExecutor(1,1,0L,TimeUnit.MILLISECONDS,new ArrayBlockingQueue<Runnable>(1),r->new Thread(r,"score-download"));
    private volatile ScoreDownload scoreDownload;
    private static final class ScoreDownload {
        final int id;volatile HttpURLConnection connection;Future<?> future;
        ScoreDownload(int id){this.id=id;}
    }
    private static final int PERMISSIONS=10,ENABLE=11,FILE=12,EXPORT=13;
    private static final UUID CCCD=UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private static final long GATT_SETUP_TIMEOUT_MS=15000;
    // JavaScript implements the packaged control UI. Privileged navigation is
    // restricted to our assets; downloaded scores are data, never HTML pages.
    @SuppressLint("SetJavaScriptEnabled")
    @Override public void onCreate(Bundle b){super.onCreate(b);
        web=new WebView(this);setContentView(web);
        musicCatalog=new MusicCatalog(getCacheDir(),(id,result)->ui.post(()->{if(web!=null)js("window.nativeMusicResult("+id+","+result.toString()+")");}));
        web.getSettings().setJavaScriptEnabled(true);web.getSettings().setDomStorageEnabled(true);
        web.getSettings().setAllowFileAccess(false);web.getSettings().setAllowContentAccess(true);
        web.addJavascriptInterface(new Bridge(),"AndroidBle");
        web.getSettings().setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        web.setWebViewClient(new WebViewClient(){
            @Override public boolean shouldOverrideUrlLoading(WebView view,WebResourceRequest request){return !isLocalAsset(request.getUrl());}
            @Override public boolean shouldOverrideUrlLoading(WebView view,String url){return !isLocalAsset(Uri.parse(url));}
        });
        web.setWebChromeClient(new WebChromeClient(){@Override public boolean onShowFileChooser(WebView v,ValueCallback<Uri[]> cb,FileChooserParams p){return chooseScoreFile(cb,p);}});
        web.loadUrl("file:///android_asset/index.html");
        BluetoothManager manager=(BluetoothManager)getSystemService(BLUETOOTH_SERVICE);adapter=manager==null?null:manager.getAdapter();
    }
    private void js(String script){
        // GATT callbacks already check their owner on the UI thread. A second
        // post could run after reconnect and deliver an old packet/write ACK
        // to the replacement JS session, so dispatch within the same task.
        Runnable deliver=()->{if(web!=null)web.evaluateJavascript(script,null);};
        if(Looper.myLooper()==Looper.getMainLooper())deliver.run();else ui.post(deliver);
    }
    private void state(String s,String message){js("window.nativeBleState("+JSONObject.quote(s)+","+JSONObject.quote(message)+")");}
    private void writeResult(boolean ok,String message){writing=false;js("window.nativeBleWriteComplete("+ok+","+JSONObject.quote(message)+")");}
    private boolean hasPermissions(){if(Build.VERSION.SDK_INT>=31)return checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN)==PackageManager.PERMISSION_GRANTED&&checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)==PackageManager.PERMISSION_GRANTED;return checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)==PackageManager.PERMISSION_GRANTED;}
    private static boolean isLocalAsset(Uri url){return "file".equals(url.getScheme())&&(url.getAuthority()==null||url.getAuthority().isEmpty())&&url.getPath()!=null&&url.getPath().startsWith("/android_asset/");}
    private void permissionLost(){disconnect(false);state("error","蓝牙权限已撤销，请重新连接并授权");}
    private void connect(){if(adapter==null||!getPackageManager().hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)){state("error","此设备不支持 BLE");return;}if(!hasPermissions()){requestPermissions(Build.VERSION.SDK_INT>=31?new String[]{Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT}:new String[]{Manifest.permission.ACCESS_FINE_LOCATION,Manifest.permission.ACCESS_COARSE_LOCATION},PERMISSIONS);return;}
        try{if(!adapter.isEnabled()){startActivityForResult(new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),ENABLE);return;}
        disconnect(false);final long generation=connectionGeneration;scanner=adapter.getBluetoothLeScanner();if(scanner==null){state("error","无法打开 BLE 扫描器");return;}found.clear();scanning=true;state("scanning","正在扫描 Tang-Synth BLE 桥（6秒）");
        scanCallback=new ScanCallback(){@Override public void onScanResult(int type,ScanResult result){ui.post(()->{try{if(scanning&&generation==connectionGeneration)found.put(result.getDevice().getAddress(),result.getDevice());}catch(SecurityException e){if(generation==connectionGeneration)permissionLost();}});}@Override public void onScanFailed(int error){ui.post(()->{if(!scanning||generation!=connectionGeneration)return;stopScan();state("error","BLE 扫描失败 code="+error);});}};
        chooseDeviceTask=()->chooseDevice(generation);
        scanner.startScan(Collections.singletonList(new ScanFilter.Builder().setServiceUuid(new ParcelUuid(UUID.fromString(Protocol.SERVICE))).build()),new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),scanCallback);ui.postDelayed(chooseDeviceTask,6000);
        }catch(SecurityException e){permissionLost();}
    }
    private void stopScan(){boolean wasScanning=scanning;scanning=false;if(chooseDeviceTask!=null){ui.removeCallbacks(chooseDeviceTask);chooseDeviceTask=null;}if(wasScanning&&scanner!=null&&scanCallback!=null){try{scanner.stopScan(scanCallback);}catch(SecurityException e){state("error","蓝牙扫描权限已撤销");}}scanCallback=null;}
    private void chooseDevice(long generation){if(!scanning||generation!=connectionGeneration)return;stopScan();if(!hasPermissions()){permissionLost();return;}if(found.isEmpty()){state("error","未找到 NUS 蓝牙桥；请检查桥供电及旧 Android 的定位开关");return;}
        try{final BluetoothDevice[] devices=found.values().toArray(new BluetoothDevice[0]);String[] labels=new String[devices.length];for(int i=0;i<devices.length;i++)labels[i]=(devices[i].getName()==null?"BLE UART":devices[i].getName())+" "+devices[i].getAddress();
            deviceDialog=new AlertDialog.Builder(this).setTitle("选择 FPGA 蓝牙桥").setItems(labels,(dialog,index)->{if(generation!=connectionGeneration)return;deviceDialog=null;try{if(!hasPermissions()){permissionLost();return;}state("connecting","正在连接 GATT");gatt=devices[index].connectGatt(this,false,gattCallback,BluetoothDevice.TRANSPORT_LE);if(gatt==null){state("error","GATT 连接启动失败");return;}armSetupTimeout(gatt,"GATT 连接");}catch(SecurityException e){permissionLost();}}).setOnCancelListener(d->{if(generation==connectionGeneration){deviceDialog=null;state("disconnected","取消连接");}}).show();
        }catch(SecurityException e){permissionLost();}
    }
    private void cancelSetupTimeout(){setupGeneration++;if(setupTimeoutTask!=null){ui.removeCallbacks(setupTimeoutTask);setupTimeoutTask=null;}}
    private void requestPerformanceLink(BluetoothGatt owner) {
        // 连接优先级仅申请较短间隔；不循环重试、不因手机拒绝而断开。
        try {
            if (!BlePerformanceLink.requestHighPriority(owner))
                state("info", "系统未接受高优先级连接申请，继续使用当前参数");
        } catch (SecurityException failure) { permissionLost(); }
    }
    private void armSetupTimeout(BluetoothGatt owner,String stage){cancelSetupTimeout();final long generation=connectionGeneration,deadline=setupGeneration;setupTimeoutTask=()->{if(generation!=connectionGeneration||deadline!=setupGeneration||owner!=gatt||ready)return;disconnect(false);state("error",stage+"超时，请检查桥供电后重新连接");};ui.postDelayed(setupTimeoutTask,GATT_SETUP_TIMEOUT_MS);}
    private final BluetoothGattCallback gattCallback=new BluetoothGattCallback(){
        @Override public void onConnectionStateChange(BluetoothGatt g,int status,int newState){ui.post(()->{if(g!=gatt)return;try{if(status==BluetoothGatt.GATT_SUCCESS&&newState==BluetoothProfile.STATE_CONNECTED){state("connecting","连接成功，发现 UART 服务");armSetupTimeout(g,"服务发现");if(!g.discoverServices()){state("error","服务发现启动失败");disconnect(false);}}else if(newState==BluetoothProfile.STATE_DISCONNECTED||status!=BluetoothGatt.GATT_SUCCESS){state("disconnected","蓝牙断开 status="+status);disconnect(false);}}catch(SecurityException e){permissionLost();}});}
        @Override public void onServicesDiscovered(BluetoothGatt g,int status){ui.post(()->{if(g!=gatt)return;try{BluetoothGattService service=g.getService(UUID.fromString(Protocol.SERVICE));if(status!=BluetoothGatt.GATT_SUCCESS||service==null){state("error","缺少固定 NUS 服务");disconnect(false);return;}rx=service.getCharacteristic(UUID.fromString(Protocol.RX));BluetoothGattCharacteristic tx=service.getCharacteristic(UUID.fromString(Protocol.TX));if(rx==null||tx==null||!g.setCharacteristicNotification(tx,true)){state("error","UART 特征不可用");disconnect(false);return;}BluetoothGattDescriptor descriptor=tx.getDescriptor(CCCD);if(descriptor==null){state("error","缺少通知 CCCD");disconnect(false);return;}descriptor.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);armSetupTimeout(g,"通知订阅");if(!g.writeDescriptor(descriptor)){state("error","启用通知失败");disconnect(false);}}catch(SecurityException e){permissionLost();}});}
        @Override public void onDescriptorWrite(BluetoothGatt g,BluetoothGattDescriptor d,int status){ui.post(()->{if(g!=gatt||!CCCD.equals(d.getUuid()))return;if(status==BluetoothGatt.GATT_SUCCESS){cancelSetupTimeout();requestPerformanceLink(g);if(g!=gatt)return;ready=true;state("ready","通知已启用，等待 FPGA 握手");}else{state("error","CCCD 写入失败 status="+status);disconnect(false);}});}
        @Override public void onCharacteristicWrite(BluetoothGatt g,BluetoothGattCharacteristic c,int status){ui.post(()->{if(g==gatt&&c==rx&&writing)writeResult(status==BluetoothGatt.GATT_SUCCESS,"GATT 写入 status="+status);});}
        @Override public void onCharacteristicChanged(BluetoothGatt g,BluetoothGattCharacteristic c){final byte[] bytes=c.getValue().clone();ui.post(()->{if(g==gatt)js("window.nativeBleReceive("+JSONObject.quote(Protocol.hex(bytes))+")");});}
    };
    private void disconnect(boolean notify){connectionGeneration++;stopScan();cancelSetupTimeout();if(deviceDialog!=null){deviceDialog.dismiss();deviceDialog=null;}ready=false;rx=null;writeGeneration++;if(writing)writeResult(false,"GATT 已断开");if(gatt!=null){BluetoothGatt old=gatt;gatt=null;try{old.disconnect();}catch(SecurityException e){state("error","蓝牙权限已撤销");}try{old.close();}catch(SecurityException e){state("error","蓝牙连接权限已撤销");}}if(notify)state("disconnected","蓝牙已断开");}
    public final class Bridge {
        @JavascriptInterface public void connect(){ui.post(MainActivity.this::connect);}
        @JavascriptInterface public void disconnect(){ui.post(()->MainActivity.this.disconnect(true));}
        @JavascriptInterface public void writeHex(String hex){ui.post(()->{try{byte[] bytes=Protocol.unhex(hex);if(!ready||gatt==null||rx==null||writing){writeResult(false,"GATT 未就绪或写入忙");return;}if(!hasPermissions()){permissionLost();return;}rx.setWriteType(BlePerformanceLink.writeTypeFor(rx.getProperties()));rx.setValue(bytes);writing=true;final long id=++writeGeneration;if(!gatt.writeCharacteristic(rx))writeResult(false,"GATT 拒绝写入");else ui.postDelayed(()->{if(writing&&writeGeneration==id){writeResult(false,"GATT 写回调超时");MainActivity.this.disconnect(true);}},3000);}catch(SecurityException e){permissionLost();writeResult(false,"蓝牙权限已撤销");}catch(Exception e){writeResult(false,e.getMessage());}});}
        @JavascriptInterface public void loadScoreUrl(String url,int id){ui.post(()->startScoreDownload(url,id));}
        @JavascriptInterface public void cancelScoreLoad(){ui.post(MainActivity.this::cancelScoreDownload);}
        @JavascriptInterface public void musicRequest(String json,int id){if(musicCatalog!=null)musicCatalog.request(json,id);}
        @JavascriptInterface public void exportJson(String json){ui.post(()->beginExport(json));}
    }
    private boolean chooseScoreFile(ValueCallback<Uri[]> cb,WebChromeClient.FileChooserParams params){
        // A fixed Android request code may have only one outstanding owner.
        // Replacing the callback would route picker A's URI into callback B.
        if(fileChoice!=null||web==null){cb.onReceiveValue(null);return true;}
        boolean midi=false;for(String accept:params.getAcceptTypes())if(accept.contains("mid"))midi=true;
        fileChoice=cb;Intent intent=new Intent(Intent.ACTION_OPEN_DOCUMENT).setType(midi?"*/*":"application/json").addCategory(Intent.CATEGORY_OPENABLE);
        // 厂商文档提供器对audio/midi标注不一致，MID使用通用选择器，文件内容仍严格解析。
        try{startActivityForResult(intent,FILE);}catch(RuntimeException e){fileChoice=null;cb.onReceiveValue(null);state("info","文件选择失败：无法打开文件选择器");}return true;
    }
    private void beginExport(String json){
        if(web==null)return;if(exportJson!=null){state("info","请先完成或取消当前导出");return;}
        exportJson=json;Intent intent=new Intent(Intent.ACTION_CREATE_DOCUMENT).setType("application/json").addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE,"tang-recording.json");
        try{startActivityForResult(intent,EXPORT);}catch(RuntimeException e){exportJson=null;state("info","导出失败：无法打开保存文件窗口");}
    }
    private void cancelScoreDownload(){
        ScoreDownload old=scoreDownload;scoreDownload=null;
        if(old!=null){if(old.future!=null)old.future.cancel(true);HttpURLConnection c=old.connection;if(c!=null)c.disconnect();}
        scoreExecutor.purge();
    }
    private void startScoreDownload(String url,int id){
        cancelScoreDownload();if(web==null||scoreExecutor.isShutdown())return;
        ScoreDownload request=new ScoreDownload(id);scoreDownload=request;request.future=scoreExecutor.submit(()->loadJson(url,request));
    }
    private void checkScoreDownload(ScoreDownload request)throws InterruptedIOException{if(scoreDownload!=request||Thread.currentThread().isInterrupted())throw new InterruptedIOException("曲谱下载已取消");}
    private void scoreResult(ScoreDownload request,String json,String error){
        ui.post(()->{if(scoreDownload!=request||web==null)return;scoreDownload=null;js("window.nativeScoreLoaded("+(json==null?"null":JSONObject.quote(json))+","+(error==null?"null":JSONObject.quote(error))+","+request.id+")");});
    }
    private void loadJson(String address,ScoreDownload request){try{URL url=new URL(address);byte[] body=null;for(int redirects=0;redirects<4;redirects++){checkScoreDownload(request);if(!"https".equalsIgnoreCase(url.getProtocol()))throw new IOException("只允许 HTTPS 曲谱");HttpURLConnection c=(HttpURLConnection)url.openConnection();request.connection=c;try{checkScoreDownload(request);c.setInstanceFollowRedirects(false);c.setConnectTimeout(10000);c.setReadTimeout(10000);c.setRequestProperty("Accept","application/json");int code=c.getResponseCode();checkScoreDownload(request);if(code>=300&&code<400){String to=c.getHeaderField("Location");if(to==null)throw new IOException("重定向缺少 Location");url=new URL(url,to);continue;}if(code!=200)throw new IOException("HTTP "+code);try(InputStream in=c.getInputStream();ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] chunk=new byte[4096];int n;while((n=in.read(chunk))!=-1){checkScoreDownload(request);if(out.size()+n>16777216)throw new IOException("JSON 超过 16MiB");out.write(chunk,0,n);}body=out.toByteArray();}break;}finally{c.disconnect();request.connection=null;}}checkScoreDownload(request);if(body==null)throw new IOException("重定向次数过多");scoreResult(request,new String(body,StandardCharsets.UTF_8),null);}catch(Exception e){scoreResult(request,null,String.valueOf(e.getMessage()));}}
    @Override public void onRequestPermissionsResult(int r,String[] p,int[] grants){super.onRequestPermissionsResult(r,p,grants);if(r==PERMISSIONS){if(hasPermissions())connect();else state("error","蓝牙扫描/连接权限被拒绝");}}
    @Override protected void onActivityResult(int r,int result,Intent data){super.onActivityResult(r,result,data);if(r==ENABLE){if(result==RESULT_OK)connect();else state("error","蓝牙未启用");}else if(r==FILE){if(fileChoice!=null){ValueCallback<Uri[]> owner=fileChoice;fileChoice=null;owner.onReceiveValue(result==RESULT_OK&&data!=null&&data.getData()!=null?new Uri[]{data.getData()}:null);}}else if(r==EXPORT){String snapshot=exportJson;exportJson=null;if(snapshot!=null&&result==RESULT_OK&&data!=null&&data.getData()!=null){try(OutputStream out=getContentResolver().openOutputStream(data.getData(),"wt")){if(out==null)throw new IOException("无法写入文件");out.write(snapshot.getBytes(StandardCharsets.UTF_8));state("info","录音 JSON 已保存");}catch(Exception e){state("info","导出失败 "+e.getMessage());}}}}
    @Override protected void onDestroy(){disconnect(false);cancelScoreDownload();if(musicCatalog!=null)musicCatalog.close();scoreExecutor.shutdownNow();exportJson=null;if(fileChoice!=null){fileChoice.onReceiveValue(null);fileChoice=null;}web.removeJavascriptInterface("AndroidBle");web.destroy();web=null;super.onDestroy();}
}
