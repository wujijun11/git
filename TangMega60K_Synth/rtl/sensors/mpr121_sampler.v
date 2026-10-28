// Independent module initialization, verified configuration and coherent snapshots.
// irq_n has already been synchronized by the board wrapper.
module mpr121_sampler #(
    parameter integer CLK_HZ=49152000, I2C_HZ=400000,
    parameter integer TIMEOUT_CYCLES=CLK_HZ/200,
    parameter integer POLL_CYCLES=CLK_HZ/2000,
    parameter integer RESET_CYCLES=CLK_HZ/1000,
    parameter integer SETTLE_CYCLES=CLK_HZ/20,
    parameter integer RETRY_CYCLES=CLK_HZ/10,
    parameter integer CALIBRATION_SNAPSHOTS=3, MAX_RETRIES=2,
    parameter integer ELECTRODES=12,
    // 只提前发布已收到的两个状态字节；原43字节完整读取/校准/滑条数据仍保留。
    parameter integer EARLY_KEY_ENABLE=0,
    parameter [6:0] I2C_ADDR=7'h5a,
    parameter [7:0] TOUCH_THRESHOLD=12, RELEASE_THRESHOLD=6,
    parameter [7:0] FILTER_CDC=8'h10, FILTER_CDT=8'h20
)(
    input wire clk,resetn,irq_n, input wire snapshot_ready,
    output reg snapshot_valid, output reg [343:0] snapshot,
    output reg ready, fault,
    output reg [3:0] last_error, output reg [31:0] error_count,
    output reg [31:0] last_success_age,
    output wire [4:0] init_stage,
    output reg [15:0] oor_status, inout wire scl,sda,
    output reg early_key_valid,
    input wire early_key_ready,
    output reg [11:0] early_key_status
);
    localparam [4:0] WRITE=0,WWAIT=1,VERIFY=2,VWAIT=3,RESET_WAIT=4,
       SETTLE=5,POLL=6,PWAIT=7,HOLD=8,RETRY=9,OVCF_LOCK=10;
    reg [4:0] state;
    reg [5:0] cfg_index;
    reg [31:0] timer;
    reg [7:0] verify_byte;
    reg [343:0] scratch;
    reg [7:0] fail_attempts,cal_count;
    wire bus_ready,bus_done,bus_busy,rx_valid;
    wire [2:0] bus_error;
    wire [7:0] rx_data;
    wire [5:0] rx_index;
    wire cmd_read=(state==VERIFY || state==POLL);
    wire early_key_space=!early_key_valid || early_key_ready;
    wire poll_allowed=!EARLY_KEY_ENABLE || !ready || early_key_space;
    wire cmd_valid=(state==WRITE || state==VERIFY || (state==POLL && poll_allowed));
    wire [11:0] enabled_mask=(12'hfff >> (12-ELECTRODES));
    function [7:0] cfg_addr;
      input [5:0] n;
      begin
        if(n==0) cfg_addr=8'h80;
        else if(n==1 || n==44) cfg_addr=8'h5e;
        else if(n<=12) cfg_addr=8'h2b+n-2;
        else if(n<=36) cfg_addr=8'h41+n-13;
        else case(n)
          37:cfg_addr=8'h5b;38:cfg_addr=8'h5c;39:cfg_addr=8'h5d;
          40:cfg_addr=8'h76;41:cfg_addr=8'h77;42:cfg_addr=8'h7b;
          default:cfg_addr=8'h7c;
        endcase
      end
    endfunction
    function [7:0] cfg_data;
      input [5:0] n;
      begin
        case(n)
          0:cfg_data=8'h63; 2,3,6,7:cfg_data=8'h01;
          8:cfg_data=8'hff;9:cfg_data=8'h02;
          38:cfg_data=FILTER_CDC;39:cfg_data=FILTER_CDT;
          44:cfg_data=8'h80 | ELECTRODES;
          default: if(n>=13 && n<=36)
              cfg_data=n[0]?TOUCH_THRESHOLD:RELEASE_THRESHOLD;
            else cfg_data=0;
        endcase
      end
    endfunction
    i2c_register_master #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ),
      .TIMEOUT_CYCLES(TIMEOUT_CYCLES)) bus(
      .clk(clk),.resetn(resetn),.cmd_valid(cmd_valid),.cmd_ready(bus_ready),
      .cmd_read(cmd_read),.cmd_addr(I2C_ADDR),
      .cmd_reg((state==POLL)?8'h00:cfg_addr(cfg_index)),
      .cmd_wdata(cfg_data(cfg_index)),.cmd_len((state==POLL)?6'd43:6'd1),
      .busy(bus_busy),.done(bus_done),.error(bus_error),
      .rdata_valid(rx_valid),.rdata(rx_data),.rindex(rx_index),.scl(scl),.sda(sda));
    assign init_stage=state;
    // 已呈现快照在反压时保持；新事务启动前预留邮箱位置，禁止覆盖按下/松开。
    // fault/ready撤销属于采集通道取消，丢弃未确认旧状态，避免故障恢复后重放陈旧按键。
    always @(posedge clk)begin
      if(!resetn)begin
        early_key_valid<=0;
        early_key_status<=0;
      end else if(fault || !ready)begin
        early_key_valid<=0;
      end else begin
        if(early_key_valid && early_key_ready)
          early_key_valid<=0;
        if(EARLY_KEY_ENABLE && state==PWAIT && rx_valid && rx_index==1 && !rx_data[7])begin
          early_key_status<={rx_data[3:0],scratch[7:0]};
          early_key_valid<=1;
        end
      end
    end
    integer k;
    integer filtered,baseline,delta;
    reg calibration_ok;
    always @* begin
      calibration_ok=((scratch[11:0] & enabled_mask)==0);
      for(k=0;k<ELECTRODES;k=k+1) begin
        filtered={scratch[(5+2*k)*8 +:2],scratch[(4+2*k)*8 +:8]};
        baseline={scratch[(30+k)*8 +:8],2'b00};
        delta=baseline-filtered;
        if(baseline==0 || filtered==0 || filtered>=1020 || delta>32 || delta< -32)
          calibration_ok=0;
      end
    end
    always @(posedge clk) begin
      if(!resetn) begin
        state<=WRITE;cfg_index<=0;timer<=0;verify_byte<=0;scratch<=0;
        snapshot_valid<=0;snapshot<=0;ready<=0;fault<=0;last_error<=0;
        error_count<=0;last_success_age<=0;oor_status<=0;
        fail_attempts<=0;cal_count<=0;
      end else begin
        if(last_success_age!=32'hffffffff) last_success_age<=last_success_age+1;
        if(rx_valid) begin
          if(state==VWAIT) verify_byte<=rx_data;
          if(state==PWAIT) scratch[rx_index*8 +:8]<=rx_data;
          // 状态高字节包含OVCF：一旦已知过流就停止发键并触发既有故障释放。
          // I2C事务仍由bus完成，不带电气截断；完整状态机随后进入OVCF_LOCK。
          if(EARLY_KEY_ENABLE && ready && state==PWAIT && rx_index==1 && rx_data[7])begin
            fault<=1;
            ready<=0;
            last_error<=5;
          end
        end
        case(state)
          WRITE: if(bus_ready) state<=WWAIT;
          WWAIT: if(bus_done) begin
            if(bus_error!=0) begin
              fault<=1;ready<=0;last_error<={1'b0,bus_error};error_count<=error_count+1;
              timer<=0;state<=RETRY;
            end else if(cfg_index==0) begin timer<=0;state<=RESET_WAIT;end
            else state<=VERIFY;
          end
          RESET_WAIT: if(timer>=RESET_CYCLES-1) begin cfg_index<=1;state<=WRITE;end
            else timer<=timer+1;
          VERIFY: if(bus_ready) state<=VWAIT;
          VWAIT: if(bus_done) begin
            if(bus_error!=0 || verify_byte!=cfg_data(cfg_index)) begin
              fault<=1;ready<=0;last_error<=(bus_error!=0)?{1'b0,bus_error}:4'd4;
              error_count<=error_count+1;timer<=0;state<=RETRY;
            end else if(cfg_index==44) begin timer<=0;cal_count<=0;state<=SETTLE;end
            else begin cfg_index<=cfg_index+1;state<=WRITE;end
          end
          SETTLE: if(timer>=SETTLE_CYCLES-1 && poll_allowed) begin timer<=0;state<=POLL;end
            else timer<=timer+1;
          POLL: if(bus_ready && poll_allowed) state<=PWAIT;
          PWAIT: if(bus_done) begin
            if(bus_error!=0) begin
              last_error<={1'b0,bus_error};error_count<=error_count+1;
              if(fail_attempts>=MAX_RETRIES) begin
                fault<=1;ready<=0;timer<=0;state<=RETRY;
              end else begin fail_attempts<=fail_attempts+1;state<=POLL;end
            end else if(scratch[15]) begin
              // OVCF stops the chip; external reset is required after REXT inspection.
              fault<=1;ready<=0;last_error<=5;error_count<=error_count+1;state<=OVCF_LOCK;
            end else begin
              fail_attempts<=0;last_success_age<=0;
              oor_status<=scratch[31:16]; timer<=0;
              if(!ready) begin
                if(calibration_ok) begin
                  if(cal_count>=CALIBRATION_SNAPSHOTS-1) begin
                    ready<=1;fault<=0;last_error<=0;
                    snapshot<=scratch;snapshot_valid<=1;state<=HOLD;
                  end else begin cal_count<=cal_count+1;state<=SETTLE;end
                end else begin cal_count<=0;state<=SETTLE;end
              end else begin snapshot<=scratch;snapshot_valid<=1;state<=HOLD;end
            end
          end
          HOLD: if(snapshot_valid && snapshot_ready) begin
            snapshot_valid<=0;timer<=0;state<=SETTLE;
          end
          // SETTLE after calibration is just the periodic poll interval.
          RETRY: if(timer>=RETRY_CYCLES-1) begin
            cfg_index<=0;cal_count<=0;fail_attempts<=0;state<=WRITE;
          end else timer<=timer+1;
          OVCF_LOCK: begin ready<=0;fault<=1;end
          default: state<=WRITE;
        endcase
        if(state==SETTLE && ready && poll_allowed && (timer>=POLL_CYCLES-1 || !irq_n)) begin
          timer<=0;state<=POLL;
        end
      end
    end
endmodule
