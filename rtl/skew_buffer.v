// rtl/skew_buffer.v
`timescale 1ns / 1ps

module skew_buffer #(
    parameter DELAY = 0
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,         // 全局数据步进使能
    input  wire [15:0] d_in,
    output wire [15:0] d_out
);

    generate
        if (DELAY == 0) begin : gen_no_delay
            // 延迟为 0 的情况（第 0 行），直接连线穿透
            assign d_out = d_in;
        end else begin : gen_delay
            // 定义存储器阵列 (在综合时会被映射为寄存器堆 Register File)
            reg [15:0] mem [0:DELAY-1];
            // 定义读写共用指针 (使用 8-bit，最大支持 255 的深度，足够本设计使用)
            reg [7:0]  ptr;
            
            // 【巧妙逻辑】先读取旧值（组合逻辑读）
            assign d_out = mem[ptr]; 
            
            // 时序逻辑：写入新值并更新指针
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    ptr <= 8'd0;
                    // mem 数组无需复位，节省大量布线资源，初值依靠管线填满即可
                end else if (en) begin
                    mem[ptr] <= d_in;
                    if (ptr == DELAY - 1)
                        ptr <= 8'd0;
                    else
                        ptr <= ptr + 8'd1;
                end
            end
        end
    endgenerate

endmodule