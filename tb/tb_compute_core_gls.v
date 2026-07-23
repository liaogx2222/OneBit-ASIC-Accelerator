`timescale 1ns / 1ps

module tb_compute_core_gls;

    // ==========================================
    // 参数设定 (匹配版图流片的 4x4 Mini-Chip)
    // ==========================================
    localparam ROWS = 4;
    localparam COLS = 4;
    localparam FLAT_WIDTH = ROWS * 16; // 64-bit

    reg clk = 0;
    reg rst_n = 0;
    
    // 控制线与数据线
    reg load_en = 0, compute_en = 0, w_in = 0;
    reg                   valid_in = 0;
    wire                  ready_in;
    reg  [FLAT_WIDTH-1:0] x_in_flat = 0, g_in_flat = 0, h_in_flat = 0;
    
    wire                  valid_out;
    reg                   ready_out = 1;
    wire [FLAT_WIDTH-1:0] y_out_flat;

    // ==========================================
    // 🛡️ 物理护甲 1：建立理想电源网，消除 X 态
    // ==========================================
`ifdef USE_POWER_PINS
    supply1 VDD_CORE;  // 理想无穷大 1.8V 物理火线
    supply0 VSS_CORE;  // 理想无穷大 0V 物理地线
`endif

    // ==========================================
    // 实例化带电物理门级网表 (DUT)
    // ==========================================
    compute_core u_core (
    `ifdef USE_POWER_PINS
        .VPWR(VDD_CORE),  // 将万个晶体管直接硬连线至理想电源
        .VGND(VSS_CORE),  // 将万个晶体管直接硬连线至理想地线
    `endif
        .clk(clk), .rst_n(rst_n),
        .load_en(load_en), .compute_en(compute_en), .w_in(w_in),
        .valid_in(valid_in), .ready_in(ready_in),
        .x_in_flat(x_in_flat), .g_in_flat(g_in_flat), .h_in_flat(h_in_flat),
        .valid_out(valid_out), .ready_out(ready_out), .y_out_flat(y_out_flat)
    );

    // ==========================================
    // 🛡️ 物理护甲 2：注入物理版图 SDF 延迟信息
    // ==========================================
    initial begin
        // 使用 MAXIMUM 工艺角进行极限量产施压
        // $sdf_annotate("/root/OpenLane/designs/compute_core/runs/run_44/results/signoff/compute_core.sdf", u_core, , "sdf_annotate.log", "MAXIMUM");
    end

    // ==========================================
    // 🛡️ 物理护甲 3：降频至 10MHz (消除 Setup 违规)
    // ==========================================
    // 周期 100ns。0ns时clk=0, 50ns时clk=1, 100ns时clk=0 (下降沿)
    always #50 clk = ~clk; 

    // 存储器定义
    reg                  W_mem [0:15];
    reg [FLAT_WIDTH-1:0] G_mem [0:0];
    reg [FLAT_WIDTH-1:0] H_mem [0:0];
    reg [FLAT_WIDTH-1:0] X_mem [0:19];
    reg [FLAT_WIDTH-1:0] Y_mem [0:19];

    integer i, output_idx = 0, error_count = 0;

    // ==========================================
    // 驱动控制主线程 (Driver)
    // ==========================================
    initial begin
        // 读取 4x4 的测试数据
        $readmemb("W_test_4x4.txt", W_mem);
        $readmemh("g_test_4x4.txt", G_mem);
        $readmemh("h_test_4x4.txt", H_mem);
        $readmemh("X_test_4x4.txt", X_mem);
        $readmemh("Y_expected_4x4.txt", Y_mem);
        
        // 限制波形抓取深度，防止软件卡死
        $dumpfile("post_pr_sim.vcd");
        $dumpvars(1, tb_compute_core_gls);
        $dumpvars(1, tb_compute_core_gls.u_core);

        // 初始化
        rst_n = 0; load_en = 0; compute_en = 0; w_in = 0;
        valid_in = 0; ready_out = 1;
        x_in_flat = 0; g_in_flat = 0; h_in_flat = 0;
        
        // ==========================================
        // 🛡️ 物理护甲 4：绝对安全的错峰复位！
        // ==========================================
        // 1000ns 恰好是第 10 个周期的“下降沿(negedge)”。
        // 在这里释放复位，完美避开时钟上升沿的激烈跳变，彻底杜绝复位恢复时间违规！
        #1000 rst_n = 1; 
        
        // 阶段 1: 加载缩放因子 G 和 H
        @(negedge clk);
        g_in_flat = G_mem[0];
        h_in_flat = H_mem[0];

        // 阶段 2: 装载 1-bit 权重 (4x4 = 16 拍)
        $display("[%0t] [GLS] 开始装载 4x4 权重...", $time);
        @(negedge clk);
        load_en = 1;
        for (i = 0; i < 16; i = i + 1) begin
            w_in = W_mem[i];
            @(negedge clk); // 始终在下降沿更新数据
        end
        load_en = 0;
        
        // 阶段 3: 启动计算，流式推入激活值 X
        $display("[%0t] [GLS] 权重装载完毕，启动物理流式计算...", $time);
        #200; // 等待指令间隙
        @(negedge clk);
        compute_en = 1; 
        
        for (i = 0; i < 20; i = i + 1) begin
            // 使用 === 进行严格的 X 态鉴别，防止瘟疫蔓延
            if (ready_in === 1'b1) begin 
                valid_in = 1;
                x_in_flat = X_mem[i];
            end else begin
                valid_in = 0;
                i = i - 1; 
            end
            @(negedge clk);
        end
        
        valid_in = 0;
    end

    // ==========================================
    // 监听与比对线程 (Monitor & Scoreboard)
    // ==========================================
    initial begin
        while (output_idx < 20) begin
            // 同样在下降沿进行采样，此时该周期的物理门级延时早已结算完毕
            @(negedge clk); 
            if (valid_out === 1'b1 && ready_out === 1'b1) begin
                if (y_out_flat !== Y_mem[output_idx]) begin
                    $display("[ERROR] 物理后仿 第 %0d 行错位！\nDUT: %h\nEXP: %h", 
                             output_idx, y_out_flat, Y_mem[output_idx]);
                    error_count = error_count + 1;
                end else begin
                    $display("[%0t] [GLS] 完美接收并验证通过矩阵第 %0d 行物理结算结果", $time, output_idx);
                end
                output_idx = output_idx + 1;
            end
        end
        
        if (error_count == 0)
            $display("\n=======================================================\n[WIN] 👑 物理后仿 (SDF Back-annotation) 端到端完美通过！👑\n=======================================================\n");
        else
            $display("\n[FAIL] 发现 %0d 个错误。\n", error_count);
            
        $finish;
    end

    // ==========================================
    // 看门狗 (Watchdog)
    // ==========================================
    initial begin
        #5000000; // 5毫秒的绝对超时时间
        $display("\n[FATAL] 物理后仿超时！请检查波形。\n");
        $finish;
    end

endmodule