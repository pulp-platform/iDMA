# Copyright 2026 Mosaic SoC AG
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Each testbench declares its configuration suffixes here. The generic
# plumbing combines them into "<top>__<suffix>" build and run targets.
IDMA_VLT_TESTBENCHES := \
	tb_idma_otf_transpose \
	tb_idma_transpose_nd \
	tb_idma_transpose_b2b \
	tb_idma_transpose_midend \
	tb_idma_nd_midend_b2b \
	tb_idma_reg_frontend \
	tb_idma_rt_midend

IDMA_VLT_SUFFIXES_tb_idma_otf_transpose := sw8_fd0 sw8_fd1 sw64_fd0 sw64_fd1
IDMA_VLT_SUFFIXES_tb_idma_transpose_nd := dw32 dw64
IDMA_VLT_SUFFIXES_tb_idma_transpose_b2b := dw32 dw64
IDMA_VLT_SUFFIXES_tb_idma_transpose_midend := dw64 dw512
IDMA_VLT_SUFFIXES_tb_idma_nd_midend_b2b := default
IDMA_VLT_SUFFIXES_tb_idma_reg_frontend := ns1_nr1 ns2_nr1 ns2_nr2
IDMA_VLT_SUFFIXES_tb_idma_rt_midend := default

# Standalone transpose engine: explicitly enumerate the orthogonal
# StrbWidth x FullDuplex matrix.
IDMA_VLT_ELAB_ARGS_tb_idma_otf_transpose__sw8_fd0 := \
	-GStrbWidth=8 -GFullDuplex=0
IDMA_VLT_ELAB_ARGS_tb_idma_otf_transpose__sw8_fd1 := \
	-GStrbWidth=8 -GFullDuplex=1
IDMA_VLT_ELAB_ARGS_tb_idma_otf_transpose__sw64_fd0 := \
	-GStrbWidth=64 -GFullDuplex=0
IDMA_VLT_ELAB_ARGS_tb_idma_otf_transpose__sw64_fd1 := \
	-GStrbWidth=64 -GFullDuplex=1

IDMA_VLT_RUN_ARGS_tb_idma_otf_transpose__sw8_fd0 := +BP
IDMA_VLT_RUN_ARGS_tb_idma_otf_transpose__sw8_fd1 := +BP
IDMA_VLT_RUN_ARGS_tb_idma_otf_transpose__sw64_fd0 := +BP
IDMA_VLT_RUN_ARGS_tb_idma_otf_transpose__sw64_fd1 := +BP

# End-to-end transpose and transpose-midend bus-width configurations.
IDMA_VLT_ELAB_ARGS_tb_idma_transpose_nd__dw32 := -GDataWidth=32
IDMA_VLT_ELAB_ARGS_tb_idma_transpose_nd__dw64 := -GDataWidth=64
IDMA_VLT_ELAB_ARGS_tb_idma_transpose_b2b__dw32 := -GDataWidth=32
IDMA_VLT_ELAB_ARGS_tb_idma_transpose_b2b__dw64 := -GDataWidth=64
IDMA_VLT_ELAB_ARGS_tb_idma_transpose_midend__dw64 := -GDataWidth=64
IDMA_VLT_ELAB_ARGS_tb_idma_transpose_midend__dw512 := -GDataWidth=512

# Register frontend configurations cover one and two streams, plus arbitration
# between two independent register ports.
IDMA_VLT_ELAB_ARGS_tb_idma_reg_frontend__ns1_nr1 := -GNumStreams=1 -GNumRegs=1
IDMA_VLT_ELAB_ARGS_tb_idma_reg_frontend__ns2_nr1 := -GNumStreams=2 -GNumRegs=1
IDMA_VLT_ELAB_ARGS_tb_idma_reg_frontend__ns2_nr2 := -GNumStreams=2 -GNumRegs=2
