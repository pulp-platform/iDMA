// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Tobias Senti <tsenti@student.ethz.ch>

/// Responds to read requests from DMA
class idma_source #(
    parameter int     AddrWidth = 32,
    parameter int       IdWidth = 4,
    parameter int     DataWidth = 32,
    parameter int       Latency = 0,    // Read latency in cycles
    parameter time          TCK = 10ns,
    parameter int   NumInFlight = 3,    // Number of request that can be handled
    parameter bit RandomLatency = 1'b0, // Enables random latency up to Latency cycles
    parameter type tb_dma_job_t = logic
);
    localparam int StrbWidth = DataWidth / 8;

    // Driver handles protocol specific logic
    idma_proto_test::idma_protocol_driver #(
        .AddrWidth ( AddrWidth ),
        .IdWidth   ( IdWidth   ),
        .DataWidth ( DataWidth )
    ) driver;

    // Struct holding receive request
    typedef struct packed {
        logic [AddrWidth-1:0] addr;
        logic [  IdWidth-1:0] id;
        int length;
        time wait_until_time;
    } receive_request_t;

    // Queue holding received requests
    mailbox queue = new(NumInFlight);

    // Queue holding jobs
    tb_dma_job_t req_jobs [$];

    // Constructor
    function new(
        idma_proto_test::idma_protocol_driver #(
            .AddrWidth ( AddrWidth ),
            .IdWidth   ( IdWidth   ),
            .DataWidth ( DataWidth )
        ) driver
    );
        this.driver = driver;
    endfunction

    // Fill job queue
    function void set_jobs(tb_dma_job_t req_jobs [$]);
        this.req_jobs = req_jobs;
    endfunction

    // Generate data to send back
    function logic[DataWidth-1:0] gen_data(receive_request_t req, int i);
      logic[DataWidth-1:0] result;
      result = '0;
      for(int j = 0; j < StrbWidth; j++)
        result[j * 8 +: 8] = req.addr + i * StrbWidth + j;
   
      gen_data = result;
    endfunction

    // Receive and check read request
    task receive_read();
        receive_request_t req;

        forever begin
            // Get new request
            this.driver.receive_read(
                .addr   ( req.addr   ),
                .id     ( req.id     ),
                .length ( req.length )
            );
            $display("idma_source request: New request @%X with ID %X for %d words", req.addr, req.id, req.length);
            
            // Add to queue
            queue.put(req);
        end

        /*
        TODO: This has to handle reading the starting bytes multiple times -> sometimes when missaligned
        IDEA: Use another queue, check requests with another task
        tb_dma_job_t job;
        logic [AddrWidth-1:0] start_addr;
        logic [AddrWidth-1:0] stop_addr;
        logic [AddrWidth-1:0] current_addr;
        while(req_jobs.size() > 0) begin
            // Get new job
            job = req_jobs.pop_front();
            // Bus aligned start address
            start_addr = job.src_addr;
            start_addr = start_addr - start_addr % StrbWidth;
            // End address
            // If not aligned, align by rounding up
            stop_addr  = job.src_addr + job.length;
            if(stop_addr % StrbWidth != 0)
              stop_addr = stop_addr - stop_addr % StrbWidth + StrbWidth;
            // Current bus aligned address
            current_addr = start_addr;
            
            $display("idma_source request: Got new job: @%X to @%X, %d bytes", start_addr, stop_addr, job.length);

            // Handle requests within the job
            while(current_addr < stop_addr) begin
                // Get new request
                this.driver.receive_read(
                    .addr   ( req.addr   ),
                    .id     ( req.id     ),
                    .length ( req.length )
                );

                // Check request
                $display("idma_source request: New request @%X with ID %X for %d words", req.addr, req.id, req.length);

                // Check if request address is current address, the starting byte might get read twice
                if(req.addr != start_addr && req.addr != current_addr) begin
                    $error("idma_source request: Requested source address %X is not %X", req.addr, current_addr);
                    $stop;
                end
                // Check if end of request is lower or equal to stop_addr
                if(!((req.addr + req.length * StrbWidth) <= stop_addr)) begin
                    $error("idma_source request: Requested source address+length %X+%X is not lower or equal to %X", req.addr, req.length * StrbWidth, stop_addr);
                    $stop;
                end

                // Move checked address up to this requests end
                current_addr = req.addr + req.length * StrbWidth;

                // Set latency
                if(Latency == 0)
                    req.wait_until_time = 0;
                else begin
                    if (RandomLatency)
                        req.wait_until_time = $urandom_range(0, Latency);
                    else
                        req.wait_until_time = Latency;
                    req.wait_until_time = $time() + TCK * req.wait_until_time;
                end

                // Add request to queue
                queue.put(req);
            end
        end
        */
        $display("idma_source request: Finished all request!");
    endtask

    // Send back read request data
    task send_data();
        receive_request_t req;
        logic[DataWidth-1:0] data;

        forever begin
            // Get next request
            queue.get(req);
            // Wait until latency cycles have passed
            while(req.wait_until_time > $time())
              this.driver.wait_posedge();

            // Handle burst of data
            for (int i = 0; i < req.length-1; i++) begin
                // Send data
                data = gen_data(req, i);
                $display("idma_source response: Sending response %d of read @%X: %X", i, req.addr, data);
                this.driver.send_data(
                  .data ( data   ), 
                  .id   ( req.id ),
                  .last ( 1'b0   )
                );
            end
            // Send last data in burst
            data = gen_data(req, req.length-1);
            $display("idma_source response: Sending last response of read @%X: %X", req.addr, data);
            this.driver.send_data(
              .data ( data   ), 
              .id   ( req.id ),
              .last ( 1'b1   )
            );
        end
    endtask

    // Start handling requests
    task run();
        $display("idma_source: Starting idma source!");
        fork
            receive_read();
            send_data();  
        join_none
    endtask
endclass : idma_source
