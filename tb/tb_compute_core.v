// tb/tb_compute_core.v
`timescale 1ns / 1ps

module tb_compute_core;

    reg clk;
    reg rst_n;
    
    // 控制线
    reg load_en;
    reg compute_en;
    reg w_in;
    
    // 数据线
    reg          valid_in;
    wire         ready_in;
    reg  [255:0] x_in_flat;
    reg  [255:0] g_in_flat;
    reg  [255:0] h_in_flat;
    
    wire         valid_out;
    reg          ready_out;
    wire [255:0] y_out_flat;

    // 例化核心
    compute_core u_core (
        .clk(clk), .rst_n(rst_n),
        .load_en(load_en), .compute_en(compute_en), .w_in(w_in),
        .valid_in(valid_in), .ready_in(ready_in),
        .x_in_flat(x_in_flat), .g_in_flat(g_in_flat), .h_in_flat(h_in_flat),
        .valid_out(valid_out), .ready_out(ready_out), .y_out_flat(y_out_flat)
    );

    // 时钟
    initial begin clk = 0; forever #5 clk = ~clk; end

    // 存储器
    reg        W_mem [0:255];
    reg [255:0] G_mem [0:0];
    reg [255:0] H_mem [0:0];
    reg [255:0] X_mem [0:19];
    reg [255:0] Y_mem [0:19];

    integer i;
    integer output_idx = 0;
    integer error_count = 0;

    initial begin
        $readmemb("W_test.txt", W_mem);
        $readmemh("g_test.txt", G_mem);
        $readmemh("h_test.txt", H_mem);
        $readmemh("X_test.txt", X_mem);
        $readmemh("Y_expected.txt", Y_mem);
        
        $dumpfile("compute_core.vcd");
        $dumpvars(0, tb_compute_core);

        // 初始化
        rst_n = 0;
        load_en = 0; compute_en = 0; w_in = 0;
        valid_in = 0; ready_out = 1;
        x_in_flat = 0; g_in_flat = 0; h_in_flat = 0;
        
        #25 rst_n = 1;
        
        // ===============================================
        // 阶段 1: 加载缩放因子 G 和 H (静态)
        // ===============================================
        g_in_flat = G_mem[0];
        h_in_flat = H_mem[0];

        // ===============================================
        // 阶段 2: 装载 1-bit 权重 (Daisy Chain 256 拍)
        // ===============================================
        $display("[%0t] 开始装载 1-bit 权重...", $time);
        load_en = 1;
        for (i = 0; i < 256; i = i + 1) begin
            @(posedge clk); #1;
            w_in = W_mem[i];
        end
        @(posedge clk); #1;
        load_en = 0;
        $display("[%0t] 权重装载完毕！准备启动流式矩阵计算...", $time);
        
        // ===============================================
        // 阶段 3: 启动计算，流式推入激活值 X
        // ===============================================
        #20 compute_en = 1; // 唤醒全系统流水线
        
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk); #1;
            if (ready_in) begin
                valid_in = 1;
                x_in_flat = X_mem[i];
            end else begin
                i = i - 1; // 被反压则原地等待
            end
        end
        
        // 发送完毕，排空流水线
        @(posedge clk); #1;
        valid_in = 0;
    end

    // ===============================================
    // 阶段 4: Monitor 接收结果并比对 (Scoreboard)
    // ===============================================
    initial begin
        while (output_idx < 20) begin
            @(posedge clk); #1;
            if (valid_out && ready_out) begin
                // 比对 256-bit 扁平结果
                if (y_out_flat !== Y_mem[output_idx]) begin
                    $display("[ERROR] 矩阵第 %0d 行结果错误！\nDUT: %h\nEXP: %h", 
                             output_idx, y_out_flat, Y_mem[output_idx]);
                    error_count = error_count + 1;
                end else begin
                    $display("[%0t] 收到并验证通过矩阵第 %0d 行流水线结果", $time, output_idx);
                end
                output_idx = output_idx + 1;
            end
        end
        
        if (error_count == 0)
            $display("\n=======================================================\n[PASS] 16x16 核心矩阵运算 100%% 比特级通过！🏆\n=======================================================\n");
        else
            $display("\n[FAIL] 发现 %0d 个错误。\n", error_count);
            
        $finish;
    end

    // 看门狗
    initial begin
        #100000;
        $display("\n[FATAL] 仿真超时卡死！\n");
        $finish;
    end
endmodule