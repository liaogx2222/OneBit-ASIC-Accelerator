// tb/tb_fp16_adder.v
`timescale 1ns / 1ps

module tb_fp16_adder;

    reg clk;
    reg rst_n;
    
    // 接口信号
    reg         valid_in;
    wire        ready_in;
    reg  [15:0] a_in;
    reg  [15:0] b_in;
    
    wire        valid_out;
    reg         ready_out;
    wire [15:0] sum_out;

    // 实例化我们要测试的模块 (DUT)
    fp16_adder dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .ready_in(ready_in),
        .a_in(a_in),
        .b_in(b_in),
        .valid_out(valid_out),
        .ready_out(ready_out),
        .sum_out(sum_out)
    );

    // 时钟生成 (100MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // 测试数据存储器
    reg [47:0] test_data [0:9999]; // 每行 48-bit (16-bit a, 16-bit b, 16-bit c)
    reg [15:0] expected_queue [0:9999]; // 预期结果的 FIFO
    
    integer input_idx = 0;
    integer output_idx = 0;
    integer error_count = 0;

    // Driver: 从 txt 读取数据并推入流水线
    initial begin
        // 读取 Python 生成的数据
        $readmemh("test_data.txt", test_data);
        
        $dumpfile("fp16_adder_wave.vcd"); // 生成波形文件用于 GTKWave
        $dumpvars(0, tb_fp16_adder);

        // 初始化
        rst_n = 0;
        valid_in = 0;
        ready_out = 1; // 始终准备好接收，测试最高吞吐率
        a_in = 0; b_in = 0;
        
        #20 rst_n = 1; // 释放复位
        
        // 持续注入数据
        while (input_idx < 10000) begin
            @(posedge clk);
            #1; 
            if (ready_in) begin
                valid_in = 1;
                a_in = test_data[input_idx][47:32];
                b_in = test_data[input_idx][31:16];
                expected_queue[input_idx] = test_data[input_idx][15:0];
                input_idx = input_idx + 1;
            end
        end
        
        // 注入完成后，拉低 valid_in，等待流水线排空
        @(posedge clk);
        #1; 
        valid_in = 0;
    end

    // Monitor: 抓取输出并比对
    initial begin
        while (output_idx < 10000) begin
            @(posedge clk);
            #1; 
            if (valid_out && ready_out) begin
                if (sum_out !== expected_queue[output_idx]) begin
                    $display("[ERROR] Index %0d | A: %h, B: %h | DUT Out: %h | Expected: %h", 
                              output_idx, test_data[output_idx][47:32], test_data[output_idx][31:16], sum_out, expected_queue[output_idx]);
                    error_count = error_count + 1;
                end
                output_idx = output_idx + 1;
            end
        end
        
        if (error_count == 0)
            $display("\n=======================================\n[PASS] 所有 10000 组 FP16 测试完美通过！\n=======================================\n");
        else
            $display("\n=======================================\n[FAIL] 发现 %0d 个错误！请检查波形。\n=======================================\n", error_count);
            
        $finish;
    end

    initial begin
        #500000; // 设定一个绝对超时时间 (500us)
        $display("\n=======================================");
        $display("[FATAL] 仿真超时卡死！强制退出！");
        $display("当前已接收数据量: %0d", output_idx);
        $display("=======================================\n");
        $finish;
    end
endmodule