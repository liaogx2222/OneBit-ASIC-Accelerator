// rtl/systolic_array.v
`timescale 1ns / 1ps

module systolic_array #(
    parameter ROWS = 16,
    parameter COLS = 16
)(
    input  wire clk,
    input  wire rst_n,
    
    // 全局门控控制
    input  wire load_en,
    input  wire compute_en,

    // 1-bit 权重链入口
    input  wire w_in,

    // ==========================================
    // 左侧接口: 激活值 X 输入 (一维拉平: 16 * 16 = 256 bit)
    // ==========================================
    input  wire [ROWS*16-1:0] x_in_flat,

    // ==========================================
    // 顶部接口: 部分和 P 输入 (通常外部给 0) 及握手
    // ==========================================
    input  wire [COLS*16-1:0] p_in_flat,
    input  wire [COLS-1:0]    valid_in,
    output wire [COLS-1:0]    ready_in,

    // ==========================================
    // 底部接口: 最终结果 P 输出 及握手
    // ==========================================
    output wire [COLS*16-1:0] p_out_flat,
    output wire [COLS-1:0]    valid_out,
    input  wire [COLS-1:0]    ready_out
);

    // --------------------------------------------------------
    // 1. 定义内部二维织网线缆 (2D Wire Arrays)
    // --------------------------------------------------------
    // x_wire[i][j] 表示第 i 行，连接第 j 列和第 j+1 列的 X 数据线
    wire [15:0] x_wire [0:ROWS-1][0:COLS]; 
    
    // p_wire[i][j] 表示第 j 列，连接第 i 行和第 i+1 行的 P 数据线
    wire [15:0] p_wire [0:ROWS][0:COLS-1]; 
    
    // valid 和 ready 握手信号线 (垂直流向与 P 绑定)
    wire        v_wire [0:ROWS][0:COLS-1];
    wire        r_wire [0:ROWS][0:COLS-1];
    
    // 权重 Daisy Chain 移位线 (256个PE需要257个节点连接)
    wire        w_wire [0:ROWS*COLS];

    // --------------------------------------------------------
    // 2. 边界端口映射 (Boundary Assignments)
    // --------------------------------------------------------
    genvar i, j;
    generate
        // A. 左侧输入边界：将 256-bit 拆解挂到每行的输入线上
        for (i = 0; i < ROWS; i = i + 1) begin : x_bound
            assign x_wire[i][0] = x_in_flat[i*16 +: 16]; 
            // 注意: i*16 +: 16 是 Verilog 2001 优雅的切片语法，表示从 i*16 开始向上取 16 位
        end

        // B. 顶部与底部边界
        for (j = 0; j < COLS; j = j + 1) begin : p_bound
            // 顶部输入挂载
            assign p_wire[0][j] = p_in_flat[j*16 +: 16];
            assign v_wire[0][j] = valid_in[j];
            assign ready_in[j]  = r_wire[0][j]; // 阵列的 ready 是由第 0 行反馈给顶部的

            // 底部输出挂载
            assign p_out_flat[j*16 +: 16] = p_wire[ROWS][j];
            assign valid_out[j]           = v_wire[ROWS][j];
            assign r_wire[ROWS][j]        = ready_out[j]; // 外部把 ready_out 给到底部第 16 行
        end
    endgenerate

    // 权重链入口
    assign w_wire[0] = w_in;

    // --------------------------------------------------------
    // 3. 核心大招：二维阵列批量例化 (Array Generation)
    // --------------------------------------------------------
    generate
        for (i = 0; i < ROWS; i = i + 1) begin : row_gen
            for (j = 0; j < COLS; j = j + 1) begin : col_gen
                
                // 实例化我们的细胞：PE
                pe u_pe (
                    .clk        (clk),
                    .rst_n      (rst_n),
                    
                    // 全局控制
                    .load_en    (load_en),
                    .compute_en (compute_en),
                    
                    // 权重串联 (前一个连进来，连向下一个)
                    .w_in       (w_wire[i*COLS + j]),
                    .w_out      (w_wire[i*COLS + j + 1]),
                    
                    // 握手信号 (垂直传递)
                    .valid_in   (v_wire[i][j]),
                    .ready_in   (r_wire[i][j]),       // PE的输出ready，连向上面的线
                    .valid_out  (v_wire[i+1][j]),
                    .ready_out  (r_wire[i+1][j]),     // 接收下面的ready
                    
                    // 数据流
                    .x_in       (x_wire[i][j]),       // 左侧来
                    .x_out      (x_wire[i][j+1]),     // 去右侧
                    .p_in       (p_wire[i][j]),       // 上方来
                    .p_out      (p_wire[i+1][j])      // 去下方
                );
                
            end
        end
    endgenerate

endmodule