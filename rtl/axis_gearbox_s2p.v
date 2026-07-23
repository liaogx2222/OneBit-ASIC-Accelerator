// rtl/axis_gearbox_s2p.v
`timescale 1ns / 1ps

// 64-bit to 256-bit AXI-Stream Serial-to-Parallel Converter
module axis_gearbox_s2p (
    input  wire         clk,
    input  wire         rst_n,

    // ==========================================
    // Slave Interface (外部 64-bit 输入)
    // ==========================================
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire [63:0]  s_axis_tdata,

    // ==========================================
    // Master Interface (内部 256-bit 输出)
    // ==========================================
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire [255:0] m_axis_tdata
);

    // 拼装寄存器与计数器
    reg [255:0] buffer;
    reg [1:0]   cnt;
    reg         m_valid_reg;

    // Slave 端准备好接收的条件：
    // 1. 下游(Master)没数据待发 (m_valid_reg == 0)
    // 2. 或者下游正在取走数据 (m_axis_tvalid && m_axis_tready)
    // 3. 当前还不满 256-bit (缓冲过程)
    wire s_ready_comb = (!m_valid_reg || m_axis_tready);
    assign s_axis_tready = s_ready_comb;

    // Master 端有效信号
    assign m_axis_tvalid = m_valid_reg;
    assign m_axis_tdata  = buffer;

    // 握手成功标志
    wire s_fire = s_axis_tvalid && s_axis_tready;
    wire m_fire = m_axis_tvalid && m_axis_tready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt         <= 2'd0;
            m_valid_reg <= 1'b0;
            buffer      <= 256'd0;
        end else begin
            // 1. 处理 Master 端的握手（下游取走数据后释放 valid）
            if (m_fire) begin
                m_valid_reg <= 1'b0;
            end

            // 2. 处理 Slave 端的握手（接收新数据并拼接）
            if (s_fire) begin
                // 使用索引拼接，避免繁琐的位选择逻辑
                case (cnt)
                    2'd0: buffer[ 63:  0] <= s_axis_tdata;
                    2'd1: buffer[127: 64] <= s_axis_tdata;
                    2'd2: buffer[191:128] <= s_axis_tdata;
                    2'd3: buffer[255:192] <= s_axis_tdata;
                endcase
                
                if (cnt == 2'd3) begin
                    cnt <= 2'd0;
                    // 凑满 4 个 64-bit，向 Master 发出 Valid
                    m_valid_reg <= 1'b1; 
                end else begin
                    cnt <= cnt + 2'd1;
                end
            end
        end
    end

endmodule