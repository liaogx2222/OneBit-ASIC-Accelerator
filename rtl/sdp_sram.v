// rtl/sdp_sram.v
`timescale 1ns / 1ps

// 1R1W (Simple Dual Port) SRAM 模型
(* blackbox *)
module sdp_sram #(
    parameter DATA_WIDTH = 256,
    parameter DEPTH      = 512,  // 足够容纳打偏和分块数据
    parameter ADDR_WIDTH = 9
)(
    input  wire                  clk,
    
    // 写端口 (Write Port)
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] w_addr,
    input  wire [DATA_WIDTH-1:0] w_data,
    
    // 读端口 (Read Port)
    input  wire                  re,
    input  wire [ADDR_WIDTH-1:0] r_addr,
    output reg  [DATA_WIDTH-1:0] r_data
);

    // 定义存储器阵列
    reg [DATA_WIDTH-1:0] ram [0:DEPTH-1];
    
    // 写逻辑
    always @(posedge clk) begin
        if (we) begin
            ram[w_addr] <= w_data;
        end
    end
    
    // 读逻辑 (同步读取，数据在下一个时钟沿有效)
    always @(posedge clk) begin
        if (re) begin
            r_data <= ram[r_addr];
        end
    end

endmodule