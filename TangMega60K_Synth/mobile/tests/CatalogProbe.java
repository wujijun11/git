package cn.tangsynth.remote;

import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.concurrent.*;

/** 普通JVM的曲库核心测试；不冒充Android系统HTML或真实手机蓝牙测试。 */
public final class CatalogProbe {
    private static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    public static void main(String[] args) throws Exception {
        String html = Files.readString(Paths.get(args[0]), StandardCharsets.UTF_8);
        JSONArray expected = new JSONArray(Files.readString(Paths.get(args[1]), StandardCharsets.UTF_8));
        JSONObject parsed = MusicCatalog.parseListing(html,
                input -> input.replaceAll("<[^>]+>", " ").replace("&amp;", "&").replaceAll("\\s+", " ").trim());
        JSONArray items = parsed.getJSONArray("items");
        require(items.length() == expected.length() && items.length() > 0, "search result count");
        for (int i = 0; i < items.length(); i++) {
            JSONObject got = items.getJSONObject(i), reference = expected.getJSONObject(i);
            for (String key : new String[]{"composer", "license", "midiUrl", "detailUrl"})
                require(got.optString(key).equals(reference.optString(key)), "field mismatch " + i + " " + key);
        }
        JSONArray choices=new JSONArray().put(new JSONObject().put("title","Voice").put("instruments","Voice and Piano").put("midiUrl","https://www.mutopiaproject.org/a.mid"))
                .put(new JSONObject().put("title","Solo").put("instruments","for Piano").put("midiUrl","https://www.mutopiaproject.org/b.mid"))
                .put(new JSONObject().put("title","Duplicate").put("instruments","for Piano").put("midiUrl","https://www.mutopiaproject.org/b.mid"))
                .put(new JSONObject().put("title","NoMidi").put("instruments","for Piano").put("midiUrl",""))
                .put(new JSONObject().put("title","Violin").put("instruments","Violin").put("midiUrl","https://www.mutopiaproject.org/c.mid"));
        JSONArray selected=MusicRecommendations.select(choices);
        require(selected.length()==2 && selected.getJSONObject(0).getString("title").equals("Solo"),"solo first, duplicate and missing MIDI filter");
        require(selected.getJSONObject(0).has("recommendationReason"),"reason preserved");
        require(MusicCatalog.checkedUrl("http://mutopiaproject.org/a.mid").toString()
                .equals("https://www.mutopiaproject.org/a.mid"), "https normalization");
        for (String bad : new String[]{"https://evil.test/a.mid", "https://www.mutopiaproject.org.evil.test/",
                "file:///etc/passwd", "https://evil@www.mutopiaproject.org/a.mid", "https://www.mutopiaproject.org:444/a.mid"}) {
            boolean rejected = false;
            try { MusicCatalog.checkedUrl(bad); } catch (IOException failure) { rejected = true; }
            require(rejected, "URL should be rejected: " + bad);
        }
        boolean limited = false;
        try { MusicCatalog.readLimited(new ByteArrayInputStream(new byte[101]), 100, Long.MAX_VALUE); }
        catch (IOException failure) { limited = true; }
        require(limited, "download limit");
        CountDownLatch done = new CountDownLatch(1);
        MusicCatalog catalog = new MusicCatalog(new File(args[2]), (id, result) -> {
            require(id == 7 && !result.optBoolean("ok"), "bad action callback"); done.countDown();
        });
        try { catalog.request("{\"action\":\"invalid\"}", 7); require(done.await(5, TimeUnit.SECONDS), "callback timeout"); }
        finally { catalog.close(); }
        System.out.println("NATIVE CATALOG CORE PASS: " + items.length() + " real listing rows, URL restrictions, size limit, worker error callback. Android HTML/GATT not tested.");
    }
}
