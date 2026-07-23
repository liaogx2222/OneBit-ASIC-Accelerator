// rtl/pingpong_buffer.v
`timescale 1ns / 1ps

module pingpong_buffer #(
    parameter DATA_WIDTH = 256,
    parameter DEPTH      = 512,
    parameter ADDR_WIDTH = 9
)(
    input  wire                  clk,
    input  wire                  rst_n,
    
    // 乒乓切换信号 (脉冲)
    input  wire                  switch_bank,
    
    // ==========================================
    // 外部写接口 (来自 DMA/AXI 接收侧)
    // ==========================================
    input  wire                  ext_we,
    input  wire [ADDR_WIDTH-1:0] ext_w_addr,
    input  wire [DATA_WIDTH-1:0] ext_w_data,
    
    // ==========================================
    // 内部读接口 (发往 脉动阵列/打偏网络)
    // ==========================================
    input  wire                  arr_re,
    input  wire [ADDR_WIDTH-1:0] arr_r_addr,
    output wire [DATA_WIDTH-1:0] arr_r_data
);

    // 状态寄存器 (0: 写Bank0/读Bank1 | 1: 写Bank1/读Bank0)
    reg pp_state;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) 
            pp_state <= 1'b0;
        else if (switch_bank)
            pp_state <= ~pp_state;
    end

    // 内部连线
    wire                  we_0, we_1;
    wire                  re_0, re_1;
    wire [ADDR_WIDTH-1:0] w_addr_0, w_addr_1;
    wire [ADDR_WIDTH-1:0] r_addr_0, r_addr_1;
    wire [DATA_WIDTH-1:0] w_data_0, w_data_1;
    wire [DATA_WIDTH-1:0] r_data_0, r_data_1;

    // ----------------------------------------------------
    // DEMUX: 写端口路由
    // ----------------------------------------------------
    assign we_0     = (pp_state == 1'b0) ? ext_we : 1'b0;
    assign w_addr_0 = (pp_state == 1'b0) ? ext_w_addr : {ADDR_WIDTH{1'b0}};
    assign w_data_0 = (pp_state == 1'b0) ? ext_w_data : {DATA_WIDTH{1'b0}};

    assign we_1     = (pp_state == 1'b1) ? ext_we : 1'b0;
    assign w_addr_1 = (pp_state == 1'b1) ? ext_w_addr : {ADDR_WIDTH{1'b0}};
    assign w_data_1 = (pp_state == 1'b1) ? ext_w_data : {DATA_WIDTH{1'b0}};

    // ----------------------------------------------------
    // DEMUX: 读端口路由 (注意状态是反过来的)
    // ----------------------------------------------------
    assign re_0     = (pp_state == 1'b1) ? arr_re : 1'b0;
    assign r_addr_0 = (pp_state == 1'b1) ? arr_r_addr : {ADDR_WIDTH{1'b0}};

    assign re_1     = (pp_state == 1'b0) ? arr_re : 1'b0;
    assign r_addr_1 = (pp_state == 1'b0) ? arr_r_addr : {ADDR_WIDTH{1'b0}};

    // ----------------------------------------------------
    // MUX: 读数据聚合
    // ----------------------------------------------------
    assign arr_r_data = (pp_state == 1'b1) ? r_data_0 : r_data_1;

    // ----------------------------------------------------
    // 实例化两块 SDP SRAM
    // ----------------------------------------------------
    sdp_sram #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) bank0 (
        .clk    (clk),
        .we     (we_0),
        .w_addr (w_addr_0),
        .w_data (w_data_0),
        .re     (re_0),
        .r_addr (r_addr_0),
        .r_data (r_data_0)
    );

    sdp_sram #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) bank1 (
        .clk    (clk),
        .we     (we_1),
        .w_addr (w_addr_1),
        .w_data (w_data_1),
        .re     (re_1),
        .r_addr (r_addr_1),
        .r_data (r_data_1)
    );

endmodule