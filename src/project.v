/*
 * Copyright (c) 2024 Soumobrata Ghosh
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none
`timescale 1ns / 1ps

module tt_um_sfg_ai_filter (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  wire in_valid = ui_in[0];
  wire in_last  = ui_in[1];

  wire signed [15:0] in_q15;
  assign in_q15 = {ui_in[7:2], uio_in[7:0], 2'b00};

  wire clean_valid;
  wire signed [15:0] clean_q15;
  wire clean_bit;

  wire class_valid;
  wire [1:0] class_idx;

  wire rtl_EMA_valid;
  wire signed [15:0] rtl_EMA_clean_q15;

  wire rtl_FC1_valid;
  wire rtl_FC1_last;
  wire signed [15:0] rtl_FC1_neuron_q15;

  wire rtl_ReLU_valid;
  wire signed [15:0] rtl_ReLU_neuron_q15;

  wire rtl_FC2_valid;
  wire rtl_FC2_last;
  wire signed [15:0] rtl_FC2_logit_q15;

  wire rtl_Argmax_valid;
  wire [1:0] rtl_Argmax_idx;

  ai_filter #(
    .N_IN(100),
    .N_HID(32),
    .N_OUT(3),
    .GAIN_SHIFT(4),
    .USE_EMA(1)
  ) u_ai_filter (
    .clk(clk),
    .rst_n(rst_n),

    .in_valid(in_valid),
    .in_q15(in_q15),
    .in_last(in_last),

    .clean_valid(clean_valid),
    .clean_q15(clean_q15),
    .clean_bit(clean_bit),

    .class_valid(class_valid),
    .class_idx(class_idx),

    .rtl_EMA_valid(rtl_EMA_valid),
    .rtl_EMA_clean_q15(rtl_EMA_clean_q15),

    .rtl_FC1_valid(rtl_FC1_valid),
    .rtl_FC1_last(rtl_FC1_last),
    .rtl_FC1_neuron_q15(rtl_FC1_neuron_q15),

    .rtl_ReLU_valid(rtl_ReLU_valid),
    .rtl_ReLU_neuron_q15(rtl_ReLU_neuron_q15),

    .rtl_FC2_valid(rtl_FC2_valid),
    .rtl_FC2_last(rtl_FC2_last),
    .rtl_FC2_logit_q15(rtl_FC2_logit_q15),

    .rtl_Argmax_valid(rtl_Argmax_valid),
    .rtl_Argmax_idx(rtl_Argmax_idx)
  );

  assign uo_out[0]   = clean_bit;
  assign uo_out[1]   = clean_valid;
  assign uo_out[3:2] = class_idx;
  assign uo_out[4]   = class_valid;
  assign uo_out[5]   = rtl_FC1_valid;
  assign uo_out[6]   = rtl_FC2_valid;
  assign uo_out[7]   = rtl_Argmax_valid;

  assign uio_out = clean_q15[15:8];

  assign uio_oe = 8'hFF;

  wire _unused;
  assign _unused = &{
    ena,
    in_last,
    rtl_EMA_valid,
    rtl_EMA_clean_q15,
    rtl_FC1_last,
    rtl_FC1_neuron_q15,
    rtl_ReLU_valid,
    rtl_ReLU_neuron_q15,
    rtl_FC2_last,
    rtl_FC2_logit_q15,
    rtl_Argmax_idx,
    1'b0
  };

endmodule

`default_nettype wire
