// rtl/global_controller.v
`timescale 1ns / 1ps

module global_controller (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        s_axis_tvalid,
    output reg         s_axis_tready,
    input  wire [63:0] s_axis_tdata,

    output reg         w_valid,
    output wire [63:0] w_data,
    
    output reg         x_valid,
    input  wire        x_ready, 
    output wire [63:0] x_data,
    
    // 新增：动态输出 G 和 H 缩放向量到 Compute Core
    output reg [255:0] g_flat,
    output reg [255:0] h_flat,
    
    output reg         compute_en,
    output reg         in_switch_bank,
    output reg         out_switch_bank,
    output reg         store_start,
    output reg [31:0]  store_length
);

    localparam ST_IDLE    = 3'd0;
    localparam ST_LOAD_W  = 3'd1;
    localparam ST_LOAD_X  = 3'd2;
    localparam ST_LOAD_G  = 3'd3;
    localparam ST_COMPUTE = 3'd4;
    localparam ST_STORE   = 3'd5;
    localparam ST_LOAD_H  = 3'd6;

    localparam OPC_LOAD_W = 4'b0001;
    localparam OPC_LOAD_X = 4'b0010;
    localparam OPC_LOAD_G = 4'b0011;
    localparam OPC_LOAD_H = 4'b0100;
    localparam OPC_STORE  = 4'b0101;
    localparam OPC_COMP   = 4'b1111;

    reg [2:0]  state, next_state;
    reg [31:0] payload_cnt, length_reg;

    wire handshake = s_axis_tvalid && s_axis_tready;
    assign w_data = s_axis_tdata;
    assign x_data = s_axis_tdata;

    // 状态转移与配置寄存器写入逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            payload_cnt <= 0; 
            length_reg <= 0;
            g_flat <= 256'd0;
            h_flat <= 256'd0;
        end else begin
            state <= next_state;
            
            if (state == ST_IDLE && s_axis_tvalid) begin
                length_reg  <= s_axis_tdata[31:0];
                payload_cnt <= 0;
            end else if (state == ST_LOAD_W || state == ST_LOAD_X || state == ST_LOAD_G || state == ST_LOAD_H) begin
                if (handshake) begin
                    payload_cnt <= payload_cnt + 1;
                    
                    // 动态移位装载 256-bit 配置向量
                    if (state == ST_LOAD_G) begin
                        g_flat <= {s_axis_tdata, g_flat[255:64]};
                    end else if (state == ST_LOAD_H) begin
                        h_flat <= {s_axis_tdata, h_flat[255:64]};
                    end
                end
            end else if (state == ST_COMPUTE) begin
                payload_cnt <= payload_cnt + 1;
            end
        end
    end

    // 次态推导逻辑
    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (s_axis_tvalid) begin
                    case (s_axis_tdata[63:60])
                        OPC_LOAD_W: next_state = ST_LOAD_W;
                        OPC_LOAD_X: next_state = ST_LOAD_X;
                        OPC_LOAD_G: next_state = ST_LOAD_G;
                        OPC_LOAD_H: next_state = ST_LOAD_H;
                        OPC_COMP:   next_state = ST_COMPUTE;
                        OPC_STORE:  next_state = ST_STORE;
                        default:    next_state = ST_IDLE;
                    endcase
                end
            end
            ST_LOAD_W, ST_LOAD_X, ST_LOAD_G, ST_LOAD_H: begin
                if (handshake && (payload_cnt == length_reg - 1)) next_state = ST_IDLE;
            end
            ST_COMPUTE: begin
                // 维持足够周期确保流水线排空
                if (payload_cnt == 300) next_state = ST_IDLE;
            end
            ST_STORE: begin
                next_state = ST_IDLE; 
            end
        endcase
    end

    // 输出控制逻辑
    always @(*) begin
        s_axis_tready = 1'b0; w_valid = 1'b0; x_valid = 1'b0;
        compute_en = 1'b0; in_switch_bank = 1'b0; 
        out_switch_bank = 1'b0; store_start = 1'b0; store_length = 0;

        case (state)
            ST_IDLE: begin 
                s_axis_tready = 1'b1;
                if (s_axis_tvalid && (s_axis_tdata[63:60] == OPC_COMP)) begin
                    in_switch_bank = 1'b1; 
                end
            end
            ST_LOAD_W: begin s_axis_tready = 1'b1; w_valid = s_axis_tvalid; end
            ST_LOAD_X: begin s_axis_tready = x_ready; x_valid = s_axis_tvalid; end
            ST_LOAD_G, ST_LOAD_H: begin 
                s_axis_tready = 1'b1; // 配置数据无内部反压
            end
            ST_COMPUTE: begin
                compute_en = 1'b1;
            end
            ST_STORE: begin
                out_switch_bank = 1'b1; 
                store_start     = 1'b1; 
                store_length    = length_reg; 
            end
        endcase
    end
endmodule