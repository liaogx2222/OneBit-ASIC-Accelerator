// rtl/sram_read_p2s.v
`timescale 1ns / 1ps

module sram_read_p2s #(
    parameter ADDR_WIDTH = 9
)(
    input  wire         clk,
    input  wire         rst_n,

    input  wire         start,
    input  wire [31:0]  length,     

    output reg                  sram_re,
    output reg [ADDR_WIDTH-1:0] sram_r_addr,
    input  wire [255:0]         sram_r_data,

    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire [63:0]  m_axis_tdata
);

    // 重新定义状态机，引入严格的 SRAM 读延迟等待状态
    localparam ST_IDLE  = 2'd0;
    localparam ST_READ  = 2'd1; 
    localparam ST_WAIT  = 2'd2; // [新增] 等待 SRAM 数据稳定
    localparam ST_SEND  = 2'd3; 

    reg [1:0]  state;
    reg [31:0] block_cnt; 
    reg [1:0]  beat_cnt;  
    
    reg [255:0] data_buffer;

    assign m_axis_tvalid = (state == ST_SEND);
    
    assign m_axis_tdata = (beat_cnt == 2'd0) ? data_buffer[ 63:  0] :
                          (beat_cnt == 2'd1) ? data_buffer[127: 64] :
                          (beat_cnt == 2'd2) ? data_buffer[191:128] :
                                               data_buffer[255:192] ;

    wire m_fire = m_axis_tvalid && m_axis_tready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            block_cnt   <= 0;
            beat_cnt    <= 0;
            sram_re     <= 0;
            sram_r_addr <= 0;
            data_buffer <= 0;
        end else begin
            case (state)
                ST_IDLE: begin
                    block_cnt <= 0;
                    beat_cnt  <= 0;
                    if (start) begin
                        state       <= ST_READ;
                        sram_re     <= 1'b1;
                        sram_r_addr <= 0;
                    end
                end
                
                ST_READ: begin
                    // 撤销读请求，进入等待周期
                    sram_re <= 1'b0; 
                    state   <= ST_WAIT;
                end

                ST_WAIT: begin
                    // SRAM 数据此时已建立并稳定，安全锁存入内部 Buffer
                    data_buffer <= sram_r_data;
                    state       <= ST_SEND;
                end
                
                ST_SEND: begin
                    if (m_fire) begin
                        if (beat_cnt == 2'd3) begin
                            beat_cnt <= 0;
                            if (block_cnt == length - 1) begin
                                state <= ST_IDLE; 
                            end else begin
                                block_cnt   <= block_cnt + 1;
                                sram_r_addr <= sram_r_addr + 1;
                                sram_re     <= 1'b1; // 发起下一块的读请求
                                state       <= ST_READ; // 回到 READ 状态走完整时序
                            end
                        end else begin
                            beat_cnt <= beat_cnt + 1;
                        end
                    end
                end
            endcase
        end
    end
endmodule