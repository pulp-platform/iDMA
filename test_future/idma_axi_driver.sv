// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Tobias Senti <tsenti@student.ethz.ch>

/// AXI driver
class idma_axi_driver #(
    parameter int AddrWidth = 32,
    parameter int DataWidth = 32,
    parameter int   IdWidth = 4,
    parameter int UserWidth = 1,
    parameter time       TA = 0ns, // application time
    parameter time       TT = 0ns  // test time
) implements idma_proto_test::idma_protocol_driver #(.AddrWidth(AddrWidth), .IdWidth(IdWidth), .DataWidth(DataWidth));

    typedef axi_test::axi_ax_beat #(.AW(AddrWidth), .IW(IdWidth), .UW(UserWidth)) ax_beat_t;
    typedef axi_test::axi_r_beat  #(.DW(DataWidth), .IW(IdWidth), .UW(UserWidth)) r_beat_t;

    // Use axi_driver
    axi_test::axi_driver #(
        .AW ( AddrWidth ),
        .DW ( DataWidth ),
        .IW (   IdWidth ),
        .UW ( UserWidth ),
        .TA (        TA ),
        .TT (        TT )
    ) driver;

    // Constructor
    function new(
        virtual AXI_BUS_DV #(
            .AXI_ADDR_WIDTH ( AddrWidth ),
            .AXI_DATA_WIDTH ( DataWidth ),
            .AXI_ID_WIDTH   (   IdWidth ),
            .AXI_USER_WIDTH ( UserWidth )
        ) axi_intf
    );
        this.driver = new(axi_intf);
    endfunction

    // Resets bus to idle state
    virtual function void reset();
        this.driver.reset_slave();
    endfunction

    // Waits until posedge on bus block
    virtual task wait_posedge();
      @(posedge this.driver.axi.clk_i);
    endtask
    
    // Waits until read request on AR channel is received
    virtual task receive_read(
        output logic [AddrWidth-1:0] addr,
        output logic [IdWidth-1:0] id,
        output int length
    );
        ax_beat_t beat = new;
        this.driver.recv_ar(beat);

        // Can only handle bussized reads
        if((1 << int'(beat.ax_size)) != DataWidth / 8)
          $fatal(1, "AXI Driver only supports bus sized reads! Read size: %d bytes", 1 << int'(beat.ax_size));

        addr   = beat.ax_addr;
        id     = beat.ax_id;
        length = int'(beat.ax_len) + 1;
    endtask

    // Sends data on R channel
    virtual task send_data(
        input logic [DataWidth-1:0] data,
        input logic [IdWidth-1:0] id,
        input logic last
    );
        r_beat_t beat = new;
        beat.r_data = data;
        beat.r_last = last;
        beat.r_resp = '0;
        beat.r_user = '0;
        beat.r_id   = id;

        this.driver.send_r(beat);
    endtask
endclass : idma_axi_driver