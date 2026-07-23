// rtl/skew_network.v
`timescale 1ns / 1ps

module skew_network #(
    parameter ROWS = 16,
    parameter DELAY_PER_ROW = 3 // 每增加一行，额外延迟 3 个周期
)(
    input  wire clk,
    input  wire rst_n,
    input  wire en,             // 阵列处于计算态并吸入数据时使能
    
    input  wire [ROWS*16-1:0] x_in_flat,
    output wire [ROWS*16-1:0] x_out_skewed_flat
);

    genvar i;
    generate
        for (i = 0; i < ROWS; i = i + 1) begin : row_skew
            // 计算当前行需要的绝对延迟拍数
            localparam CURRENT_DELAY = i * DELAY_PER_ROW;
            
            // 切片提取该行的 16-bit 输入
            wire [15:0] current_row_in = x_in_flat[i*16 +: 16];
            wire [15:0] current_row_out;
            
            // 实例化环形缓冲区
            skew_buffer #(
                .DELAY(CURRENT_DELAY)
            ) u_skew_buf (
                .clk   (clk),
                .rst_n (rst_n),
                .en    (en),
                .d_in  (current_row_in),
                .d_out (current_row_out)
            );
            
            // 将打偏后的输出拼接回一维拉平总线
            assign x_out_skewed_flat[i*16 +: 16] = current_row_out;
        end
    endgenerate

endmodule