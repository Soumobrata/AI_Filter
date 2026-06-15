# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start AI filter smoke test")

    clock = Clock(dut.clk, 20, unit="ns")
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)

    # Feed 100 samples.
    # ui_in[0] = in_valid
    # ui_in[1] = in_last/reserved
    # ui_in[7:2] = upper sample bits
    # uio_in[7:0] = lower sample bits
    for i in range(100):
        dut.ui_in.value = 0x01 | ((i & 0x3F) << 2)
        dut.uio_in.value = i & 0xFF
        await ClockCycles(dut.clk, 1)

    dut.ui_in.value = 0
    dut.uio_in.value = 0

    # Wait for FC1 + FC2 sequential processing
    await ClockCycles(dut.clk, 5000)

    # Smoke checks
    assert dut.uio_oe.value == 0xFF
    assert dut.uo_out.value.integer >= 0
