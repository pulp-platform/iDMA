// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Tobias Senti <tsenti@student.ethz.ch>

/// Abstract protocol driver
interface class idma_protocol_driver #(
    parameter int AddrWidth,
    parameter int IdWidth,
    parameter int DataWidth
);
    // Resets bus to idle state
    pure virtual function void reset();

    // Waits until posedge on bus block
    pure virtual task wait_posedge();

    // Receive read request from DMA
    pure virtual task receive_read(
        output logic [AddrWidth-1:0] addr,
        output logic [IdWidth-1:0] id,
        output int length
    );

    // Send data to DMA
    pure virtual task send_data(
        input logic [DataWidth-1:0] data,
        input logic [IdWidth-1:0] id,
        input logic last
    );
endclass : idma_protocol_driver
