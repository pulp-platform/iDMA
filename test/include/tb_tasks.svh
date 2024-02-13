// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>


    // write a byte to the AXI-attached memory
`ifdef PROT_AXI4
    task write_byte_axi_mem (
        input byte_t byte_i,
        input addr_t addr_i
    );
        i_axi_sim_mem.mem[addr_i] = byte_i;
    endtask

    // read a byte from the AXI-attached memory
    task read_byte_axi_mem (
        output byte_t byte_o,
        input  addr_t addr_i
    );
        if (i_axi_sim_mem.mem.exists(addr_i))
            byte_o = i_axi_sim_mem.mem[addr_i];
        else
            byte_o = '1;
    endtask
`else
    task write_byte_axi_mem (
        input byte_t byte_i,
        input addr_t addr_i
    );
        $fatal(1, "AXI Protocol not available");
    endtask

    // read a byte from the AXI-attached memory
    task read_byte_axi_mem (
        output byte_t byte_o,
        input  addr_t addr_i
    );
        $fatal(1, "AXI Protocol not available");
        byte_o = 'x;
    endtask
`endif

`ifdef PROT_AXI4_LITE
    // write a byte to the AXI-Lite AXI-attached memory
    task write_byte_axi_lite_axi_mem (
        input byte_t byte_i,
        input addr_t addr_i
    );
        i_axi_lite_axi_sim_mem.mem[addr_i] = byte_i;
    endtask

    // read a byte from the AXI-Lite AXI-attached memory
    task read_byte_axi_lite_axi_mem (
        output byte_t byte_o,
        input  addr_t addr_i
    );
        if (i_axi_lite_axi_sim_mem.mem.exists(addr_i))
            byte_o = i_axi_lite_axi_sim_mem.mem[addr_i];
        else
            byte_o = '1;
    endtask
`else
    // write a byte to the AXI-Lite AXI-attached memory
    task write_byte_axi_lite_axi_mem (
        input byte_t byte_i,
        input addr_t addr_i
    );
        $fatal(1, "AXI Lite Protocol not available");
    endtask

    // read a byte from the AXI-Lite AXI-attached memory
    task read_byte_axi_lite_axi_mem (
        output byte_t byte_o,
        input  addr_t addr_i
    );
        $fatal(1, "AXI Lite Protocol not available");
        byte_o = 'x;
    endtask
`endif

`ifdef PROT_OBI
    // write a byte to the OBI AXI-attached memory
    task write_byte_obi_axi_mem (
        input byte_t byte_i,
        input addr_t addr_i
    );
        i_obi_axi_sim_mem.mem[addr_i] = byte_i;
    endtask

    // read a byte from the OBI AXI-attached memory
    task read_byte_obi_axi_mem (
        output byte_t byte_o,
        input  addr_t addr_i
    );
        if (i_obi_axi_sim_mem.mem.exists(addr_i))
            byte_o = i_obi_axi_sim_mem.mem[addr_i];
        else
            byte_o = '1;
    endtask
`else
    // write a byte to the OBI AXI-attached memory
    task write_byte_obi_axi_mem (
        input byte_t byte_i,
        input addr_t addr_i
    );
        $fatal(1, "OBI Protocol not available");
    endtask

    // read a byte from the OBI AXI-attached memory
    task read_byte_obi_axi_mem (
        output byte_t byte_o,
        input  addr_t addr_i
    );
        $fatal(1, "OBI Protocol not available");
        byte_o = 'x;
    endtask
`endif

`ifdef PROT_TILELINK
    // write a byte to the TileLink AXI-attached memory
    task write_byte_tilelink_axi_mem (
        input byte_t byte_i,
        input addr_t addr_i
    );
        i_tilelink_axi_sim_mem.mem[addr_i] = byte_i;
    endtask

    // read a byte from the TileLink AXI-attached memory
    task read_byte_tilelink_axi_mem (
        output byte_t byte_o,
        input  addr_t addr_i
    );
        if (i_tilelink_axi_sim_mem.mem.exists(addr_i))
            byte_o = i_tilelink_axi_sim_mem.mem[addr_i];
        else
            byte_o = '1;
    endtask
`else
    // write a byte to the TileLink AXI-attached memory
    task write_byte_tilelink_axi_mem (
        input byte_t byte_i,
        input addr_t addr_i
    );
        $fatal(1, "TileLink Protocol not available");
    endtask

    // read a byte from the TileLink AXI-attached memory
    task read_byte_tilelink_axi_mem (
        output byte_t byte_o,
        input  addr_t addr_i
    );
        $fatal(1, "TileLink Protocol not available");
        byte_o = 'x;
    endtask
`endif

`ifdef PROT_AXI4_STREAM
    // write a byte to the AXI Stream AXI-attached memory
    task write_byte_axis_axi_mem (
        input byte_t byte_i,
        input addr_t addr_i
    );
        i_axis_axi_sim_mem.mem[addr_i] = byte_i;
    endtask

    // read a byte from the AXI Stream AXI-attached memory
    task read_byte_axis_axi_mem (
        output byte_t byte_o,
        input  addr_t addr_i
    );
        if (i_axis_axi_sim_mem.mem.exists(addr_i))
            byte_o = i_axis_axi_sim_mem.mem[addr_i];
        else
            byte_o = '1;
    endtask
`else
    // write a byte to the AXI Stream AXI-attached memory
    task write_byte_axis_axi_mem (
        input byte_t byte_i,
        input addr_t addr_i
    );
        $fatal(1, "AXI Stream Protocol not available");
    endtask

    // read a byte from the AXI Stream AXI-attached memory
    task read_byte_axis_axi_mem (
        output byte_t byte_o,
        input  addr_t addr_i
    );
        $fatal(1, "AXI Stream Protocol not available");
        byte_o = 'x;
    endtask
`endif

`ifdef PROT_AXI4
    // set error flag in the AXI-attached memory
    task set_error_mem (
        input addr_t          addr_i,
        input logic           is_read_i,
        input axi_pkg::resp_t resp_i
    );
        if (is_read_i)
            i_axi_sim_mem.rerr[addr_i] = resp_i;
        else
            i_axi_sim_mem.werr[addr_i] = resp_i;
    endtask
`else
     // set error flag in the AXI-attached memory
    task set_error_mem (
        input addr_t          addr_i,
        input logic           is_read_i,
        input axi_pkg::resp_t resp_i
    );
        $fatal(1, "AXI Protocol not available");
    endtask
`endif

    // compare if a range of bytes matches
    task compare_mem (
        input  addr_t               length_i,
        input  addr_t               addr_i,
        input  idma_pkg::protocol_e protocol,
        output logic                match_o
    );
        byte_t data;
        byte_t model_byte;
        addr_t now;
        logic  local_match;
        logic  local_x;
        now = 0;
        match_o = 1;
        while (now < length_i) begin
            case(protocol)
            idma_pkg::AXI: read_byte_axi_mem (data, addr_i + now);
            idma_pkg::AXI_LITE: read_byte_axi_lite_axi_mem (data, addr_i + now); 
            idma_pkg::OBI: read_byte_obi_axi_mem (data, addr_i + now);
            idma_pkg::TILELINK: read_byte_tilelink_axi_mem (data, addr_i + now);
            idma_pkg::AXI_STREAM: read_byte_axis_axi_mem(data, addr_i + now);
            idma_pkg::INIT: begin
                now++;
                continue; // Omit checks against INIT terminate events
            end
            default: $fatal(1, "compare_mem for protocol %d not implemented!", protocol);
            endcase
            // omit check against ff (DMA init memory state to simplify error model - ideally this will be rewritten at some point)
            if (data === 8'hff) begin
                if (Debug)
                    $display("[tb  ] omit check against 0xff @0x%h", addr_i + now);
                now++;
                continue;
            end
            model_byte = model.read_byte (addr_i + now, protocol);
            // check if match
            local_match = (data == model_byte);
            // check if at least a bit is 'x
            local_x = 1'b0;
            for (int i = 0; i < 8; i++)
                local_x = local_x | (data[i] === 1'bx);
            // global match flag for the burst
            match_o = match_o & local_match & !local_x;
            if (Debug)
                $display("[tb  ] compare:    %h - %h @0x%h - (idma - model - addr) - match: %b", data, model_byte, addr_i + now, local_match);
            if (!local_match)
                $display("[tb  ] mismatch:   %h - %h @0x%h - (idma - model - addr) - match: %b", data, model_byte, addr_i + now, local_match);
            if (local_x)
                $display("[tb  ] idma has x: %h (%b) - %h @0x%h - (idma - model - addr) - match: %b", data, data, model_byte, addr_i + now, local_match);
            now++;
        end
    endtask

    // acknowledge a transfer, handle the errors (in order)
    task automatic ack_tf_handle_err (
        ref tb_dma_job_t now_r
    );
        // internal signals
        logic                error;
        logic                last;
        idma_pkg::err_type_t err_type;
        axi_pkg::resp_t      cause;
        addr_t               burst_addr;
        int                  err_idx [$];
        // multiple errors can happen -> once one occurs
        // handle it after checking the list
        while (1) begin
            drv.wait_tf(cause, err_type, burst_addr, error, last);
            // if bus error occurs
            if (error & (err_type == idma_pkg::BUS_READ | err_type == idma_pkg::BUS_WRITE) & ErrorCap == idma_pkg::ERROR_HANDLING) begin
                err_idx = now_r.err_addr.find_first_index with (item == burst_addr);
                // handle it
                drv.handle_error(now_r.err_action[err_idx[0]]);
            // if transfer length zero happens:
            end else if (error & err_type == idma_pkg::BACKEND) begin
                break;
            end else begin
                break;
            end
        end
    endtask

    // initialize a memory region with random data in both memories
    task automatic init_mem (
        idma_pkg::protocol_e used_protocols[],
        ref tb_dma_job_t now_r
    );
        addr_t now;
        byte_t to_write;
        now = 0;
        while (now < now_r.length) begin
            // to_write = $urandom();
            to_write = now_r.src_addr + now;
            foreach (used_protocols[i]) begin
                case(used_protocols[i])
                idma_pkg::AXI: begin
                    model.write_byte   ( to_write, now_r.src_addr + now, idma_pkg::AXI);
                    write_byte_axi_mem ( to_write, now_r.src_addr + now);
                end
                idma_pkg::AXI_LITE: begin
                    model.write_byte            ( -to_write, now_r.src_addr + now, idma_pkg::AXI_LITE);
                    write_byte_axi_lite_axi_mem ( -to_write, now_r.src_addr + now);
                end
                idma_pkg::OBI: begin
                    model.write_byte       ( ~to_write, now_r.src_addr + now, idma_pkg::OBI);
                    write_byte_obi_axi_mem ( ~to_write, now_r.src_addr + now);
                end
                idma_pkg::TILELINK: begin
                    model.write_byte            ( {to_write[3:0], to_write[7:4]}, now_r.src_addr + now, idma_pkg::TILELINK );
                    write_byte_tilelink_axi_mem ( {to_write[3:0], to_write[7:4]}, now_r.src_addr + now );
                end
                idma_pkg::INIT: begin
                    model.write_byte ( 8'h42, now_r.src_addr + now, idma_pkg::INIT );
                end
                idma_pkg::AXI_STREAM: begin
                    model.write_byte              ( ~{to_write[3:0], to_write[7:4]}, now_r.src_addr + now, idma_pkg::AXI_STREAM );
                    write_byte_axis_axi_mem ( ~{to_write[3:0], to_write[7:4]}, now_r.src_addr + now );
                end
                default: $fatal(1, "init_mem not implemented for used protocol!");
                endcase
            end
            now++;
        end
        // write errors
        for (int i = 0; i < now_r.err_addr.size(); i++) begin
            set_error_mem(
                          now_r.err_addr[i],
                          now_r.err_is_read[i],
                          axi_pkg::RESP_SLVERR
                         );
        end
    endtask

    // read jobs from the job file
    task automatic read_jobs (
        input string       filename,
        ref   tb_dma_job_t jobs [$]
    );
        // Running counter
        int unsigned id;

        // job file
        integer job_file;

        // parsed fields
        int unsigned            num_errors;
        string                  is_read, error_handling;
        addr_t                  err_addr;
        tb_dma_job_t            now;
        idma_pkg::idma_eh_req_t eh;

        id = 0;

        // open file
        job_file = $fopen(filename, "r");

        // check if file exist
        if (job_file == 0)
            $fatal(1, "File not found!");

        // until not end of file
        while (! $feof(job_file)) begin
            now = new();
            void'($fscanf(job_file, "%d\n", now.length));
            void'($fscanf(job_file, "0x%x\n", now.src_addr));
            void'($fscanf(job_file, "0x%x\n", now.dst_addr));
            void'($fscanf(job_file, "%d\n", now.src_protocol));
            void'($fscanf(job_file, "%d\n", now.dst_protocol));
            void'($fscanf(job_file, "%d\n", now.max_src_len));
            void'($fscanf(job_file, "%d\n", now.max_dst_len));
            void'($fscanf(job_file, "%b\n", now.aw_decoupled));
            void'($fscanf(job_file, "%b\n", now.rw_decoupled));
            if (now.IsND) begin
                for (int d = 0; d < now.NumDim-1; d++) begin
                    void'($fscanf(job_file, "%d\n", now.n_dims[d].reps));
                    void'($fscanf(job_file, "0x%x\n", now.n_dims[d].src_strides));
                    void'($fscanf(job_file, "0x%x\n", now.n_dims[d].dst_strides));
                end
            end
            now.id = id++;
            void'($fscanf(job_file, "%d\n", num_errors));
            for (int i = 0; i < num_errors; i++) begin
                void'($fscanf(job_file, "%c%c0x%h\n", is_read, error_handling, err_addr));
                // parse error handling option
                eh = '0;
                case (error_handling)
                    "c" : eh = idma_pkg::CONTINUE;
                    "a" : eh = idma_pkg::ABORT;
                    default:;
                endcase
                now.err_action.push_back(eh);

                // parse read flag
                if (is_read == "r") begin
                    now.err_is_read.push_back(1);
                end else begin
                    now.err_is_read.push_back(0);
                end

                // error address
                now.err_addr.push_back(err_addr);
            end
            jobs.push_back(now);
        end

        // close job file
        $fclose(job_file);

    endtask

    // print a job summary (# jobs and total length)
    task automatic print_summary (
        ref   tb_dma_job_t jobs [$]
    );
        int unsigned data_size;
        int unsigned num_transfers;
        data_size     = '0;
        num_transfers = jobs.size();
        // go through queue
        for (int i = 0; i < num_transfers; i++) begin
            data_size = data_size + jobs[i].length;
        end
        $display("Launching %d jobs copying a total of %d B (%d kiB - %d MiB)",
                 num_transfers,
                 data_size,
                 data_size / 1024,
                 data_size / 1024 / 1024
                );
    endtask
