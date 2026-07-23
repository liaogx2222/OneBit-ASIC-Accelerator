`timescale 1ns / 1ps

module fp16_adder (
    input  wire        clk,
    input  wire        rst_n,      
    
    // 输入接口 (Slave)
    input  wire        valid_in,
    output wire        ready_in,
    input  wire [15:0] a_in,       
    input  wire [15:0] b_in,       
    
    // 输出接口 (Master)
    output wire        valid_out,
    input  wire        ready_out,
    output wire [15:0] sum_out     
);

    // ====================================================================
    // Stage 1: 解码、FTZ 检查 与 尾数对齐 (Alignment)
    // ====================================================================
    wire sign_a = a_in[15];
    wire sign_b = b_in[15];
    wire [4:0] exp_a = a_in[14:10];
    wire [4:0] exp_b = b_in[14:10];
    
    // FTZ (Flush-To-Zero): 指数为0则尾数强制为0，否则补充隐含位 1
    wire [10:0] mant_a = (exp_a == 5'b00000) ? 11'd0 : {1'b1, a_in[9:0]};
    wire [10:0] mant_b = (exp_b == 5'b00000) ? 11'd0 : {1'b1, b_in[9:0]};

    // 比较大小
    wire a_is_larger = (exp_a > exp_b) || (exp_a == exp_b && mant_a >= mant_b);
    wire [4:0] exp_max  = a_is_larger ? exp_a : exp_b;
    wire [4:0] exp_diff = a_is_larger ? (exp_a - exp_b) : (exp_b - exp_a);

    // 扩展为 14-bit (11位原尾数 + 3位 G,R,S 保护位)
    wire [13:0] mant_large = a_is_larger ? {mant_a, 3'b000} : {mant_b, 3'b000};
    wire [13:0] mant_small = a_is_larger ? {mant_b, 3'b000} : {mant_a, 3'b000};
    
    // 对阶右移，并用掩码捕获所有被移出丢弃的低位，提取真正的 Sticky 标志
    wire [14:0] mask_temp = (15'd1 << exp_diff) - 1'b1;
    wire [13:0] dropped_mask = mask_temp[13:0];
    wire sticky_from_shift = |(mant_small & dropped_mask);
    
    // 右移后，将最低位与 sticky_from_shift 进行逻辑或
    wire [13:0] mant_small_raw = mant_small >> exp_diff;
    wire [13:0] mant_small_aligned = {mant_small_raw[13:1], mant_small_raw[0] | sticky_from_shift};
    
    // Stage 1 -> Stage 2 寄存器
    reg        valid_s1;
    reg        sign_large_s1;
    reg        sign_small_s1;
    reg  [4:0] exp_max_s1;
    reg [13:0] mant_large_s1;
    reg [13:0] mant_small_aligned_s1;

    wire ready_s1; // 由 Stage 2 的反压决定
    assign ready_in = ready_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_s1 <= 1'b0;
        else if (ready_s1) begin
            valid_s1 <= valid_in;
            if (valid_in) begin
                sign_large_s1         <= a_is_larger ? sign_a : sign_b;
                sign_small_s1         <= a_is_larger ? sign_b : sign_a;
                exp_max_s1            <= exp_max;
                mant_large_s1         <= mant_large;
                mant_small_aligned_s1 <= mant_small_aligned;
            end
        end
    end

    // ====================================================================
    // Stage 2: 尾数加减法运算 与 前导零检测 (LOD)
    // ====================================================================
    wire is_sub = (sign_large_s1 != sign_small_s1);
    
    // 15-bit 结果 (最高位是溢出进位 Carry)
    wire [14:0] mant_sum_raw = is_sub ? (mant_large_s1 - mant_small_aligned_s1) 
                                      : (mant_large_s1 + mant_small_aligned_s1);
    
    // 前导零检测 (LOD)：寻找最高位的 1
    reg [4:0] shift_amt;
    reg       carry_out;
    integer i;
    always @(*) begin
        if (mant_sum_raw[14] == 1'b1) begin
            carry_out = 1'b1;     // 加法溢出，需要在 Stage 3 右移
            shift_amt = 5'd0;
        end else begin
            carry_out = 1'b0;
            shift_amt = 5'd15;    // 默认全零情况
            for (i = 13; i >= 0; i = i - 1) begin
                if (mant_sum_raw[i] == 1'b1 && shift_amt == 5'd15) begin
                    shift_amt = 13 - i; // 计算需要左移多少位才能让 1 顶到第 13 位
                end
            end
        end
    end

    // Stage 2 -> Stage 3 寄存器
    reg        valid_s2;
    reg        sign_s2;
    reg  [4:0] exp_max_s2;
    reg [14:0] mant_sum_s2;
    reg  [4:0] shift_amt_s2;
    reg        carry_out_s2;

    wire ready_s2; 
    assign ready_s1 = ready_s2 || !valid_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_s2 <= 1'b0;
        else if (ready_s2) begin
            valid_s2 <= valid_s1;
            if (valid_s1) begin
                sign_s2      <= sign_large_s1; // 结果符号始终跟随大数
                exp_max_s2   <= exp_max_s1;
                mant_sum_s2  <= mant_sum_raw;
                shift_amt_s2 <= shift_amt;
                carry_out_s2 <= carry_out;
            end
        end
    end

    // ====================================================================
    // Stage 3: 规格化、奇偶舍入 (RNE) 与 组装打包
    // ====================================================================
     reg [14:0] mant_norm;
    reg signed [6:0] exp_norm_temp; // 必须用有符号数，防下溢出

    always @(*) begin
        if (carry_out_s2) begin
            // 溢出右移 1 位，最低位与移出的位做 Sticky 或运算
            mant_norm = {1'b0, mant_sum_s2[14:1]};
            mant_norm[0] = mant_sum_s2[1] | mant_sum_s2[0]; 
            exp_norm_temp = $signed({2'b00, exp_max_s2}) + 1;
        end else begin
            // 根据 LOD 结果左移规格化
            mant_norm = mant_sum_s2 << shift_amt_s2;
            exp_norm_temp = $signed({2'b00, exp_max_s2}) - $signed({2'b00, shift_amt_s2});
        end
    end

    // 提取舍入保护位
    wire G = mant_norm[2];
    wire R = mant_norm[1];
    wire S = mant_norm[0];
    wire LSB = mant_norm[3]; // 尾数最低位

    // RNE (Round to Nearest, ties to Even) 奇偶舍入逻辑
    wire round_up = (G & (R | S)) | (G & ~R & ~S & LSB);
    
    // 执行舍入：去掉隐藏位 13，并扩展为 12-bit 以捕获真实的舍入进位
    wire [11:0] mant_rounded = {1'b0, mant_norm[13:3]} + round_up;
    
    // 真正的溢出位出现在第 11 位
    wire round_overflow = mant_rounded[11];
    
    // 检查是否下溢成极小值，若成立按 FTZ 清零
    wire is_tiny = (exp_norm_temp <= 0) || (mant_sum_s2 == 0);
    
    wire [4:0] final_exp  = is_tiny ? 5'd0 : (exp_norm_temp[4:0] + round_overflow);
    wire [9:0] final_mant = is_tiny ? 10'd0 : (round_overflow ? 10'd0 : mant_rounded[9:0]);
    
    // Stage 3 -> 输出寄存器
    reg        valid_s3;
    reg [15:0] sum_out_reg;

    assign ready_s2 = ready_out || !valid_s3;
    assign valid_out = valid_s3;
    assign sum_out   = sum_out_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_s3 <= 1'b0;
        else if (ready_out || !valid_s3) begin
            valid_s3 <= valid_s2;
            if (valid_s2) begin
                sum_out_reg <= {sign_s2, final_exp, final_mant};
            end
        end
    end

endmodule