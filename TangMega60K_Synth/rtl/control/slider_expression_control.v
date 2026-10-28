// 连续滑条只更新选中的V2表情字段：0音量、1弯音、2颤音。
// 音量0..2048(Q1.11)；弯音-200..+200音分，松手回零；颤音0..100音分。
// 当前已呈现的负载在反压时冻结，后续连续位置仅合并到尚未呈现的目标。
module slider_expression_control(
    input wire clk,rst_n,input wire [1:0] mode,
    input wire position_valid,input wire [11:0] position,
    input wire touch_active,touch_fault,reset_expression,
    output reg expr_valid,input wire expr_ready,
    output reg [2:0] expr_mask,output reg [11:0] expr_gain,
    output reg signed [12:0] expr_bend,output reg [7:0] expr_vibrato
);
    reg sample_valid,previous_valid,sample_new_touch;
    reg [1:0] sample_mode;
    reg [21:0] scaled_position;
    reg [11:0] desired_gain;
    reg signed [12:0] desired_bend;
    reg [7:0] desired_vibrato;
    reg [2:0] dirty;
    wire [21:0] clamped=position>3072?22'd3072:{10'd0,position};
    wire [21:0] scaled=(clamped<<9)+(clamped<<7)+(clamped<<5)+(clamped<<3)+(clamped<<1)+clamped;
    wire [12:0] rounded=(scaled_position+22'd512)>>10;
    wire [21:0] normal=rounded>2048?22'd2048:{9'd0,rounded};
    wire [21:0] bend_scaled=(normal<<8)+(normal<<7)+(normal<<4);
    wire [21:0] depth_scaled=(normal<<6)+(normal<<5)+(normal<<2);
    wire signed [12:0] mapped_bend=$signed({1'b0,bend_scaled[22-1:11]})-13'sd200;
    wire [7:0] mapped_depth=depth_scaled>>11;
    wire [11:0] gain_distance=normal[11:0]>=desired_gain?
        normal[11:0]-desired_gain:desired_gain-normal[11:0];
    wire space=!expr_valid || expr_ready;
    reg [2:0] updates;
    reg [11:0] next_gain;
    reg signed [12:0] next_bend;
    reg [7:0] next_vibrato;
    always @*begin
        updates=0;
        next_gain=desired_gain;
        next_bend=desired_bend;
        next_vibrato=desired_vibrato;
        if(sample_valid && sample_mode==mode && !touch_fault)begin
            case(mode)
                0:if(sample_new_touch || gain_distance>=4 ||
                     ((normal==0 || normal==2048) && gain_distance!=0))begin
                    updates[0]=1;
                    next_gain=normal[11:0];
                    end
                1:if(touch_active && (sample_new_touch || mapped_bend!=desired_bend))begin
                    updates[1]=1;
                    next_bend=mapped_bend;
                    end
                2:if(sample_new_touch || mapped_depth!=desired_vibrato)begin
                    updates[2]=1;
                    next_vibrato=mapped_depth;
                    end
                default:;
            endcase
        end
        if((!touch_active || touch_fault || mode!=1) && next_bend!=0)begin
            updates[1]=1;
            next_bend=0;
        end
        // 复位只清弯音/颤音，保留本地或蓝牙设置的音量。
        if(reset_expression)begin updates=3'b110;
        next_bend=0;
        next_vibrato=0;
        end
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            sample_valid<=0;
            previous_valid<=0;
            sample_new_touch<=0;
            sample_mode<=0;
            scaled_position<=0;
            desired_gain<=2048;
            desired_bend<=0;
            desired_vibrato<=0;
            dirty<=0;
            expr_valid<=0;
            expr_mask<=0;
            expr_gain<=2048;
            expr_bend<=0;
            expr_vibrato<=0;
        end else begin
            sample_valid<=position_valid;
            previous_valid<=position_valid;
            sample_new_touch<=position_valid && !previous_valid;
            sample_mode<=mode;
            if(position_valid)scaled_position<=scaled;
            if(space)begin
                expr_valid<=|dirty;
                expr_mask<=dirty;
                if(|dirty)begin expr_gain<=desired_gain;
                expr_bend<=desired_bend;
                expr_vibrato<=desired_vibrato;
                end
            end
            desired_gain<=next_gain;
            desired_bend<=next_bend;
            desired_vibrato<=next_vibrato;
            dirty<=(space?3'd0:dirty)|updates;
        end
    end
endmodule
