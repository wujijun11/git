package cn.tangsynth.remote;

import org.json.JSONArray;
import org.json.JSONObject;
import java.util.*;

/** 真实曲库推荐筛选：只选有MIDI的键盘声部，独奏优先，不冒充容量已验证。 */
final class MusicRecommendations {
    private MusicRecommendations() { }

    static JSONArray select(JSONArray source) throws Exception {
        List<JSONObject> solo = new ArrayList<>(), other = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (int i=0;i<source.length();i++) {
            JSONObject item = source.getJSONObject(i);
            String url=item.optString("midiUrl"), instrument=item.optString("instruments").toLowerCase(Locale.ROOT).trim();
            if(url.isEmpty() || seen.contains(url) || !(instrument.contains("piano") || instrument.contains("keyboard") || instrument.contains("harpsichord") || instrument.contains("clavier")))continue;
            seen.add(url);
            boolean isSolo=instrument.matches("(for\\s+)?(piano|keyboard|harpsichord|clavier)");
            JSONObject copy=new JSONObject(item.toString()).put("recommendationReason",isSolo?"优先探索钢琴独奏":"含键盘声部，可选择旋律音轨");
            (isSolo?solo:other).add(copy);
        }
        solo.addAll(other);
        JSONArray result=new JSONArray();
        for(JSONObject item:solo){if(result.length()==6)break;result.put(item);}
        return result;
    }
}
