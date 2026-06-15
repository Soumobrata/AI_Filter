// ============================================================================
// ai_filter.v  (Verilog-2001; synthesizable)
// Sequential AI filter with EMA + time-mux FC1/ReLU/FC2/Argmax
// ============================================================================

`timescale 1ns/1ps

// ---------- ROM ----------
module rom_hex #(parameter integer WIDTH=16, DEPTH=1, parameter FNAME="mem.memh")
(
  input  [31:0] addr,
  output reg signed [WIDTH-1:0] dout
);
  reg signed [WIDTH-1:0] mem [0:DEPTH-1];

  initial begin
    $readmemh(FNAME, mem);
  end

  always @* begin
    dout = mem[addr];
  end
endmodule

// ---------- ReLU ----------
module relu_q15(
  input  signed [15:0] din,
  output signed [15:0] dout
);
  assign dout = din[15] ? 16'sd0 : din;
endmodule

// ---------- Argmax(3) ----------
module argmax3(
  input  signed [15:0] a0,
  input  signed [15:0] a1,
  input  signed [15:0] a2,
  output       [1:0]   idx
);
  reg [1:0] r;

  always @* begin
    if (a0 >= a1 && a0 >= a2) r = 2'd0;
    else if (a1 >= a2)        r = 2'd1;
    else                      r = 2'd2;
  end

  assign idx = r;
endmodule

// ---------- Centered EMA ----------
module ema_q15_centered #(parameter integer GAIN_SHIFT=4)(
  input                     clk,
  input                     rst_n,
  input                     in_valid,
  input      signed [15:0]  in_q15,
  output reg                out_valid,
  output reg signed [15:0]  out_q15
);
  reg signed [31:0] y_c_acc;
  reg               primed;
  reg signed [31:0] x_c;
  reg signed [31:0] y_next;

  localparam signed [15:0] HALF = 16'sd16384;

  function signed [31:0] sx_q15;
    input signed [15:0] q;
    begin
      sx_q15 = {{16{q[15]}}, q};
    end
  endfunction

  function signed [15:0] sat16;
    input signed [31:0] x;
    begin
      if      (x >  32'sh00007FFF) sat16 = 16'sh7FFF;
      else if (x < -32'sh00008000) sat16 = 16'sh8000;
      else                         sat16 = x[15:0];
    end
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      y_c_acc   <= 32'sd0;
      primed    <= 1'b0;
      out_valid <= 1'b0;
      out_q15   <= 16'sd0;
    end else begin
      out_valid <= 1'b0;

      if (in_valid) begin
        x_c = sx_q15(in_q15 - HALF);

        if (!primed) begin
          y_c_acc <= x_c;
          out_q15 <= sat16(x_c + sx_q15(HALF));
          primed  <= 1'b1;
        end else begin
          y_next  = y_c_acc + ((x_c - y_c_acc) >>> GAIN_SHIFT);
          y_c_acc <= y_next;
          out_q15 <= sat16(y_next + sx_q15(HALF));
        end

        out_valid <= 1'b1;
      end
    end
  end
endmodule

// ---------- FC Layer, Time-Multiplexed MAC ----------
module fc_tmux
#(
  parameter integer N_IN  = 100,
  parameter integer N_OUT = 32,
  parameter        W_FILE = "w1.memh",
  parameter        B_FILE = "b1.memh"
)(
  input                      clk,
  input                      rst_n,
  input                      x_valid,
  input       signed [15:0]  x_sample,
  input                      x_last,
  input                      start,
  output reg                 y_valid,
  output reg  signed [15:0]  y_data,
  output reg                 y_last
);

  reg signed [15:0] xbuf [0:N_IN-1];
  integer xwr_ptr;

  reg window_ready;
  reg go;

  localparam integer W_DEPTH = N_OUT * N_IN;
  localparam integer B_DEPTH = N_OUT;

  reg  [31:0] waddr;
  wire signed [15:0] wdata;

  reg  [31:0] baddr;
  wire signed [15:0] bdata;

  rom_hex #(
    .WIDTH(16),
    .DEPTH(W_DEPTH),
    .FNAME(W_FILE)
  ) U_W (
    .addr(waddr),
    .dout(wdata)
  );

  rom_hex #(
    .WIDTH(16),
    .DEPTH(B_DEPTH),
    .FNAME(B_FILE)
  ) U_B (
    .addr(baddr),
    .dout(bdata)
  );

  localparam [1:0] S_IDLE  = 2'd0;
  localparam [1:0] S_LOADB = 2'd1;
  localparam [1:0] S_ACCUM = 2'd2;
  localparam [1:0] S_OUT   = 2'd3;

  reg [1:0] st;
  integer neuron_idx;
  integer in_idx;

  reg signed [47:0] acc;

  wire signed [15:0] x_cur;
  wire signed [31:0] prod_q230;

  assign x_cur     = xbuf[in_idx];
  assign prod_q230 = x_cur * wdata;

  always @* begin
    waddr = neuron_idx * N_IN + in_idx;
  end

  always @* begin
    baddr = neuron_idx;
  end

  function signed [15:0] q230_to_q15_sat;
    input signed [47:0] a;
    reg signed [47:0] ar;
    reg signed [31:0] shr;
    begin
      ar  = a + 48'sd16384;
      shr = ar[46:15];

      if      (shr >  32'sh00007FFF) q230_to_q15_sat = 16'sh7FFF;
      else if (shr < -32'sh00008000) q230_to_q15_sat = 16'sh8000;
      else                           q230_to_q15_sat = shr[15:0];
    end
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      xwr_ptr      <= 0;
      window_ready <= 1'b0;
      go           <= 1'b0;

      st           <= S_IDLE;
      neuron_idx   <= 0;
      in_idx       <= 0;
      acc          <= 48'sd0;

      y_valid      <= 1'b0;
      y_last       <= 1'b0;
      y_data       <= 16'sd0;
    end else begin
      y_valid <= 1'b0;
      y_last  <= 1'b0;

      // Load input window
      if (x_valid) begin
        xbuf[xwr_ptr] <= x_sample;

        if (x_last) begin
          xwr_ptr      <= 0;
          window_ready <= 1'b1;
        end else begin
          xwr_ptr <= xwr_ptr + 1;
        end
      end

      // Latch start if window is ready
      if (window_ready && start)
        go <= 1'b1;

      if (st == S_LOADB)
        go <= 1'b0;

      case (st)
        S_IDLE: begin
          if (window_ready && (start || go)) begin
            neuron_idx   <= 0;
            in_idx       <= 0;
            st           <= S_LOADB;
            window_ready <= 1'b0;
          end
        end

        S_LOADB: begin
          acc    <= {{32{bdata[15]}}, bdata, 15'd0};
          in_idx <= 0;
          st     <= S_ACCUM;
        end

        S_ACCUM: begin
          acc <= acc + {{16{prod_q230[31]}}, prod_q230};

          if (in_idx == (N_IN-1))
            st <= S_OUT;
          else
            in_idx <= in_idx + 1;
        end

        S_OUT: begin
          y_data  <= q230_to_q15_sat(acc);
          y_valid <= 1'b1;

          if (neuron_idx == (N_OUT-1)) begin
            y_last <= 1'b1;
            st     <= S_IDLE;
          end else begin
            neuron_idx <= neuron_idx + 1;
            in_idx     <= 0;
            st         <= S_LOADB;
          end
        end

        default: begin
          st <= S_IDLE;
        end
      endcase
    end
  end

endmodule

// ---------- TOP AI FILTER ----------
module ai_filter
#(
  parameter integer N_IN       = 100,
  parameter integer N_HID      = 32,
  parameter integer N_OUT      = 3,
  parameter integer GAIN_SHIFT = 4,
  parameter integer USE_EMA    = 1
)(
  input                      clk,
  input                      rst_n,
  input                      in_valid,
  input       signed [15:0]  in_q15,
  input                      in_last,

  output                     clean_valid,
  output signed [15:0]       clean_q15,
  output                     clean_bit,

  output reg                 class_valid,
  output       [1:0]         class_idx,

  output                     rtl_EMA_valid,
  output signed [15:0]       rtl_EMA_clean_q15,

  output                     rtl_FC1_valid,
  output                     rtl_FC1_last,
  output signed [15:0]       rtl_FC1_neuron_q15,

  output                     rtl_ReLU_valid,
  output signed [15:0]       rtl_ReLU_neuron_q15,

  output                     rtl_FC2_valid,
  output                     rtl_FC2_last,
  output signed [15:0]       rtl_FC2_logit_q15,

  output                     rtl_Argmax_valid,
  output       [1:0]         rtl_Argmax_idx
);

  wire s_valid;
  wire signed [15:0] s_q15;

  generate
    if (USE_EMA) begin : G_EMA
      ema_q15_centered #(
        .GAIN_SHIFT(GAIN_SHIFT)
      ) U_EMA (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_q15(in_q15),
        .out_valid(s_valid),
        .out_q15(s_q15)
      );
    end else begin : G_BYP
      assign s_valid = in_valid;
      assign s_q15   = in_q15;
    end
  endgenerate

  assign clean_valid       = s_valid;
  assign clean_q15         = s_q15;
  assign clean_bit         = (s_q15 >= 16'sd16384);

  assign rtl_EMA_valid     = s_valid;
  assign rtl_EMA_clean_q15 = s_q15;

  // UI framing
  integer sample_cnt;
  reg ui_end;
  reg ui_end_d1;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sample_cnt <= 0;
      ui_end     <= 1'b0;
      ui_end_d1  <= 1'b0;
    end else begin
      ui_end <= 1'b0;

      if (s_valid) begin
        if (sample_cnt == (N_IN-1)) begin
          sample_cnt <= 0;
          ui_end     <= 1'b1;
        end else begin
          sample_cnt <= sample_cnt + 1;
        end
      end

      ui_end_d1 <= ui_end;
    end
  end

  // FC1
  wire fc1_v;
  wire fc1_l;
  wire signed [15:0] fc1_y;

  fc_tmux #(
    .N_IN(N_IN),
    .N_OUT(N_HID),
    .W_FILE("w1.memh"),
    .B_FILE("b1.memh")
  ) U_FC1 (
    .clk(clk),
    .rst_n(rst_n),
    .x_valid(s_valid),
    .x_sample(s_q15),
    .x_last(ui_end),
    .start(ui_end_d1),
    .y_valid(fc1_v),
    .y_data(fc1_y),
    .y_last(fc1_l)
  );

  assign rtl_FC1_valid      = fc1_v;
  assign rtl_FC1_last       = fc1_l;
  assign rtl_FC1_neuron_q15 = fc1_y;

  // ReLU + hidden buffer
  wire signed [15:0] relu_y;

  relu_q15 U_RELU (
    .din(fc1_y),
    .dout(relu_y)
  );

  reg signed [15:0] hid [0:N_HID-1];
  integer hwptr;
  reg hid_ready;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hwptr     <= 0;
      hid_ready <= 1'b0;
    end else begin
      if (fc1_v) begin
        hid[hwptr] <= relu_y;

        if (fc1_l) begin
          hwptr     <= 0;
          hid_ready <= 1'b1;
        end else begin
          hwptr <= hwptr + 1;
        end
      end

      if (class_valid)
        hid_ready <= 1'b0;
    end
  end

  assign rtl_ReLU_valid      = fc1_v;
  assign rtl_ReLU_neuron_q15 = relu_y;

  // Stream hidden buffer into FC2
  integer hrptr;
  reg h_v;
  reg h_l;
  reg signed [15:0] h_samp;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hrptr  <= 0;
      h_v    <= 1'b0;
      h_l    <= 1'b0;
      h_samp <= 16'sd0;
    end else begin
      h_v <= 1'b0;
      h_l <= 1'b0;

      if (hid_ready) begin
        h_v    <= 1'b1;
        h_samp <= hid[hrptr];

        if (hrptr == (N_HID-1)) begin
          h_l   <= 1'b1;
          hrptr <= 0;
        end else begin
          hrptr <= hrptr + 1;
        end
      end
    end
  end

  // FC2
  wire fc2_v;
  wire fc2_l;
  wire signed [15:0] fc2_y;

  fc_tmux #(
    .N_IN(N_HID),
    .N_OUT(N_OUT),
    .W_FILE("w2.memh"),
    .B_FILE("b2.memh")
  ) U_FC2 (
    .clk(clk),
    .rst_n(rst_n),
    .x_valid(h_v),
    .x_sample(h_samp),
    .x_last(h_l),
    .start(h_l),
    .y_valid(fc2_v),
    .y_data(fc2_y),
    .y_last(fc2_l)
  );

  assign rtl_FC2_valid     = fc2_v;
  assign rtl_FC2_last      = fc2_l;
  assign rtl_FC2_logit_q15 = fc2_y;

  // Collect FC2 logits
  reg [1:0] oc;
  reg signed [15:0] log0;
  reg signed [15:0] log1;
  reg signed [15:0] log2;

  wire [1:0] idx_w;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      oc          <= 2'd0;
      class_valid <= 1'b0;
      log0        <= 16'sd0;
      log1        <= 16'sd0;
      log2        <= 16'sd0;
    end else begin
      class_valid <= 1'b0;

      if (fc2_v) begin
        case (oc)
          2'd0: begin
            log0 <= fc2_y;
            oc   <= 2'd1;
          end

          2'd1: begin
            log1 <= fc2_y;
            oc   <= 2'd2;
          end

          2'd2: begin
            log2 <= fc2_y;
            oc   <= 2'd0;
          end

          default: begin
            oc <= 2'd0;
          end
        endcase

        if (fc2_l)
          class_valid <= 1'b1;
      end
    end
  end

  argmax3 U_AM (
    .a0(log0),
    .a1(log1),
    .a2(log2),
    .idx(idx_w)
  );

  assign class_idx        = idx_w;
  assign rtl_Argmax_idx   = idx_w;
  assign rtl_Argmax_valid = class_valid;

  wire _unused = &{in_last, 1'b0};

endmodule
