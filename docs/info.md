# AI-Based Sequential Neural Filter

## How it works

This project implements a small hardware neural-network filter for signal restoration and timing/error classification. The design accepts signed Q1.15 input samples one at a time, applies an optional centered EMA smoothing stage, buffers one input window, and then evaluates a two-layer fully connected neural network using time-multiplexed MAC hardware.

The network structure is:

```text
Input window → EMA / bypass → FC1 → ReLU → FC2 → Argmax
```

Unlike a fully combinational neural network, this implementation reuses MAC hardware sequentially to reduce area. The trained weights and biases are stored as Q1.15 hexadecimal memory files.

## Input/output behavior

| Signal         | Direction | Description                                   |
| -------------- | --------: | --------------------------------------------- |
| `clk`          |     input | Main project clock                            |
| `rst_n`        |     input | Active-low reset                              |
| `ui_in[0]`     |     input | Serial/sample data input bit or control input |
| `ui_in[1]`     |     input | Input valid / shift enable                    |
| `ui_in[2]`     |     input | Input last / end-of-window marker             |
| `ui_in[7:3]`   |     input | Reserved                                      |
| `uo_out[0]`    |    output | Cleaned binary output                         |
| `uo_out[2:1]`  |    output | Neural-network class index                    |
| `uo_out[3]`    |    output | Clean output valid                            |
| `uo_out[4]`    |    output | Class output valid                            |
| `uo_out[7:5]`  |    output | Debug/status                                  |
| `uio_out[7:0]` |    output | Lower 8 bits of cleaned Q1.15 output          |
| `uio_oe[7:0]`  |    output | Set high when using `uio_out` as output       |
| `uio_in[7:0]`  |     input | Reserved                                      |

## How to test

1. Hold `rst_n` low to reset the design.
2. Release reset with `rst_n = 1`.
3. Stream Q1.15 samples into the design.
4. Assert input-valid while each sample is loaded.
5. Assert the end-of-window marker on the final sample of a window.
6. Wait for `class_valid`.
7. Read:

   * `uo_out[0]` for the cleaned binary output.
   * `uo_out[2:1]` for the predicted class.
   * `uio_out[7:0]` for debug visibility of the cleaned Q1.15 signal.

## Expected behavior

The circuit produces a smoothed/cleaned signal output and a 3-class neural-network decision. The class output is valid only when `class_valid` is asserted.

## External hardware

No special external hardware is required. The design can be driven from the TinyTapeout demo board, an RP2040 script, FPGA, or logic analyzer pattern generator.

## Design notes

The implementation is intended as a compact ASIC demonstration of an AI-assisted nonlinear signal filter. The main objective is to show a hardware-friendly neural filter architecture using fixed-point arithmetic, sequential MAC reuse, ReLU activation, and argmax classification.
