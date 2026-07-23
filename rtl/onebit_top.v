// rtl/onebit_top.v
`timescale 1ns / 1ps

module onebit_top #(
    parameter ROWS = 16,
    parameter COLS = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    // ==========================================
    // 芯片对外统一输入接口 (AXI-Stream Slave)
    // ==========================================
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire [63:0] s_axis_tdata,

    // ==========================================
    // 芯片对外统一输出接口 (AXI-Stream Master)
    // ==========================================
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire [63:0] m_axis_tdata
);

    // ==========================================
    // 1. 全局控制器 (The Brain)
    // ==========================================
    wire        w_valid;
    wire [63:0] w_data;
    wire        x_valid;
    wire        x_ready;
    wire [63:0] x_data;
    
    wire        compute_en;
    wire        in_switch_bank;
    wire        out_switch_bank;
    wire        store_start;
    wire [31:0] store_length;

    wire [255:0] g_flat;
    wire [255:0] h_flat;

    global_controller u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready), .s_axis_tdata(s_axis_tdata),
        .w_valid(w_valid), .w_data(w_data),
        .x_valid(x_valid), .x_ready(x_ready), .x_data(x_data),
        .g_flat(g_flat), .h_flat(h_flat), // <- 新增接入点
        .compute_en(compute_en), .in_switch_bank(in_switch_bank),
        .out_switch_bank(out_switch_bank), .store_start(store_start), .store_length(store_length)
    );

    // ==========================================
    // 2. 输入域：S2P 齿轮箱 -> PingPong SRAM
    // ==========================================
    wire         s2p_valid;
    wire         s2p_ready;
    wire [255:0] s2p_data;
    
    axis_gearbox_s2p u_s2p (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(x_valid), .s_axis_tready(x_ready), .s_axis_tdata(x_data),
        .m_axis_tvalid(s2p_valid), .m_axis_tready(s2p_ready), .m_axis_tdata(s2p_data)
    );

    // 这里使用一个极简写地址发生器 (写入 PingPong)
    reg [8:0] s2p_w_addr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) s2p_w_addr <= 0;
        else if (in_switch_bank) s2p_w_addr <= 0;
        else if (s2p_valid && s2p_ready) s2p_w_addr <= s2p_w_addr + 1;
    end
    assign s2p_ready = 1'b1; // SRAM永远可以写

    wire [255:0] core_in_data;

    pingpong_buffer #( .DATA_WIDTH(256), .DEPTH(512), .ADDR_WIDTH(9) ) u_pp_in (
        .clk(clk), .rst_n(rst_n), .switch_bank(in_switch_bank),
        .ext_we(s2p_valid), .ext_w_addr(s2p_w_addr), .ext_w_data(s2p_data),
        .arr_re(compute_en), .arr_r_addr(core_r_addr), .arr_r_data(core_in_data)
    );

    // ==========================================
    // 3. 计算域：Compute Core
    // ==========================================
    wire         core_valid_out;
    wire [255:0] core_y_out;
    
    // 【优化1】保证每次计算前，读指针归零
    reg [8:0] core_r_addr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) core_r_addr <= 0;
        else if (!compute_en) core_r_addr <= 0; 
        else core_r_addr <= core_r_addr + 1;
    end
    
    // 【终极修复2】SRAM 读数据有 1 拍物理延迟，我们将 valid 信号也精确延迟 1 拍！
    reg core_valid_in;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) core_valid_in <= 1'b0;
        else core_valid_in <= compute_en;
    end
    
    compute_core #( .ROWS(ROWS), .COLS(COLS) ) u_core (
        .clk(clk), .rst_n(rst_n),
        .load_en(w_valid), .compute_en(compute_en), .w_in(w_data[0]),
        .valid_in(core_valid_in), 
        .ready_in(), 
        .x_in_flat(core_in_data), 
        .g_in_flat(g_flat),       
        .h_in_flat(h_flat),       
        .valid_out(core_valid_out), .ready_out(1'b1), .y_out_flat(core_y_out)
    );
    // ==========================================
    // 4. 输出域：PingPong SRAM -> P2S 齿轮箱
    // ==========================================
    reg [8:0] core_w_addr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) core_w_addr <= 0;
        else if (out_switch_bank) core_w_addr <= 0;
        else if (core_valid_out) core_w_addr <= core_w_addr + 1;
    end

    wire         p2s_re;
    wire [8:0]   p2s_r_addr;
    wire [255:0] p2s_r_data;

    pingpong_buffer #( .DATA_WIDTH(256), .DEPTH(512), .ADDR_WIDTH(9) ) u_pp_out (
        .clk(clk), .rst_n(rst_n), .switch_bank(out_switch_bank),
        .ext_we(core_valid_out), .ext_w_addr(core_w_addr), .ext_w_data(core_y_out),
        .arr_re(p2s_re), .arr_r_addr(p2s_r_addr), .arr_r_data(p2s_r_data)
    );

    sram_read_p2s #( .ADDR_WIDTH(9) ) u_p2s (
        .clk(clk), .rst_n(rst_n),
        .start(store_start), .length(store_length),
        .sram_re(p2s_re), .sram_r_addr(p2s_r_addr), .sram_r_data(p2s_r_data),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready), .m_axis_tdata(m_axis_tdata)
    );

endmodule