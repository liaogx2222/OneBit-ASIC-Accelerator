// rtl/compute_core.v
`timescale 1ns / 1ps

module compute_core #(
    parameter ROWS = 16,
    parameter COLS = 16
)(
    input  wire clk,
    input  wire rst_n,

    input  wire load_en,
    input  wire compute_en,
    input  wire w_in,

    input  wire                 valid_in,
    output wire                 ready_in,
    input  wire [ROWS*16-1:0]   x_in_flat,
    input  wire [ROWS*16-1:0]   g_in_flat, 
    input  wire [COLS*16-1:0]   h_in_flat, 

    output wire                 valid_out,
    input  wire                 ready_out,
    output wire [COLS*16-1:0]   y_out_flat
);

    // =========================================================
    // 1. 预处理缩放 (Pre-Scaling): X = X * g
    // =========================================================
    wire [ROWS*16-1:0] x_scaled_flat;
    wire [ROWS-1:0]    pre_mul_valid_out_arr;
    wire [ROWS-1:0]    pre_mul_ready_in_arr;
    
    wire pre_mul_valid_out = pre_mul_valid_out_arr[0];
    wire array_ready_in; 
    assign ready_in = pre_mul_ready_in_arr[0]; 
    
    genvar i, j;
    generate
        for (i = 0; i < ROWS; i = i + 1) begin : pre_mul_gen
            fp16_mul u_pre_mul (
                .clk       (clk),
                .rst_n     (rst_n),
                .valid_in  (valid_in & compute_en),
                .ready_in  (pre_mul_ready_in_arr[i]),
                .a_in      (x_in_flat[i*16 +: 16]),
                .b_in      (g_in_flat[i*16 +: 16]),
                .valid_out (pre_mul_valid_out_arr[i]),
                .ready_out (array_ready_in), 
                .mul_out   (x_scaled_flat[i*16 +: 16])
            );
        end
    endgenerate

    // =========================================================
    // 2. 行时间扭曲 (Row Skewing): X 延迟 3*i
    // =========================================================
    wire [ROWS*16-1:0] x_skewed_flat;
    
    skew_network #(
        .ROWS(ROWS),
        .DELAY_PER_ROW(3)
    ) u_skew (
        .clk               (clk),
        .rst_n             (rst_n),
        // [修复2]: 只要阵列没满，传送带就永远转动，排泄内部残留数据！
        .en                (array_ready_in), 
        .x_in_flat         (x_scaled_flat),
        .x_out_skewed_flat (x_skewed_flat)
    );

    // =========================================================
    // 3. 列时间扭曲 (Col Skewing): Valid 延迟 3*j
    // =========================================================
    wire [COLS-1:0] array_valid_in_skewed;
    generate
        for (j = 0; j < COLS; j = j + 1) begin : col_skew_in
            if (j == 0) begin
                assign array_valid_in_skewed[j] = pre_mul_valid_out;
            end else begin
                // 手工移位寄存器，每列多延迟 3 拍
                reg [3*j-1:0] v_shift;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) v_shift <= 0;
                    else if (array_ready_in) begin
                        v_shift <= {v_shift[3*j-2:0], pre_mul_valid_out};
                    end
                end
                assign array_valid_in_skewed[j] = v_shift[3*j-1];
            end
        end
    endgenerate

    // =========================================================
    // 4. 16x16 脉动阵列 (Systolic Array)
    // =========================================================
    wire [COLS*16-1:0] p_sum_flat;
    wire [COLS-1:0]    array_valid_out_arr;
    
    wire post_mul_ready_in; 
    assign array_ready_in = post_mul_ready_in;
    
    systolic_array #(
        .ROWS(ROWS),
        .COLS(COLS)
    ) u_array (
        .clk         (clk),
        .rst_n       (rst_n),
        .load_en     (load_en),
        .compute_en  (compute_en),
        .w_in        (w_in),
        
        .x_in_flat   (x_skewed_flat),
        .p_in_flat   ({(COLS*16){1'b0}}), 
        
        // [修复1]: 喂入经过完美列偏移打拍的 Valid 信号
        .valid_in    (array_valid_in_skewed),
        .ready_in    (), 
        
        .p_out_flat  (p_sum_flat),
        .valid_out   (array_valid_out_arr),
        .ready_out   ({COLS{post_mul_ready_in}}) 
    );

    // =========================================================
    // 5. 列逆向去偏 (Col De-skewing): 对齐输出波前
    // =========================================================
    // 因为第 0 列最先算完，第 15 列最后算完。为了让它们同时输出，
    // 我们必须把第 j 列的数据强行等待 3*(15-j) 个周期！
    wire [COLS*16-1:0] p_sum_deskewed_flat;
    wire [COLS-1:0]    array_valid_deskewed_arr;

    generate
        for (j = 0; j < COLS; j = j + 1) begin : col_deskew_out
            localparam DESKEW = 3 * (COLS - 1 - j);
            if (DESKEW == 0) begin
                assign p_sum_deskewed_flat[j*16 +: 16] = p_sum_flat[j*16 +: 16];
                assign array_valid_deskewed_arr[j]     = array_valid_out_arr[j];
            end else begin
                skew_buffer #(
                    .DELAY(DESKEW)
                ) u_deskew_buf (
                    .clk   (clk),
                    .rst_n (rst_n),
                    .en    (post_mul_ready_in), // 传送带持续转动
                    .d_in  (p_sum_flat[j*16 +: 16]),
                    .d_out (p_sum_deskewed_flat[j*16 +: 16])
                );
                
                reg [DESKEW-1:0] v_deskew_shift;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) v_deskew_shift <= 0;
                    else if (post_mul_ready_in) begin
                        v_deskew_shift <= {v_deskew_shift[DESKEW-2:0], array_valid_out_arr[j]};
                    end
                end
                assign array_valid_deskewed_arr[j] = v_deskew_shift[DESKEW-1];
            end
        end
    endgenerate

    // =========================================================
    // 6. 后处理缩放 (Post-Scaling): Y = S * h
    // =========================================================
    wire [COLS-1:0] post_mul_valid_out_arr;
    wire [COLS-1:0] post_mul_ready_in_arr;
    
    assign post_mul_ready_in = post_mul_ready_in_arr[0];
    assign valid_out = post_mul_valid_out_arr[0];

    generate
        for (j = 0; j < COLS; j = j + 1) begin : post_mul_gen
            fp16_mul u_post_mul (
                .clk       (clk),
                .rst_n     (rst_n),
                // 使用去偏对齐后的信号
                .valid_in  (array_valid_deskewed_arr[j]), 
                .ready_in  (post_mul_ready_in_arr[j]),
                .a_in      (p_sum_deskewed_flat[j*16 +: 16]),
                .b_in      (h_in_flat[j*16 +: 16]),
                .valid_out (post_mul_valid_out_arr[j]),
                .ready_out (ready_out), 
                .mul_out   (y_out_flat[j*16 +: 16])
            );
        end
    endgenerate

endmodule