// rtl/pe.v
`timescale 1ns / 1ps

module pe (
    input  wire        clk,
    input  wire        rst_n,

    // 全局状态控制 (合成工具会自动推断出 Clock Gating)
    input  wire        load_en,    // 权重加载使能
    input  wire        compute_en, // 矩阵计算使能

    // ==========================================
    // LOAD 状态：权重链式装载接口 (Daisy Chain)
    // ==========================================
    input  wire        w_in,
    output reg         w_out,      // 既是当前 PE 的权重，也连给下一个 PE

    // ==========================================
    // COMPUTE 状态：统一流水线握手接口 (Datapath)
    // ==========================================
    input  wire        valid_in,
    output wire        ready_in,
    input  wire [15:0] x_in,       // 激活值输入 (来自左侧)
    input  wire [15:0] p_in,       // 部分和输入 (来自上方)

    output wire        valid_out,
    input  wire        ready_out,
    output wire [15:0] x_out,      // 激活值输出 (传给右侧)
    output wire [15:0] p_out       // 部分和输出 (传给下方)
);

    // --------------------------------------------------------
    // 1. 权重驻留 (Weight Stationary) - 1-bit 移位寄存器
    // --------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_out <= 1'b0;
        end else if (load_en) begin
            w_out <= w_in;
        end
        // 没有 else，暗示 load_en 为 0 时保持不变 (自动锁存)
    end

    // --------------------------------------------------------
    // 2. OneBit 核心魔法：消除 FP16 乘法器！
    // --------------------------------------------------------
    // 若 w_out == 1 (代表 +1)，符号位不变；若 w_out == 0 (代表 -1)，符号位反转
    wire [15:0] x_mod = {x_in[15] ^ ~w_out, x_in[14:0]};

    // --------------------------------------------------------
    // 3. 例化 3 级流水线 FP16 加法器 (计算 p_out = p_in + x_mod)
    // --------------------------------------------------------
    // 这里利用 compute_en 对输入 valid 进行门控。不计算时，加法器全线休眠。
    wire adder_valid_in = valid_in & compute_en;
    
    fp16_adder u_fp16_adder (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (adder_valid_in),
        .ready_in   (ready_in),        // PE 的 ready_in 直接取自加法器
        .a_in       (p_in),
        .b_in       (x_mod),           // 变号后的激活值
        .valid_out  (valid_out),
        .ready_out  (ready_out),
        .sum_out    (p_out)
    );

    // --------------------------------------------------------
    // 4. 激活值 3 级延迟线 (保证 2D 脉动阵列水平与垂直方向同步)
    // --------------------------------------------------------
    // 极其重要：因为加法器有 3 级延迟，p_out 是在 3 拍后向下传递的。
    // 为了保证时空同步，水平传递的 x_out 也必须同步延迟 3 拍！
    
    reg [15:0] x_s1, x_s2, x_s3;
    reg        v_s1, v_s2, v_s3;

    wire ready_s2 = ready_out || !v_s3;
    wire ready_s1 = ready_s2  || !v_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_s1 <= 1'b0; v_s2 <= 1'b0; v_s3 <= 1'b0;
            x_s1 <= 16'd0; x_s2 <= 16'd0; x_s3 <= 16'd0;
        end else if (compute_en) begin
            // Stage 3
            if (ready_out || !v_s3) begin
                v_s3 <= v_s2;
                if (v_s2) x_s3 <= x_s2;
            end
            // Stage 2
            if (ready_s2) begin
                v_s2 <= v_s1;
                if (v_s1) x_s2 <= x_s1;
            end
            // Stage 1
            if (ready_s1) begin
                v_s1 <= valid_in;
                if (valid_in) x_s1 <= x_in;
            end
        end
    end

    assign x_out = x_s3;

endmodule