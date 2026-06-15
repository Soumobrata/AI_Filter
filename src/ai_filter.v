`timescale 1ns/1ps 

// ---------- ReLU ----------
module relu_q15(input signed [15:0] din, output signed [15:0] dout);
  assign dout = din[15] ? 16'sd0 : din;
endmodule

// ---------- Argmax(3) ----------
module argmax3(
  input  signed [15:0] a0, a1, a2,
  output [1:0]         idx
);
  reg [1:0] r;
  always @* begin
    if (a0 >= a1 && a0 >= a2) r = 2'd0;
    else if (a1 >= a2)        r = 2'd1;
    else                      r = 2'd2;
  end
  assign idx = r;
endmodule

// ---------- Top (COMBINATIONAL) ----------
module ai_filter
#(
  parameter N_IN  = 100,
  parameter N_HID = 32,
  parameter N_OUT = 3,

  parameter W1_FILE = "w1.memh",
  parameter B1_FILE = "b1.memh",
  parameter W2_FILE = "w2.memh",
  parameter B2_FILE = "b2.memh"
)(
  // One UI window flattened: {x[N_IN-1], ..., x[0]} (each Q1.15)
  input  [N_IN*16-1:0]         in_bus,

  // Clean outputs
  output signed [15:0]         clean_q15,
  output                       clean_bit,

  // Classification
  output        [1:0]          class_idx,

  // Flowchart taps (scalars)
  output signed [15:0]         waveform_Data_Generation_q15,
  output signed [15:0]         rtl_EMA_clean_q15,
  output signed [15:0]         rtl_FC1_neuron_q15,
  output signed [15:0]         rtl_ReLU_neuron_q15,
  output signed [15:0]         rtl_FC2_logit_q15,
  output        [1:0]          rtl_Argmax_idx
);

  // -------- Unpack input window --------
  wire signed [15:0] x [0:N_IN-1];
  genvar gi;
  generate
    for (gi=0; gi<N_IN; gi=gi+1) begin: UNPK
      assign x[gi] = in_bus[(gi*16)+:16];
    end
  endgenerate
  assign waveform_Data_Generation_q15 = x[0];

  // -------- Moving-average \u201cWiener-ish\u201d clean (FIR) --------
  integer i;
  reg signed [47:0] sum_x;
  reg signed [31:0] avg_q15;

  always @* begin
    sum_x = 48'sd0;
    for (i=0; i<N_IN; i=i+1)
      sum_x = sum_x + {{32{x[i][15]}}, x[i]};
    avg_q15 = (sum_x + (N_IN/2)) / N_IN;  // rounded divide
  end

  function signed [15:0] sat16; input signed [31:0] v;
    begin
      if      (v >  32'sh00007FFF) sat16 = 16'sh7FFF;
      else if (v < -32'sh00008000) sat16 = 16'sh8000;
      else                          sat16 = v[15:0];
    end
  endfunction

  assign rtl_EMA_clean_q15 = sat16(avg_q15);
  assign clean_q15         = rtl_EMA_clean_q15;
  assign clean_bit         = (clean_q15 >= 16'sd16384);

  // -------- Weights/Biases (loaded at time 0) --------
  localparam W1_DEPTH = N_HID * N_IN;
  localparam B1_DEPTH = N_HID;
  localparam W2_DEPTH = N_OUT * N_HID;
  localparam B2_DEPTH = N_OUT;

  reg signed [15:0] W1 [0:W1_DEPTH-1];
  reg signed [15:0] B1 [0:B1_DEPTH-1];
  reg signed [15:0] W2 [0:W2_DEPTH-1];
  reg signed [15:0] B2 [0:B2_DEPTH-1];

  initial begin
    $readmemh(W1_FILE, W1);
    $readmemh(B1_FILE, B1);
    $readmemh(W2_FILE, W2);
    $readmemh(B2_FILE, B2);
  end

  // q2.30 -> q1.15 (round & saturate)
  function signed [15:0] q230_to_q15_sat; input signed [47:0] a; reg signed [47:0] ar; reg signed [31:0] shr;
    begin
      ar  = a + 48'sd16384;  // +0.5 LSB before >>15
      shr = ar[46:15];
      if      (shr >  32'sh00007FFF) q230_to_q15_sat = 16'sh7FFF;
      else if (shr < -32'sh00008000) q230_to_q15_sat = 16'sh8000;
      else                            q230_to_q15_sat = shr[15:0];
    end
  endfunction

  // -------- FC1 TAP (neuron 0) --------
  integer k;
  reg signed [47:0] acc1;
  reg signed [15:0] fc1_y0;
  reg signed [31:0] prod1;

  always @* begin
    acc1 = {{32{B1[0][15]}}, B1[0], 15'd0};
    for (k=0; k<N_IN; k=k+1) begin
      prod1 = x[k] * W1[0*N_IN + k];            // 16x16 -> 32 (q2.30)
      acc1  = acc1 + {{16{prod1[31]}}, prod1};  // widen & accumulate
    end
    fc1_y0 = q230_to_q15_sat(acc1);
  end
  assign rtl_FC1_neuron_q15 = fc1_y0;

  // -------- Build Hidden (ReLU on all) --------
  integer jj, kk;
  reg signed [47:0] acc1_all;
  reg signed [15:0] hid [0:N_HID-1];
  reg signed [31:0] p1;

  always @* begin
    for (jj=0; jj<N_HID; jj=jj+1) begin
      acc1_all = {{32{B1[jj][15]}}, B1[jj], 15'd0};
      for (kk=0; kk<N_IN; kk=kk+1) begin
        p1       = x[kk] * W1[jj*N_IN + kk];
        acc1_all = acc1_all + {{16{p1[31]}}, p1};
      end
      hid[jj] = q230_to_q15_sat(acc1_all);
      if (hid[jj][15]) hid[jj] = 16'sd0; // ReLU
    end
  end

  assign rtl_ReLU_neuron_q15 = (fc1_y0[15] ? 16'sd0 : fc1_y0);

  // -------- FC2 (3 logits) --------
  integer t;
  reg signed [47:0] acc2;
  reg signed [15:0] log0, log1, log2;
  reg signed [31:0] p2;

  always @* begin
    // log0
    acc2 = {{32{B2[0][15]}}, B2[0], 15'd0};
    for (t=0; t<N_HID; t=t+1) begin
      p2   = hid[t] * W2[0*N_HID + t];
      acc2 = acc2 + {{16{p2[31]}}, p2};
    end
    log0 = q230_to_q15_sat(acc2);

    // log1
    acc2 = {{32{B2[1][15]}}, B2[1], 15'd0};
    for (t=0; t<N_HID; t=t+1) begin
      p2   = hid[t] * W2[1*N_HID + t];
      acc2 = acc2 + {{16{p2[31]}}, p2};
    end
    log1 = q230_to_q15_sat(acc2);

    // log2
    acc2 = {{32{B2[2][15]}}, B2[2], 15'd0};
    for (t=0; t<N_HID; t=t+1) begin
      p2   = hid[t] * W2[2*N_HID + t];
      acc2 = acc2 + {{16{p2[31]}}, p2};
    end
    log2 = q230_to_q15_sat(acc2);
  end

  assign rtl_FC2_logit_q15 = log0;

  // -------- Argmax --------
  argmax3 U_AM (.a0(log0), .a1(log1), .a2(log2), .idx(class_idx));
  assign rtl_Argmax_idx = class_idx;

endmodule     
