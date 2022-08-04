// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Thomas Benz <tbenz@ethz.ch>

`include "idma/typedef.svh"

/// testbench driver tasks and model for the iDMA
package idma_test;

    // byte
    typedef logic [7:0] byte_t;
    // half word
    typedef logic [15:0] halfw_t;



    // iDMA ND job object
    class idma_job #(
        parameter bit          IsND      = 0,
        parameter int unsigned NumDim    = 2,
        parameter int unsigned AddrWidth = 0
    );

        // derived types
        typedef logic [AddrWidth-1:0] addr_t;

        typedef struct packed {
            addr_t reps;
            addr_t src_strides;
            addr_t dst_strides;
        } dim_t;

        // fields describing a job
        addr_t                  length;
        addr_t                  src_addr;
        addr_t                  dst_addr;
        halfw_t                 max_src_len;
        halfw_t                 max_dst_len;
        logic                   aw_decoupled;
        logic                   rw_decoupled;
        dim_t [NumDim-2:0]      n_dims;
        addr_t                  err_addr    [$];
        logic                   err_is_read [$];
        idma_pkg::idma_eh_req_t err_action  [$];

        // format string for pretty printing
        string format = "\n-----------------------------------------------\
                        \niDMA %1dD job:\n num_bytes:      %d\n src:           %s\n dst:           %s\
                        \n max_src_len:  %s%d\n max_dst_len:  %s%d\
                        \n aw_decoupled:   %s%b\n rw_decoupled:   %s%b\n%s errors:\n%s\
                        \n-----------------------------------------------";

        // constructor: create an empty job
        function new ();
            length       = '0;
            src_addr     = '0;
            dst_addr     = '0;
            max_src_len  = '0;
            max_dst_len  = '0;
            aw_decoupled = '0;
            rw_decoupled = '0;
            n_dims       = '0;
            err_addr     = {};
            err_is_read  = {};
            err_action   = {};
        endfunction

        // helper function: nicely format a hex output
        function string format_hex (addr_t in);
            string num = $sformatf("%h", in);
            string res = "0x";
            int now = 1;
            foreach (num[i]) begin
                res = {res, num[i]};
                if (now % 4 == 0 & now != 0 & now != num.len())
                    res = {res, "_"};
                now++;
            end
            return res;
        endfunction

        // indent smaller types
        function string indent (int type_digits, int longest_type_width);
            string res = "";
            real digits = longest_type_width * 0.30103;
            for (int i = 0; i < (digits - type_digits); i++)
                res = {res, " "};
            return res;
        endfunction

        // create a string representing the ND-config
        function string format_dimensions();
            string res = "";
            for (int d = 0; d < NumDim-1; d++) begin
                res = {res, $sformatf(" Dimension %2d: \n", d+2)};
                res = {res, $sformatf("  reps:          %d", n_dims[d].reps), "\n"};
                res = {res, $sformatf("  src stride:   %s", format_hex(n_dims[d].src_strides)), "\n"};
                res = {res, $sformatf("  dst stride:   %s", format_hex(n_dims[d].dst_strides)), "\n"};
            end
            return res;
        endfunction

        // create and format the error list
        function string format_errors();
            string res       = "";
            string read_str  = "  read  err @ ";
            string write_str = "  write err @ ";
            string handler   = "";
            int unsigned num_err = this.err_addr.size();
            for (int i = 0; i < num_err; i++) begin
                if (this.err_action[i] == idma_pkg::CONTINUE)
                    handler = " (continue)";
                if (this.err_action[i] == idma_pkg::ABORT)
                    handler = " (abort)";
                if (this.err_is_read[i])
                    res = {res, read_str,  format_hex(this.err_addr[i]), handler, "\n"};
                else
                    res = {res, write_str, format_hex(this.err_addr[i]), handler, "\n"};
            end
            return res;
        endfunction

        // pretty print a job
        function string pprint ();
            return $sformatf(format,
                             IsND ? NumDim : 1,
                             this.length,
                             format_hex(this.src_addr),
                             format_hex(this.dst_addr),
                             indent(3, AddrWidth),
                             this.max_src_len,
                             indent(3, AddrWidth),
                             this.max_dst_len,
                             indent(1, AddrWidth),
                             this.aw_decoupled,
                             indent(1, AddrWidth),
                             this.rw_decoupled,
                             IsND ? format_dimensions() : "",
                             format_errors()
                            );
        endfunction

    endclass : idma_job



    // model class: holds the methods modeling a DMA transfer
    class idma_model #(
        parameter int unsigned AddrWidth   = 0,
        parameter int unsigned DataWidth   = 0,
        parameter bit ModelOutput = 0
    );

        // derived parameters
        localparam int unsigned StrbWidth   = DataWidth / 8;
        localparam int unsigned OffsetWidth = $clog2(StrbWidth);
        localparam int unsigned AxiMaxSize  = OffsetWidth;

        // derived types
        typedef logic [AddrWidth-1:0] addr_t;

        // model memory: byte-based
        byte_t mem [addr_t];

        // constructor
        function new ();
        endfunction

        // minimum function
        function addr_t min (addr_t a, addr_t b);
            return (a > b) ? b : a;
        endfunction

        // individual lower transfer boundaries
        function addr_t lower_page_boundry (addr_t addr, addr_t virt_page);
            return (addr / virt_page) * virt_page;
        endfunction

        // individual upper transfer boundaries
        function addr_t upper_page_boundry (addr_t addr, addr_t virt_page);
            return ((addr + virt_page) / virt_page) * virt_page - 'd1;
        endfunction

        // individual bytes remaining to break
        function addr_t bytes_remaing (addr_t addr, addr_t virt_page);
            return upper_page_boundry(addr, virt_page) + 'd1 - addr;
        endfunction

        // if coupled: combined bytes remaining to break
        function addr_t comb_bytes_remaing (
            addr_t src_addr,
            addr_t dst_addr,
            addr_t src_virt_page,
            addr_t dst_virt_page
        );
            return min(
                       bytes_remaing(src_addr, src_virt_page),
                       bytes_remaing(dst_addr, dst_virt_page)
                      );
        endfunction

        // possible length (how many bytes can a transfer be long starting from a given address)
        function addr_t poss_len (
            addr_t src_addr,
            addr_t dst_addr,
            addr_t src_virt_page,
            addr_t dst_virt_page,
            bit    decoupled,
            addr_t strb_width
        );
            automatic addr_t max_len = min(256 * strb_width, 4096);
            if (!decoupled) begin
                return min(
                           max_len,
                           comb_bytes_remaing(src_addr, dst_addr, src_virt_page, dst_virt_page)
                          );
            end else begin
                return min(max_len, bytes_remaing(src_addr, src_virt_page));
            end
        endfunction

        // write memory array
        function void write_byte (
            byte_t wbyte,
            addr_t addr
        );
            this.mem[addr] = wbyte;
        endfunction

        // read memory array
        function byte_t read_byte (
            addr_t addr
        );
            if (mem.exists(addr))
                return this.mem[addr];
            else
                return 'x;
        endfunction

        // model a DMA transfer
        function void transfer (
            // length of the transfer
            addr_t   length,
            // source address
            addr_t   src_addr,
            // destination address
            addr_t   dst_addr,
            // maximum length of a burst (in bytes)
            halfw_t  max_src_len,
            // maximum length of a burst (in bytes)
            halfw_t  max_dst_len,
            // is the transfer rw_decoupled?
            logic   rw_decoupled,
            // array with the error addresses
            ref addr_t                  err_addr [$],
            // array with the error types
            ref logic                   err_is_read [$],
            // array with the error handling actions
            ref idma_pkg::idma_eh_req_t err_action [$]
        );
            // signals
            byte_t  temp;         // temporary byte
            addr_t  src_ptr;      // source pointer
            addr_t  dst_ptr;      // destination pointer
            addr_t  poss_src_len; // the maximum possible length of a valid transfer from an addr
            addr_t  poss_dst_len; // the maximum possible length of a valid transfer from an addr
            addr_t  src_base;     // the base address of the transfer
            addr_t  dst_base;     // the base address of the transfer
            addr_t  src_len;      // the length of the transfer
            addr_t  dst_len;      // the length of the transfer
            addr_t  err_now;      // the current error pointer (both r/w)
            addr_t  err_src_ptr;  // error pointers
            addr_t  err_dst_ptr;  // error pointers
            logic   read_error;   // error happens for the current byte
            logic   write_error;  // error happens for the current byte
            int     err_idx [$];  // used in searching the array -> index of match
            idma_pkg::idma_eh_req_t read_action;  // error actions
            idma_pkg::idma_eh_req_t write_action; // error actions
            // initial assignments
            addr_t  now             =  '0;  // current address pointer
            halfw_t last_w_err_len  =  '0;  // we have to keep track of w transfers
            logic   aborted         = 1'b0; // flag: a transfer was aborted
            halfw_t src_virt_page   = min(max_src_len * StrbWidth, 'd4096);
            halfw_t dst_virt_page   = min(max_dst_len * StrbWidth, 'd4096);

            // loop over all bytes in transfer
            while (now < length) begin

                // current read / write pointers
                src_ptr = src_addr + now;
                dst_ptr = dst_addr + now;

                // length of the transfer the current byte belongs to
                if (rw_decoupled) begin
                    poss_src_len = poss_len(src_ptr, '0, src_virt_page, '0, '1, StrbWidth);
                    poss_dst_len = poss_len(dst_ptr, '0, dst_virt_page, '0, '1, StrbWidth);
                    src_len = min(length - now, poss_src_len); // remaining bytes
                    dst_len = min(length - now, poss_dst_len); // remaining bytes
                end else begin
                    poss_src_len = poss_len(
                                            src_ptr,
                                            dst_ptr,
                                            src_virt_page,
                                            dst_virt_page,
                                            '0,
                                            StrbWidth
                                           );
                    src_len = min(length - now, poss_src_len);
                    dst_len = src_len;
                end

                // src and dst base addresses (DMA always sends size = AxiMaxSize = log(2, StrbW))
                src_base = axi_pkg::aligned_addr(src_ptr, AxiMaxSize);
                dst_base = axi_pkg::aligned_addr(dst_ptr, AxiMaxSize);

                // check if there is a read error:
                err_now = 0;
                read_error = 0;
                // if a byte in the bus_width is an error -> whole word is a read error
                while (err_now < StrbWidth) begin
                    err_src_ptr = src_base + err_now;
                    // check if error is in array of errors
                    err_idx = err_addr.find_first_index with (item == err_src_ptr);
                    // error found and it is a read error
                    if (err_idx.size() > 0 && err_is_read[err_idx[0]]) begin
                        // extract action
                        read_action = err_action[err_idx[0]];
                        read_error  = 1;
                    end
                    err_now++;
                end

                // check if there is a new write error:
                write_error = 0;
                // we can encounter a new error
                if (last_w_err_len == '0) begin
                    err_now = 0;
                    // if a byte in a burst is an error -> whole burst will fail
                    while (err_now < dst_len) begin
                        err_dst_ptr = dst_base + err_now;
                        // check if error is in array of errors
                        err_idx = err_addr.find_first_index with (item == err_dst_ptr);
                        // error found and it is a write error
                        if (err_idx.size() > 0 && !err_is_read[err_idx[0]]) begin
                            // extract action
                            write_action   = err_action[err_idx[0]];
                            // load counter to keep error active until the end of the burst
                            last_w_err_len = dst_len - 'd1;
                            write_error    = 1;
                        end
                        err_now++;
                    end
                // keep write error active until burst is done
                end else begin
                    write_error = 1;
                    last_w_err_len--;
                end

                // aborted transfers do not cause errors
                if (aborted) begin
                    read_error  = 0;
                    write_error = 0;
                end

                // debug output head
                if (ModelOutput) begin
                    $display();
                    $display("---");
                    $display("Copy from byte 0x%h - belongs to transfer: 0x%h with rem. length %d",
                             src_ptr, src_base, src_len - 'd1);
                    $display("Copy to   byte 0x%h - belongs to transfer: 0x%h with rem. length %d",
                             dst_ptr, dst_base, dst_len - 'd1);
                    if (read_error)
                        $display("Read Error:  %p", read_action);
                    if (write_error)
                        $display("Write Error: %p - active for %d more bytes",
                                 write_action, last_w_err_len);
                end

                // how error is handled
                // no error
                if (!aborted & !read_error & !write_error) begin
                    temp = read_byte(src_ptr);
                    write_byte(temp, dst_ptr);
                    if (ModelOutput) begin
                        $display("Read  %h from 0x%h", temp, src_ptr);
                        $display("Write %h to   0x%h", temp, dst_ptr);
                    end
                // error happened
                end else begin
                    // continue
                    if (read_error && read_action === idma_pkg::CONTINUE) begin
                        temp = 'x;
                        if (ModelOutput)
                            $display("Read  %h from 0x%h", temp, src_ptr);
                    end
                    if (write_error && write_action === idma_pkg::CONTINUE) begin
                        temp = 'x;
                    end
                    // abort
                    if (read_error && read_action === idma_pkg::ABORT) begin
                        aborted = 1;
                        temp = 'x;
                    end
                    if (write_error && write_action === idma_pkg::ABORT) begin
                        aborted = 1;
                        temp = 'x;
                    end
                    // // replay (not implemented in hardware )
                    // if (read_error && read_action === idma_pkg::REPLAY) begin
                    //     temp = read_byte(src_ptr);
                    //     if (ModelOutput)
                    //         $display("Eventually read  %h from 0x%h", temp, src_ptr);
                    // end
                    // if (write_error && write_action === idma_pkg::REPLAY) begin
                    //     if (ModelOutput)
                    //         $display("Eventually write %h to   0x%h", temp, dst_ptr);
                    // end
                    // aborted
                    if (aborted) begin
                        if (ModelOutput) begin
                            $display("Omitted read  from 0x%h", src_ptr);
                            $display("Omitted write to   0x%h", dst_ptr);
                        end
                    end
                    // write
                    if (!aborted) begin
                        write_byte(temp, dst_ptr);
                        if (ModelOutput)
                            $display("Write %h to   0x%h", temp, dst_ptr);
                    end
                end

                // write abort logic
                if ((write_error && write_action === idma_pkg::ABORT) & last_w_err_len === '0) begin
                    // abort all further transfers
                    aborted = 1;
                    if (ModelOutput)
                        $display("Aborting all further elements of this \
                                  transfer due to write error");
                end

                // read abort logic
                if ((read_error && read_action === idma_pkg::ABORT) &
                    ((src_ptr + 'd1) % StrbWidth) == '0) begin
                    // abort all further transfers
                    aborted = 1;
                    if (ModelOutput)
                        $display("Aborting all further elements of this \
                                  transfer due to read  error");
                end

                // debug print tail
                if (ModelOutput) begin
                    $display("---");
                end

                // next byte
                now++;
            end
        endfunction

    endclass : idma_model



    // Class implementing a model for the ND-midend
    class idma_nd_midend_model #(
        parameter int unsigned AddrWidth = 0,
        parameter int unsigned NumDim = 0,
        parameter bit ModelOutput = 0
    );

        // derived types
        typedef logic [AddrWidth-1:0]   addr_t;

        typedef idma_test::idma_job #(
            .AddrWidth   ( AddrWidth ),
            .NumDim      ( NumDim    ),
            .IsND        ( 1'b1      )
        ) tb_dma_job_t;

        // creates a list of 1D job from the ND job
        function void decompose (
            tb_dma_job_t nd_job,
            ref tb_dma_job_t out_jobs [$]
        );
            // counters to hold the current state
            addr_t [NumDim-2:0] counters = '0;
            bit    [NumDim-2:0] active   = '0;
            bit                 done     = '0;
            // address accumulators
            addr_t src_addr              = nd_job.src_addr;
            addr_t dst_addr              = nd_job.dst_addr;
            // strides to add
            addr_t src_stride            = '0;
            addr_t dst_stride            = '0;
            // the current job
            automatic tb_dma_job_t now;

            // init counters
            for (int d = 0; d < NumDim-1; d++) begin
                // set initial number of repetitions
                counters[d] = nd_job.n_dims[d].reps;
                // only dimensions != 0 are active
                if (nd_job.n_dims[d].reps != 0) begin
                    active[d]   = 1;
                end
            end

            // decompose
            // at least one dimension must be active
            if (active != '0) begin
                // while not done
                while (!done) begin
                    // emit job
                    if (ModelOutput)
                        $display("Emitting: %h - %h", src_addr, dst_addr);
                    // create a new job
                    now = new();
                    // fill-in some detail
                    now.length        = nd_job.length;
                    now.max_src_len   = nd_job.max_src_len;
                    now.max_dst_len   = nd_job.max_dst_len;
                    now.aw_decoupled  = nd_job.aw_decoupled;
                    now.rw_decoupled  = nd_job.rw_decoupled;
                    now.err_addr      = nd_job.err_addr;
                    now.err_is_read   = nd_job.err_is_read;
                    now.err_action    = nd_job.err_action;
                    now.src_addr      = src_addr;
                    now.dst_addr      = dst_addr;
                    // append to queue
                    out_jobs.push_back(now);

                    // iterate over all dimensions
                    for (int d = 0; d < NumDim-1; d++) begin
                        // we are the innermost counter and active
                        if (d == 0 && active[0]) begin
                            // if the counter is counting -> add stride
                            if (counters[d] != '0)
                                src_stride = nd_job.n_dims[0].src_strides;
                                dst_stride = nd_job.n_dims[0].dst_strides;
                            // decrement counter now
                            counters[d] = counters[d] - 1;
                            // if only the innermost dimension is active and we are 0 -> done
                            if (active == 'd1 && counters[d] == 0)
                                done = 1;
                        // the higher dimensions
                        end else if(active[d]) begin
                            // if the counter below is 0: decrement and reset lower counter
                            // and add stride
                            if (counters[d-1] == '0) begin
                                counters[d]  = counters[d] - 1;
                                counters[d-1] = nd_job.n_dims[d-1].reps;
                                    src_stride = nd_job.n_dims[d].src_strides;
                                    dst_stride = nd_job.n_dims[d].dst_strides;
                            end
                            // if a counter is done and the counter above is done too -> done
                            if (counters[d] == '0 && d != NumDim-2 && counters[d+1] == 'd1)
                                done = 1;
                        end
                    end

                    // add strides
                    src_addr = src_addr + src_stride;
                    dst_addr = dst_addr + dst_stride;
                end
            end

        endfunction

    endclass



    // Driver for the iDMA interface
    class idma_driver #(
        parameter int unsigned DataWidth = 0,
        parameter int unsigned AddrWidth = 0,
        parameter int unsigned UserWidth = 0,
        parameter int unsigned AxiIdWidth = 0,
        parameter int unsigned TFLenWidth = 0,
        parameter time TA = 0ns , // stimuli application time
        parameter time TT = 0ns   // stimuli test time
    );

        // derived parameters
        localparam int unsigned StrbWidth   = DataWidth / 8;
        localparam int unsigned OffsetWidth = $clog2(StrbWidth);

        // derived types
        typedef logic [AddrWidth-1:0]   addr_t;
        typedef logic [DataWidth-1:0]   data_t;
        typedef logic [StrbWidth-1:0]   strb_t;
        typedef logic [UserWidth-1:0]   user_t;
        typedef logic [AxiIdWidth-1:0]  id_t;
        typedef logic [OffsetWidth-1:0] offset_t;
        typedef logic [TFLenWidth-1:0]  tf_len_t;

        // iDMA request / response types
        `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
        `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

        // instantiate a virtual driver interface
        virtual IDMA_DV #(
            .DataWidth  ( DataWidth   ),
            .AddrWidth  ( AddrWidth   ),
            .UserWidth  ( UserWidth   ),
            .AxiIdWidth ( AxiIdWidth  ),
            .TFLenWidth ( TFLenWidth  )
        ) idma;

        // constructor, connect virtual interface
        function new(
            virtual IDMA_DV #(
                .DataWidth  ( DataWidth   ),
                .AddrWidth  ( AddrWidth   ),
                .UserWidth  ( UserWidth   ),
                .AxiIdWidth ( AxiIdWidth  ),
                .TFLenWidth ( TFLenWidth  )
            ) idma
        );
            this.idma = idma;
        endfunction

        // reset the driver
        function void reset_driver();
            idma.req               <= '0;
            idma.req.opt.src.burst <= axi_pkg::BURST_INCR;
            idma.req.opt.dst.burst <= axi_pkg::BURST_INCR;
            idma.req_valid         <= '0;
            idma.rsp_ready         <= '0;
            idma.eh_req            <= '0;
            idma.eh_req_valid      <= '0;
        endfunction

        // start a cycle at the test time
        task cycle_start;
            #TT;
        endtask

        // end the cycle at the clock edge
        task cycle_end;
            @(posedge idma.clk_i);
        endtask

        /// launch_transfer
        task launch_tf (
            input tf_len_t    length,
            input addr_t      src_addr,
            input addr_t      dst_addr,
            input logic       decouple_aw,
            input logic       decouple_rw,
            input logic [2:0] src_max_llen,
            input logic [2:0] dst_max_llen,
            input logic       src_reduce_len,
            input logic       dst_reduce_len
        );
            idma.req.length                 <= #TA length;
            idma.req.src_addr               <= #TA src_addr;
            idma.req.dst_addr               <= #TA dst_addr;
            idma.req.opt.beo.decouple_aw    <= #TA decouple_aw;
            idma.req.opt.beo.decouple_rw    <= #TA decouple_rw;
            idma.req.opt.beo.src_max_llen   <= #TA src_max_llen;
            idma.req.opt.beo.dst_max_llen   <= #TA dst_max_llen;
            idma.req.opt.beo.src_reduce_len <= #TA src_reduce_len;
            idma.req.opt.beo.dst_reduce_len <= #TA dst_reduce_len;
            idma.req_valid                  <= #TA 1;
            cycle_start();
            while (idma.req_ready != 1) begin cycle_end(); cycle_start(); end
            cycle_end();
            idma.req.length                 <= #TA '0;
            idma.req.src_addr               <= #TA '0;
            idma.req.dst_addr               <= #TA '0;
            idma.req.opt.beo.decouple_aw    <= #TA '0;
            idma.req.opt.beo.decouple_rw    <= #TA '0;
            idma.req.opt.beo.src_max_llen   <= #TA '0;
            idma.req.opt.beo.dst_max_llen   <= #TA '0;
            idma.req.opt.beo.src_reduce_len <= #TA '0;
            idma.req.opt.beo.dst_reduce_len <= #TA '0;
            idma.req_valid                  <= #TA '0;
        endtask

        /// wait for a transfer to complete
        task wait_tf (
            output axi_pkg::resp_t      cause,
            output idma_pkg::err_type_t err_type,
            output addr_t               burst_addr,
            output logic                error,
            output logic                last
        );
            idma.rsp_ready <= #TA 1;
            cycle_start();
            while (idma.rsp_valid != 1) begin cycle_end(); cycle_start(); end
            error      = idma.rsp.error;
            last       = idma.rsp.last;
            err_type   = idma.rsp.pld.err_type;
            cause      = idma.rsp.pld.cause;
            burst_addr = idma.rsp.pld.burst_addr;
            cycle_end();
            idma.rsp_ready <= #TA 0;
        endtask

        /// handle errors
        task handle_error (
            input idma_pkg::idma_eh_req_t eh
        );
            idma.eh_req        <= #TA eh;
            idma.eh_req_valid  <= #TA 1;
            cycle_start();
            while (idma.eh_req_ready != 1) begin cycle_end(); cycle_start(); end
            cycle_end();
            idma.eh_req        <= #TA '0;
            idma.eh_req_valid  <= #TA '0;
        endtask

    endclass : idma_driver



    // Driver for the the nd midend interface
    class idma_nd_driver #(
        parameter int unsigned DataWidth = 0,
        parameter int unsigned AddrWidth = 0,
        parameter int unsigned UserWidth = 0,
        parameter int unsigned AxiIdWidth = 0,
        parameter int unsigned TFLenWidth = 0,
        parameter int unsigned NumDim = 0,
        parameter int unsigned RepWidth = 0,
        parameter int unsigned StrideWidth = 0,
        parameter time TA = 0ns , // stimuli application time
        parameter time TT = 0ns   // stimuli test time
    );

        // derived parameters
        localparam int unsigned StrbWidth   = DataWidth / 8;
        localparam int unsigned OffsetWidth = $clog2(StrbWidth);

         // derived types
        typedef logic [AddrWidth-1:0]   addr_t;
        typedef logic [DataWidth-1:0]   data_t;
        typedef logic [StrbWidth-1:0]   strb_t;
        typedef logic [UserWidth-1:0]   user_t;
        typedef logic [AxiIdWidth-1:0]  id_t;
        typedef logic [OffsetWidth-1:0] offset_t;
        typedef logic [TFLenWidth-1:0]  tf_len_t;
        typedef logic [RepWidth-1:0]    reps_t;
        typedef logic [StrideWidth-1:0] strides_t;

        // iDMA request / response types
        `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
        `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

        // iDMA ND request
        `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, strides_t)

        // instantiate a virtual driver interface
        virtual IDMA_ND_DV #(
            .DataWidth    ( DataWidth   ),
            .AddrWidth    ( AddrWidth   ),
            .UserWidth    ( UserWidth   ),
            .AxiIdWidth   ( AxiIdWidth  ),
            .TFLenWidth   ( TFLenWidth  ),
            .NumDim       ( NumDim      ),
            .RepWidth     ( RepWidth    ),
            .StrideWidth  ( StrideWidth )
        ) nd_idma;

        // constructor, connect virtual interface
        function new(
            virtual IDMA_ND_DV #(
                .DataWidth   ( DataWidth   ),
                .AddrWidth   ( AddrWidth   ),
                .UserWidth   ( UserWidth   ),
                .AxiIdWidth  ( AxiIdWidth  ),
                .TFLenWidth  ( TFLenWidth  ),
                .NumDim      ( NumDim      ),
                .RepWidth    ( RepWidth    ),
                .StrideWidth ( StrideWidth )
            ) nd_idma
        );
            this.nd_idma = nd_idma;
        endfunction

        // reset the driver
        function void reset_driver();
            nd_idma.req                         <= '0;
            nd_idma.req.burst_req.opt.src.burst <= axi_pkg::BURST_INCR;
            nd_idma.req.burst_req.opt.dst.burst <= axi_pkg::BURST_INCR;
            nd_idma.req_valid                   <= '0;
            nd_idma.rsp_ready                   <= '0;
            nd_idma.eh_req                      <= '0;
            nd_idma.eh_req_valid                <= '0;
        endfunction

        // start a cycle at the test time
        task cycle_start;
            #TT;
        endtask

        // end the cycle at the clock edge
        task cycle_end;
            @(posedge nd_idma.clk_i);
        endtask

        /// launch_transfer
        task launch_nd_tf (
            input tf_len_t                  length,
            input addr_t                    src_addr,
            input addr_t                    dst_addr,
            input logic                     decouple_aw,
            input logic                     decouple_rw,
            input logic [2:0]               src_max_llen,
            input logic [2:0]               dst_max_llen,
            input logic                     src_reduce_len,
            input logic                     dst_reduce_len,
            input idma_d_req_t [NumDim-2:0] n_dims
        );
            nd_idma.req.burst_req.length                 <= #TA length;
            nd_idma.req.burst_req.src_addr               <= #TA src_addr;
            nd_idma.req.burst_req.dst_addr               <= #TA dst_addr;
            nd_idma.req.burst_req.opt.beo.decouple_aw    <= #TA decouple_aw;
            nd_idma.req.burst_req.opt.beo.decouple_rw    <= #TA decouple_rw;
            nd_idma.req.burst_req.opt.beo.src_max_llen   <= #TA src_max_llen;
            nd_idma.req.burst_req.opt.beo.dst_max_llen   <= #TA dst_max_llen;
            nd_idma.req.burst_req.opt.beo.src_reduce_len <= #TA src_reduce_len;
            nd_idma.req.burst_req.opt.beo.dst_reduce_len <= #TA dst_reduce_len;
            // connect ND signals
            nd_idma.req.d_req                            <= #TA n_dims;
            nd_idma.req_valid                            <= #TA 1;
            cycle_start();
            while (nd_idma.req_ready != 1) begin cycle_end(); cycle_start(); end
            cycle_end();
            nd_idma.req.burst_req.length                 <= #TA '0;
            nd_idma.req.burst_req.src_addr               <= #TA '0;
            nd_idma.req.burst_req.dst_addr               <= #TA '0;
            nd_idma.req.burst_req.opt.beo.decouple_aw    <= #TA '0;
            nd_idma.req.burst_req.opt.beo.decouple_rw    <= #TA '0;
            nd_idma.req.burst_req.opt.beo.src_max_llen   <= #TA '0;
            nd_idma.req.burst_req.opt.beo.dst_max_llen   <= #TA '0;
            nd_idma.req.burst_req.opt.beo.src_reduce_len <= #TA '0;
            nd_idma.req.burst_req.opt.beo.dst_reduce_len <= #TA '0;
            nd_idma.req.d_req                            <= #TA '0;
            nd_idma.req_valid                            <= #TA '0;
        endtask

        /// wait for a transfer to complete
        task wait_tf (
            output axi_pkg::resp_t      cause,
            output idma_pkg::err_type_t err_type,
            output addr_t               burst_addr,
            output logic                error,
            output logic                last
        );
            nd_idma.rsp_ready <= #TA 1;
            cycle_start();
            while (nd_idma.rsp_valid != 1) begin cycle_end(); cycle_start(); end
            error      = nd_idma.rsp.error;
            last       = nd_idma.rsp.last;
            err_type   = nd_idma.rsp.pld.err_type;
            cause      = nd_idma.rsp.pld.cause;
            burst_addr = nd_idma.rsp.pld.burst_addr;
            cycle_end();
            nd_idma.rsp_ready <= #TA 0;
        endtask

        /// handle errors
        task handle_error (
            input idma_pkg::idma_eh_req_t eh
        );
            nd_idma.eh_req        <= #TA eh;
            nd_idma.eh_req_valid  <= #TA 1;
            cycle_start();
            while (nd_idma.eh_req_ready != 1) begin cycle_end(); cycle_start(); end
            cycle_end();
            nd_idma.eh_req        <= #TA '0;
            nd_idma.eh_req_valid  <= #TA '0;
        endtask

    endclass : idma_nd_driver

endpackage : idma_test
