// rtl/fp16_mul.v
`timescale 1ns / 1ps

module fp16_mul (
    input  wire        clk,
    input  wire        rst_n,
    
    input  wire        valid_in,
    output wire        ready_in,
    input  wire [15:0] a_in,
    input  wire [15:0] b_in,
    
    output wire        valid_out,
    input  wire        ready_out,
    output wire [15:0] mul_out
);

    // ====================================================================
    // Stage 1: FTZ, 符号运算, 指数相加, 尾数相乘
    // ====================================================================
    wire sign_a = a_in[15];
    wire sign_b = b_in[15];
    wire [4:0] exp_a = a_in[14:10];
    wire [4:0] exp_b = b_in[14:10];
    
    // FTZ (Flush-to-Zero) 与 提取隐藏位 1
    wire a_is_zero = (exp_a == 5'd0);
    wire b_is_zero = (exp_b == 5'd0);
    wire [10:0] mant_a = a_is_zero ? 11'd0 : {1'b1, a_in[9:0]};
    wire [10:0] mant_b = b_is_zero ? 11'd0 : {1'b1, b_in[9:0]};

    // 符号：正负得负
    wire sign_out_raw = sign_a ^ sign_b;
    
    // 指数：两指数相加并减去偏移量 (Bias = 15)
    wire signed [6:0] exp_sum_raw = $signed({2'b00, exp_a}) + $signed({2'b00, exp_b}) - 7'sd15;
    
    // 尾数相乘：11-bit * 11-bit = 22-bit
    wire [21:0] mant_mul_raw = mant_a * mant_b;
    
    // Stage 1 -> Stage 2 寄存器
    reg        valid_s1;
    reg        sign_s1;
    reg signed [6:0] exp_s1;
    reg [21:0] mant_mul_s1;
    reg        zero_flag_s1;

    wire ready_s1;
    assign ready_in = ready_s1;
    assign ready_s1 = ready_out || !valid_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_s1 <= 1'b0;
        else if (ready_s1) begin
            valid_s1 <= valid_in;
            if (valid_in) begin
                sign_s1      <= sign_out_raw;
                exp_s1       <= exp_sum_raw;
                mant_mul_s1  <= mant_mul_raw;
                zero_flag_s1 <= (a_is_zero || b_is_zero);
            end
        end
    end

    // ====================================================================
    // Stage 2: 规格化、奇偶舍入 (RNE) 与打包
    // ====================================================================
    // 22-bit 乘积的格式是 [21:20] . [19:0] (因为 1.xx * 1.yy 介于 1.00 到 3.99 之间)
    // 所以最高有效位可能是 bit 21，也可能是 bit 20
    wire norm_shift = mant_mul_s1[21]; 
    
    // [修复 Bug]: 正确截取最高位的隐藏 1 及后续 10 位小数
    wire [10:0] mant_norm = norm_shift ? mant_mul_s1[21:11] : mant_mul_s1[20:10];
    
    // [修复 Bug]: 保护位 G,R,S 跟着修正
    wire G = norm_shift ? mant_mul_s1[10] : mant_mul_s1[9];
    wire R = norm_shift ? mant_mul_s1[9]  : mant_mul_s1[8];
    wire S = norm_shift ? (|mant_mul_s1[8:0]) : (|mant_mul_s1[7:0]);
    wire LSB = mant_norm[0];

    // RNE (Round to Nearest, ties to Even) 奇偶舍入
    wire round_up = (G & (R | S)) | (G & ~R & ~S & LSB);
    wire [11:0] mant_rounded = {1'b0, mant_norm} + round_up; // 加 1 位防止舍入溢出
    
    // 舍入再溢出判定
    wire round_overflow = mant_rounded[11];
    
    // 最终指数调整
    wire signed [6:0] exp_norm = exp_s1 + norm_shift + round_overflow;
    
    // FTZ 与 下溢出判断
    wire is_tiny = zero_flag_s1 || (exp_norm <= 0);
    
    wire [4:0] final_exp  = is_tiny ? 5'd0 : exp_norm[4:0];
    wire [9:0] final_mant = is_tiny ? 10'd0 : (round_overflow ? 10'd0 : mant_rounded[9:0]);

    // Stage 2 -> 输出寄存器
    reg        valid_s2;
    reg [15:0] mul_out_reg;

    assign valid_out = valid_s2;
    assign mul_out   = mul_out_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_s2 <= 1'b0;
        else if (ready_out || !valid_s2) begin
            valid_s2 <= valid_s1;
            if (valid_s1) begin
                mul_out_reg <= {sign_s1, final_exp, final_mant};
            end
        end
    end

endmodule