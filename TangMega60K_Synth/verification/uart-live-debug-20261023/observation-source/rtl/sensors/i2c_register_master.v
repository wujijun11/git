// Single-master open-drain I2C register transactions. No driven logic-one.
// cmd_len is 1..43 for reads; writes carry one data byte. All commands latched.
module i2c_register_master #(
    parameter integer CLK_HZ=49152000, I2C_HZ=400000,
    parameter integer TIMEOUT_CYCLES=CLK_HZ/200
)(
    input wire clk, resetn, cmd_valid, cmd_read,
    input wire [6:0] cmd_addr,
    input wire [7:0] cmd_reg, cmd_wdata,
    input wire [5:0] cmd_len,
    output wire cmd_ready, output wire busy,
    output reg done, output reg [2:0] error,
    output reg rdata_valid, output reg [7:0] rdata,
    output reg [5:0] rindex, inout wire scl, sda
);
    // 400 kHz fast-mode requires tLOW >=1.3 us, tHIGH >=0.7 us.
    localparam integer PERIOD=(CLK_HZ+I2C_HZ-1)/I2C_HZ;
    localparam integer LOW_SPEC=(CLK_HZ*13+9999999)/10000000;
    localparam integer LO=(LOW_SPEC>PERIOD/2)?LOW_SPEC:PERIOD/2;
    localparam integer LOW_T=(LO<4)?4:LO;
    localparam integer HI=PERIOD-LOW_T;
    localparam integer HIGH_T=(HI<4)?4:HI;
    localparam [4:0] IDLE=0, FREE=1, START=2, TX_LOW=3, TX_HIGH=4,
      ACK_LOW=5, ACK_HIGH=6, RESTART_LOW=7, RESTART_HIGH=8,
      RX_LOW=9, RX_HIGH=10, MACK_LOW=11, MACK_HIGH=12,
      STOP_LOW=13, STOP_HIGH=14, STOP_FREE=15,CLEAR_LOW=16,CLEAR_HIGH=17;
    reg [4:0] state;
    reg scl_low,sda_low;
    reg [1:0] scl_sync,sda_sync;
    reg [31:0] timer, watchdog;
    reg [7:0] txbyte,rxbyte,reg_latched,data_latched;
    reg [6:0] addr_latched;
    reg read_latched;
    reg [5:0] len_latched,index;
    reg [2:0] bitno;
    reg [1:0] phase;
    reg recovering,recovery_tried;reg [3:0] clear_count;
    assign scl=scl_low?1'b0:1'bz;
    assign sda=sda_low?1'b0:1'bz;
    assign busy=(state!=IDLE);
    assign cmd_ready=(state==IDLE);
    always @(posedge clk) begin
        scl_sync<={scl_sync[0],scl}; sda_sync<={sda_sync[0],sda};
        if (!resetn) begin
            state<=IDLE; scl_low<=0; sda_low<=0; done<=0; error<=0;
            rdata_valid<=0; rdata<=0; rindex<=0; timer<=0; watchdog<=0;
            scl_sync<=3; sda_sync<=3; index<=0; bitno<=7; phase<=0;
            txbyte<=0; rxbyte<=0; reg_latched<=0; data_latched<=0;
            addr_latched<=0; read_latched<=0; len_latched<=1;
            recovering<=0;recovery_tried<=0;clear_count<=0;
        end else begin
            done<=0; rdata_valid<=0;
            if (state!=IDLE) watchdog<=watchdog+1;
            if (state!=IDLE && watchdog>=TIMEOUT_CYCLES-1) begin
                // A stuck line cannot support STOP: release both, report failure.
                state<=IDLE; scl_low<=0; sda_low<=0; done<=1;
                error<=(state==FREE || recovering)?3'd3:3'd2; timer<=0;
            end else case (state)
            IDLE: if (cmd_valid) begin
                addr_latched<=cmd_addr; reg_latched<=cmd_reg;
                data_latched<=cmd_wdata; read_latched<=cmd_read;
                len_latched<=(cmd_len==0)?1:cmd_len;
                index<=0; phase<=0; txbyte<={cmd_addr,1'b0}; bitno<=7;
                state<=FREE; timer<=0; watchdog<=0; error<=0;
                recovering<=0;recovery_tried<=0;
                scl_low<=0; sda_low<=0;
            end
            FREE: if (scl_sync[1] && sda_sync[1]) begin
                if (timer==LOW_T-1) begin sda_low<=1; timer<=0; state<=START; end
                else timer<=timer+1;
            end else if(scl_sync[1] && !sda_sync[1] && !recovery_tried) begin
                // A reset during a slave read can leave SDA held low. Single-master
                // bus clear: nine SCL pulses, NACK (released SDA), then STOP.
                recovering<=1;recovery_tried<=1;clear_count<=0;
                scl_low<=1;sda_low<=0;timer<=0;state<=CLEAR_LOW;
            end else timer<=0;
            START: if (timer==HIGH_T-1) begin
                scl_low<=1; sda_low<=~txbyte[7]; timer<=0; state<=TX_LOW;
            end else timer<=timer+1;
            TX_LOW: if (timer==LOW_T-1) begin
                scl_low<=0; timer<=0; state<=TX_HIGH;
            end else timer<=timer+1;
            TX_HIGH: if (scl_sync[1]) begin
                if (timer==HIGH_T-1) begin
                    scl_low<=1; timer<=0;
                    if (bitno==0) begin sda_low<=0; state<=ACK_LOW; end
                    else begin bitno<=bitno-1; sda_low<=~txbyte[bitno-1]; state<=TX_LOW; end
                end else timer<=timer+1;
            end
            ACK_LOW: if (timer==LOW_T-1) begin scl_low<=0; timer<=0; state<=ACK_HIGH; end
              else timer<=timer+1;
            ACK_HIGH: if (scl_sync[1]) begin
                if (timer==HIGH_T-1) begin
                    scl_low<=1; timer<=0; bitno<=7;
                    if (sda_sync[1]) begin error<=1; sda_low<=1; state<=STOP_LOW; end
                    else case(phase)
                    0: begin phase<=1; txbyte<=reg_latched; sda_low<=~reg_latched[7]; state<=TX_LOW; end
                    1: if (read_latched) begin sda_low<=0; state<=RESTART_LOW; end
                       else begin phase<=2; txbyte<=data_latched; sda_low<=~data_latched[7]; state<=TX_LOW; end
                    2: begin sda_low<=1; state<=STOP_LOW; end
                    3: begin rxbyte<=0; sda_low<=0; state<=RX_LOW; end
                    endcase
                end else timer<=timer+1;
            end
            RESTART_LOW: if (timer==LOW_T-1) begin scl_low<=0; timer<=0; state<=RESTART_HIGH; end
              else timer<=timer+1;
            RESTART_HIGH: if(scl_sync[1]) begin
                if(timer==HIGH_T-1) begin
                    sda_low<=1; timer<=0; txbyte<={addr_latched,1'b1}; phase<=3; state<=START;
                end else timer<=timer+1;
            end
            RX_LOW: if(timer==LOW_T-1) begin scl_low<=0; timer<=0; state<=RX_HIGH; end
              else timer<=timer+1;
            RX_HIGH: if(scl_sync[1]) begin
                if(timer==HIGH_T-1) begin
                    scl_low<=1; timer<=0; rxbyte<={rxbyte[6:0],sda_sync[1]};
                    if(bitno==0) begin
                        rdata<={rxbyte[6:0],sda_sync[1]}; rindex<=index; rdata_valid<=1;
                        sda_low<=(index+1<len_latched); state<=MACK_LOW;
                    end else begin bitno<=bitno-1; state<=RX_LOW; end
                end else timer<=timer+1;
            end
            MACK_LOW: if(timer==LOW_T-1) begin scl_low<=0; timer<=0; state<=MACK_HIGH; end
              else timer<=timer+1;
            MACK_HIGH: if(scl_sync[1]) begin
                if(timer==HIGH_T-1) begin
                    scl_low<=1; timer<=0;
                    if(index+1==len_latched) begin sda_low<=1; state<=STOP_LOW; end
                    else begin index<=index+1; bitno<=7; rxbyte<=0; sda_low<=0; state<=RX_LOW; end
                end else timer<=timer+1;
            end
            STOP_LOW: if(timer==LOW_T-1) begin scl_low<=0; timer<=0; state<=STOP_HIGH; end
              else timer<=timer+1;
            STOP_HIGH: if(scl_sync[1]) begin
                if(timer==HIGH_T-1) begin sda_low<=0; timer<=0; state<=STOP_FREE; end
                else timer<=timer+1;
            end
            STOP_FREE: if(timer==LOW_T-1) begin
                timer<=0;
                if(recovering) begin recovering<=0;state<=FREE;end
                else begin done<=1;state<=IDLE;end
            end
              else timer<=timer+1;
            CLEAR_LOW:if(timer==LOW_T-1) begin scl_low<=0;timer<=0;state<=CLEAR_HIGH;end
              else timer<=timer+1;
            CLEAR_HIGH:if(scl_sync[1]) begin
                if(timer==HIGH_T-1) begin
                    scl_low<=1;timer<=0;
                    if(clear_count==8) begin sda_low<=1;state<=STOP_LOW;end
                    else begin clear_count<=clear_count+1;state<=CLEAR_LOW;end
                end else timer<=timer+1;
            end
            default: state<=IDLE;
            endcase
        end
    end
endmodule
