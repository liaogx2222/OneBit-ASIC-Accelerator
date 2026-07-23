// tb/tb_onebit_top_ultimate.v
`timescale 1ns / 1ps

module tb_onebit_top_ultimate;
    reg clk;
    reg rst_n;
    
    // AXI Slave (CPU -> 加速器)
    reg         s_valid;
    wire        s_ready;
    reg  [63:0] s_data;
    
    // AXI Master (加速器 -> CPU)
    wire        m_valid;
    reg         m_ready;
    wire [63:0] m_data;

    onebit_top u_top (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_valid), .s_axis_tready(s_ready), .s_axis_tdata(s_data),
        .m_axis_tvalid(m_valid), .m_axis_tready(m_ready), .m_axis_tdata(m_data)
    );

    initial begin clk = 0; forever #5 clk = ~clk; end

    // 定义数据存储器
    reg [255:0] g_force_val;
    reg [255:0] h_force_val;
    reg         W_mem [0:255];
    reg [255:0] G_mem [0:0];
    reg [255:0] H_mem [0:0];
    reg [255:0] X_mem [0:19];
    reg [255:0] Y_mem [0:19];

    // 发送 Header 任务
    task send_header(input [3:0] opcode, input [31:0] length);
        begin
            @(posedge clk); #1;
            while (!s_ready) begin @(posedge clk); #1; end
            s_valid = 1;
            s_data  = {opcode, 28'd0, length};
        end
    endtask

    // 发送 Payload 任务
    task send_payload(input [63:0] data_val);
        begin
            @(posedge clk); #1;
            while (!s_ready) begin @(posedge clk); #1; end
            s_valid = 1;
            s_data  = data_val;
        end
    endtask

    integer i, c;

    // 驱动线程 (Driver)
    initial begin
        $readmemb("W_test.txt", W_mem);
        $readmemh("g_test.txt", G_mem);
        $readmemh("h_test.txt", H_mem);
        $readmemh("X_test.txt", X_mem);
        $readmemh("Y_expected.txt", Y_mem);
        
        rst_n = 0; s_valid = 0; m_ready = 1; s_data = 0;
        #25 rst_n = 1;
        
        $display("[%0t] [主机] 发送 G 缩放因子...", $time);
        send_header(4'b0011, 4);
        send_payload(G_mem[0][63:0]);
        send_payload(G_mem[0][127:64]);
        send_payload(G_mem[0][191:128]);
        send_payload(G_mem[0][255:192]);
        @(posedge clk); #1; s_valid = 0;

        $display("[%0t] [主机] 发送 H 缩放因子...", $time);
        send_header(4'b0100, 4);
        send_payload(H_mem[0][63:0]);
        send_payload(H_mem[0][127:64]);
        send_payload(H_mem[0][191:128]);
        send_payload(H_mem[0][255:192]);
        @(posedge clk); #1; s_valid = 0;
        
        // ==========================================
        // 1. 发送 W 权重 (Opcode=1, Length=256)
        // ==========================================
        $display("[%0t] [主机] 发送 1-bit 权重加载指令...", $time);
        send_header(4'b0001, 256);
        for(i = 0; i < 256; i = i + 1) send_payload({63'd0, W_mem[i]});
        @(posedge clk); #1; s_valid = 0;

        // ==========================================
        // 2. 发送 X 激活值 (Opcode=2, Length=80 拍)
        // 20 行，每行 256-bit (需切成 4 个 64-bit 发送)
        // ==========================================
        $display("[%0t] [主机] 发送激活值 X 数据流 (经 AXI-S2P 齿轮箱)...", $time);
        send_header(4'b0010, 80);
        for(i = 0; i < 20; i = i + 1) begin
            send_payload(X_mem[i][63:0]);
            send_payload(X_mem[i][127:64]);
            send_payload(X_mem[i][191:128]);
            send_payload(X_mem[i][255:192]);
        end
        @(posedge clk); #1; s_valid = 0;

        // ==========================================
        // 3. 启动阵列计算 (Opcode=15)
        // ==========================================
        $display("[%0t] [主机] 敲击回车，点火启动 16x16 脉动阵列算力引擎！🚀", $time);
        send_header(4'b1111, 0);
        @(posedge clk); #1; s_valid = 0;

        // 等待硬件计算结束...
        #6000; 
        
        // ==========================================
        // 4. 命令芯片交出结果 (Opcode=5, Length=20 行)
        // ==========================================
        $display("[%0t] [主机] 计算完毕，请求芯片通过 AXI 总线写回结果 Y...", $time);
        send_header(4'b0101, 20); // 告诉 P2S 读取 20 块 256-bit
        @(posedge clk); #1; s_valid = 0;
    end

    // ==========================================
    // 监听与校验线程 (Monitor & Scoreboard)
    // ==========================================
    integer output_row = 0;
    integer chunk = 0;
    integer error_cnt = 0;
    reg [255:0] y_recv_buf;

    initial begin
        while (output_row < 20) begin
            @(posedge clk); #1;
            if (m_valid && m_ready) begin
                case (chunk)
                    0: y_recv_buf[ 63:  0] = m_data;
                    1: y_recv_buf[127: 64] = m_data;
                    2: y_recv_buf[191:128] = m_data;
                    3: begin
                        y_recv_buf[255:192] = m_data;
                        
                        // 256-bit 拼装完毕，进行整行比特级断言校验！
                        if (y_recv_buf !== Y_mem[output_row]) begin
                            $display("[ERROR] 矩阵第 %0d 行比对失败！", output_row);
                            error_cnt = error_cnt + 1;
                        end else begin
                            $display("[%0t] [硬件 -> 内存] 完美接收并验证通过矩阵第 %0d 行结果", $time, output_row);
                        end
                        output_row = output_row + 1;
                    end
                endcase
                chunk = (chunk == 3) ? 0 : chunk + 1;
            end
        end
        
        if (error_cnt == 0)
            $display("\n=======================================================\n[WIN] 👑 全系统 SoC 端到端验证通过！OneBit 芯片完全体诞生！👑\n=======================================================\n");
        else
            $display("\n[FAIL] 发现 %0d 个错误。\n", error_cnt);
            
        $finish;
    end
    
    initial begin
        $dumpfile("ultimate_sim.vcd");
        $dumpvars(0, tb_onebit_top_ultimate);
        #500000;
        $display("[FATAL] 仿真超时卡死！");
        $finish;
    end
endmodule