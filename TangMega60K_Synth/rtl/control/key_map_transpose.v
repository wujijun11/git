// 对实体键盘/按键曲谱的基础映射加半音偏移；App远程NOTE仍保留原协议音高。
// 先做有符号加法再限幅，不能把负数或超过127的音高回绕。
module key_map_transpose (
    input wire [174:0] base_map,
    input wire signed [6:0] semitones,
    output wire [174:0] mapped_notes
);
    genvar key;
    generate for (key = 0; key < 25; key = key + 1) begin: keys
        wire signed [8:0] shifted = $signed({2'b0, base_map[key*7 +: 7]}) +
                                    $signed({{2{semitones[6]}}, semitones});
        assign mapped_notes[key*7 +: 7] = shifted < 0 ? 7'd0 :
                                         shifted > 127 ? 7'd127 : shifted[6:0];
    end endgenerate
endmodule
