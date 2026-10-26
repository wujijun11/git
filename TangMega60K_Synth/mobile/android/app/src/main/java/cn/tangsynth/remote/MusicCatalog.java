package cn.tangsynth.remote;

import android.text.Html;
import android.util.Base64;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.*;
import java.util.zip.*;

/** 曲库网络和缓存驱动。只返回数据；不访问BLE，不执行下载内容，不写FPGA。 */
final class MusicCatalog implements Closeable {
    interface Callback { void complete(int id, JSONObject result); }
    private static final int LIMIT = 4 * 1024 * 1024;
    private static final String BASE = "https://www.mutopiaproject.org/";
    private final File cache;
    private final Callback callback;
    private final ThreadPoolExecutor executor = new ThreadPoolExecutor(1, 1, 0L,
            TimeUnit.MILLISECONDS, new ArrayBlockingQueue<Runnable>(1), r -> new Thread(r, "music-catalog"));
    private volatile HttpURLConnection connection;
    private volatile boolean closed;

    MusicCatalog(File directory, Callback result) {
        cache = new File(directory, "mutopia"); callback = result;
        if (!cache.isDirectory()) cache.mkdirs();
    }
    void request(String json, int id) {
        if (json == null || json.length() > 12000) { callback.complete(id, error("曲库请求过大")); return; }
        try {
            executor.execute(() -> {
                JSONObject result;
                try {
                    JSONObject request = new JSONObject(json);
                    if ("search".equals(request.optString("action"))) result = search(request.getString("query"), request.optInt("offset", 0),false);
                    else if("recommend".equals(request.optString("action")))result=recommend(request.optInt("batch",0),request.optBoolean("refresh",false));
                    else if ("fetch".equals(request.optString("action"))) result = fetch(request.getJSONObject("item"));
                    else throw new IOException("不支持的曲库操作");
                    result.put("ok", true);
                } catch (Exception e) { result = error(e.getMessage()); }
                if (!closed) callback.complete(id, result);
            });
        } catch (RejectedExecutionException e) { callback.complete(id, error("曲库忙，请稍后重试")); }
    }
    private static JSONObject error(String message) {
        JSONObject value = new JSONObject();
        try { value.put("ok", false).put("error", message == null ? "曲库操作失败" : message); }
        catch (Exception ignored) { /* 固定键名和值不会触发JSON类型异常。 */ }
        return value;
    }
    static URL checkedUrl(String address) throws IOException {
        URL url = new URL(address);
        if (!("https".equalsIgnoreCase(url.getProtocol()) || "http".equalsIgnoreCase(url.getProtocol()))
                || !("www.mutopiaproject.org".equalsIgnoreCase(url.getHost()) || "mutopiaproject.org".equalsIgnoreCase(url.getHost()))
                || url.getUserInfo() != null || (url.getPort() != -1 && url.getPort() != 80 && url.getPort() != 443))
            throw new IOException("曲库只访问Mutopia官方网站");
        return new URL("https", "www.mutopiaproject.org", url.getFile());
    }
    private byte[] download(String address) throws IOException {
        URL url = checkedUrl(address);
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30);
        for (int redirects = 0; redirects < 4; redirects++) {
            if (closed || Thread.currentThread().isInterrupted()) throw new InterruptedIOException("曲库已关闭");
            HttpURLConnection current = (HttpURLConnection) url.openConnection(); connection = current;
            try {
                current.setInstanceFollowRedirects(false); current.setConnectTimeout(10000); current.setReadTimeout(10000);
                current.setRequestProperty("User-Agent", "TangSynthMobile/1.3 (educational MIDI client)");
                int status = current.getResponseCode();
                if (status >= 300 && status < 400) {
                    String location = current.getHeaderField("Location");
                    if (location == null) throw new IOException("重定向缺少地址");
                    url = checkedUrl(new URL(url, location).toString()); continue;
                }
                if (status != 200) throw new IOException("HTTP " + status);
                try (InputStream input = current.getInputStream()) { return readLimited(input, LIMIT, deadline); }
            } finally { current.disconnect(); connection = null; }
        }
        throw new IOException("曲库重定向次数过多");
    }
    static byte[] readLimited(InputStream input, int limit, long deadline) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream(); byte[] buffer = new byte[8192]; int count;
        while ((count = input.read(buffer)) != -1) {
            if (Thread.currentThread().isInterrupted() || System.nanoTime() > deadline) throw new InterruptedIOException("曲库操作超时或取消");
            if (output.size() + count > limit) throw new IOException("曲库文件或ZIP解压总量超过4MiB");
            output.write(buffer, 0, count);
        }
        return output.toByteArray();
    }
    private static String digest(byte[] bytes) throws Exception {
        StringBuilder result = new StringBuilder();
        for (byte value : MessageDigest.getInstance("SHA-256").digest(bytes)) result.append(String.format(Locale.ROOT, "%02x", value & 255));
        return result.toString();
    }
    private JSONObject search(String query, int offset, boolean refresh) throws Exception {
        query = query.trim();
        if (query.isEmpty() || query.length() > 80 || offset < 0 || offset > 5000 || offset % 10 != 0) throw new IOException("搜索词1–80字；分页为10的整数倍");
        String address = BASE + "cgibin/make-table.cgi?searchingfor=" + URLEncoder.encode(query, "UTF-8") + "&startat=" + offset;
        File file = new File(cache, digest(address.getBytes(StandardCharsets.UTF_8)) + ".json"); JSONObject old = null;
        try (InputStream input = new FileInputStream(file)) {
            old = new JSONObject(new String(readLimited(input, LIMIT, Long.MAX_VALUE), StandardCharsets.UTF_8));
        } catch (Exception ignored) { /* 损坏或不存在的缓存重新联网获取。 */ }
        if (old != null && !refresh && System.currentTimeMillis() - old.optLong("savedAt") < 86400000L) return old.put("cached", true).put("offline", false);
        try {
            JSONObject result = parseListing(new String(download(address), StandardCharsets.UTF_8));
            result.put("savedAt", System.currentTimeMillis()).put("cached", false).put("offline", false);
            try (OutputStream output = new FileOutputStream(file)) { output.write(result.toString().getBytes(StandardCharsets.UTF_8)); }
            catch (IOException ignored) { /* 缓存失败不影响当前结果。 */ }
            return result;
        } catch (Exception failure) { if (old != null) return old.put("cached", true).put("offline", true); throw failure; }
    }
    private JSONObject recommend(int batch,boolean refresh)throws Exception{
        if(batch<0 || batch>100000)throw new IOException("推荐批次无效");
        int offset=(batch%20)*10;
        JSONObject result=search("piano",offset,refresh);
        JSONArray items=MusicRecommendations.select(result.getJSONArray("items"));
        if(items.length()==0 && offset!=0){offset=0;result=search("piano",0,refresh);items=MusicRecommendations.select(result.getJSONArray("items"));}
        return result.put("items",items).put("batch",batch).put("sourceOffset",offset)
                .put("capacityChecked",false).put("note","推荐尚未检查25键与事件容量，请选音轨和片段后分析。");
    }
    @SuppressWarnings("deprecation")
    private static String text(String html) { return Html.fromHtml(html).toString().replaceAll("\\s+", " ").trim(); }
    interface LabelDecoder { String decode(String html); }
    static JSONObject parseListing(String html) throws Exception {
        return parseListing(html, MusicCatalog::text);
    }
    // 注入文本解码器可在普通JVM核对网络数据结构，Android仍使用系统HTML实体解码。
    static JSONObject parseListing(String html, LabelDecoder decoder) throws Exception {
        JSONArray items = new JSONArray();
        Matcher tables = Pattern.compile("<table\\b[^>]*class=[\"'][^\"']*result-table[^\"']*[\"'][^>]*>(.*?)</table>", Pattern.CASE_INSENSITIVE | Pattern.DOTALL).matcher(html);
        while (tables.find() && items.length() < 10) {
            String table = tables.group(1); List<String> cells = new ArrayList<>();
            Matcher td = Pattern.compile("<td\\b[^>]*>(.*?)</td>", Pattern.CASE_INSENSITIVE | Pattern.DOTALL).matcher(table);
            while (td.find()) cells.add(decoder.decode(td.group(1)));
            if (cells.size() < 5) continue;
            JSONObject item = new JSONObject().put("title", cells.get(0)).put("composer", cells.get(1)).put("instruments", cells.get(4))
                    .put("license", "未标明").put("licenseUrl", "").put("detailUrl", BASE).put("midiUrl", "");
            Matcher links = Pattern.compile("<a\\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", Pattern.CASE_INSENSITIVE | Pattern.DOTALL).matcher(table);
            while (links.find()) {
                String url = new URL(new URL(BASE + "cgibin/"), links.group(1).replace("&amp;", "&")).toString(), label = decoder.decode(links.group(2));
                if (label.toLowerCase(Locale.ROOT).contains(".mid")) item.put("midiUrl", checkedUrl(url).toString());
                if (url.contains("piece-info.cgi")) item.put("detailUrl", url);
                if (url.contains("legal.html") || url.contains("creativecommons.org")) item.put("license", label).put("licenseUrl", url);
            }
            items.put(item);
        }
        return new JSONObject().put("items", items).put("hasNext", items.length() == 10);
    }
    private JSONObject fetch(JSONObject item) throws Exception {
        String address = checkedUrl(item.getString("midiUrl")).toString(); byte[] body = download(address);
        JSONArray files = new JSONArray(); JSONObject attribution = new JSONObject(item.toString()).put("provider", "Mutopia");
        if (body.length >= 4 && body[0] == 'P' && body[1] == 'K') {
            try (ZipInputStream zip = new ZipInputStream(new ByteArrayInputStream(body))) {
                ZipEntry entry; int total = 0, entries = 0;
                while ((entry = zip.getNextEntry()) != null) {
                    if (++entries > 128) throw new IOException("ZIP条目过多");
                    if (entry.isDirectory()) continue;
                    byte[] bytes = readLimited(zip, LIMIT - total, Long.MAX_VALUE); total += bytes.length;
                    String name = entry.getName().replace('\\', '/'); String lower = name.toLowerCase(Locale.ROOT);
                    if (lower.endsWith(".mid") || lower.endsWith(".midi")) {
                        if (files.length() >= 32) throw new IOException("ZIP最多32个MIDI文件");
                        files.put(midiFile(name.substring(name.lastIndexOf('/') + 1), bytes, attribution));
                    }
                }
            }
        } else files.put(midiFile(item.optString("title", "曲库MIDI") + ".mid", body, attribution));
        if (files.length() == 0) throw new IOException("下载内容中没有MIDI文件");
        return new JSONObject().put("files", files);
    }
    private static JSONObject midiFile(String name, byte[] bytes, JSONObject attribution) throws Exception {
        if (bytes.length < 4 || bytes[0] != 'M' || bytes[1] != 'T' || bytes[2] != 'h' || bytes[3] != 'd') throw new IOException("下载内容不是标准MIDI");
        return new JSONObject().put("name", name).put("base64", Base64.encodeToString(bytes, Base64.NO_WRAP))
                .put("attribution", new JSONObject(attribution.toString()).put("sha256", digest(bytes)));
    }
    @Override public void close() { closed = true; HttpURLConnection active = connection; if (active != null) active.disconnect(); executor.shutdownNow(); }
}
