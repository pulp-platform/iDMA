// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Michael Rogenmoser <michaero@iis.ee.ethz.ch>
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

<%
    # Config-bus CPUIF family, derived from --cpuif (idma.mk IDMA_REG_CPUIF). The wrapper packs
    # the PeakRDL reg_top's flat CPUIF signals into the matching req/rsp struct; the reg_top is
    # generated with the same --cpuif so its port set matches the branch selected here.
    if cpuif.startswith('apb'):
        _fam = 'apb'
    elif cpuif.startswith('obi'):
        _fam = 'obi'
    elif cpuif.startswith('axi4-lite'):
        _fam = 'axil'
    else:
        raise Exception("idma_reg.sv.tpl: unsupported register CPUIF '%s' (add a branch)" % cpuif)
%>\
% if _fam == 'apb':
`include "apb/typedef.svh"
% elif _fam == 'obi':
`include "obi/typedef.svh"
% elif _fam == 'axil':
`include "axi/typedef.svh"
% endif

/// Description: Register-based front-end for iDMA
module idma_${identifier} #(
  /// Number of configuration register ports
  parameter int unsigned NumRegs        = 32'd1,
  /// Number of streams (max 16)
  parameter int unsigned NumStreams     = 32'd1,
  /// Width of the transfer id (max 32-bit)
  parameter int unsigned IdCounterWidth = 32'd32,
  /// Dependent parameter: Stream Idx
  parameter int unsigned StreamWidth    = cc_pkg::idx_width(NumStreams),
  /// Backend data width; MX data planes, lengths and strides must fit its beats
  parameter int unsigned DataWidth      = 32'd512,
  /// Compute ops of the backend; a launch of any other op is refused
  parameter idma_pkg::compute_enable_t ComputeOps = '1,
  /// Number of launches buffered between the register ports and request output; zero bypasses it
  parameter int unsigned LaunchFifoDepth = NumRegs,
% if _fam == 'apb':
  /// APB4 request type
  parameter type         apb_req_t      = logic,
  /// APB4 response type
  parameter type         apb_rsp_t      = logic,
% elif _fam == 'obi':
  /// OBI request type
  parameter type         obi_req_t      = logic,
  /// OBI response type
  parameter type         obi_rsp_t      = logic,
% elif _fam == 'axil':
  /// AXI4-Lite request type
  parameter type         axi_lite_req_t = logic,
  /// AXI4-Lite response type
  parameter type         axi_lite_rsp_t = logic,
% endif
  /// DMA 1d or ND burst request type
  parameter type         dma_req_t      = logic,
  /// Dependent type for IdCounterWidth
  parameter type         cnt_width_t    = logic [IdCounterWidth-1:0],
  /// Dependent type for StreamWidth
  parameter type         stream_t       = logic [StreamWidth-1:0]
) (
  input  logic clk_i,
  input  logic rst_ni,
  /// Configuration control slave (${cpuif})
% if _fam == 'apb':
  input  apb_req_t [NumRegs-1:0] dma_ctrl_req_i,
  output apb_rsp_t [NumRegs-1:0] dma_ctrl_rsp_o,
% elif _fam == 'obi':
  input  obi_req_t [NumRegs-1:0] dma_ctrl_req_i,
  output obi_rsp_t [NumRegs-1:0] dma_ctrl_rsp_o,
% elif _fam == 'axil':
  input  axi_lite_req_t [NumRegs-1:0] dma_ctrl_req_i,
  output axi_lite_rsp_t [NumRegs-1:0] dma_ctrl_rsp_o,
% endif
  /// Request signals
  output dma_req_t   dma_req_o,
  output logic       req_valid_o,
  input  logic       req_ready_i,
  /// Current unallocated transfer ID
  input  cnt_width_t next_id_i,
  /// Transfer ID carried with dma_req_o
  output cnt_width_t req_id_o,
  /// Pulse indicating that next_id_i was allocated to a launch
  output logic       id_alloc_o,
  output stream_t    stream_idx_o,
  /// Status signals
  input  cnt_width_t           [NumStreams-1:0] done_id_i,
  input  idma_pkg::idma_busy_t [NumStreams-1:0] busy_i,
  input  logic                 [NumStreams-1:0] midend_busy_i
);

  /// Maximum number of streams is set to 16. It can be enlarged, but the register file
  /// needs to be adapted too.
  localparam int unsigned MaxNumStreams = 32'd16;
  localparam int unsigned RegAddrWidth  = idma_${identifier}_reg_pkg::IDMA_${identifier.upper()}_REG_TOP_MIN_ADDR_WIDTH;
  localparam int unsigned ScaleAlignWidth = $clog2(idma_pkg::MxScaleSlotBytes);
  localparam int unsigned BeatAlignWidth  = $clog2(DataWidth / 8);

  // register connections
  idma_${identifier}_reg_pkg::idma_reg__out_t dma_reg2hw [NumRegs-1:0];
  idma_${identifier}_reg_pkg::idma_reg__in_t  dma_hw2reg [NumRegs-1:0];

  // A next_id read atomically allocates an ID and queues the corresponding descriptor.  Keeping
  // all three values in one ordered FIFO ensures that IDs are issued in allocation order even
  // when several independent register ports launch transfers.
  typedef struct packed {
    dma_req_t req;
    stream_t  stream;
  } launch_candidate_t;

  typedef struct packed {
    dma_req_t   req;
    stream_t    stream;
    cnt_width_t id;
  } launch_entry_t;

  launch_candidate_t [NumRegs-1:0] launch_candidate;
  logic              [NumRegs-1:0] launch_valid;
  logic              [NumRegs-1:0] launch_grant;
  launch_candidate_t               selected_launch;
  launch_entry_t                   launch_fifo_in, launch_fifo_out;
  logic                            selected_launch_valid;
  logic                            launch_fifo_ready;

  // generate the registers
  for (genvar i = 0; i < NumRegs; i++) begin : gen_core_regs


% if _fam == 'obi':
    // override the reg_top ID width so s_obi_aid/s_obi_rid match the OBI bus id width
    idma_${identifier}_reg_top #(
      .ID_WIDTH ( $bits(dma_ctrl_req_i[i].a.aid) )
    ) i_idma_${identifier}_reg_top (
% else:
    idma_${identifier}_reg_top i_idma_${identifier}_reg_top (
% endif
      .clk    ( clk_i ),
      .arst_n ( rst_ni ),

% if _fam == 'apb':
      .s_apb_psel    ( dma_ctrl_req_i[i].psel                    ),
      .s_apb_penable ( dma_ctrl_req_i[i].penable                 ),
      .s_apb_pwrite  ( dma_ctrl_req_i[i].pwrite                  ),
      .s_apb_pprot   ( dma_ctrl_req_i[i].pprot                   ),
      .s_apb_paddr   ( dma_ctrl_req_i[i].paddr[RegAddrWidth-1:0] ),
      .s_apb_pwdata  ( dma_ctrl_req_i[i].pwdata                  ),
      .s_apb_pstrb   ( dma_ctrl_req_i[i].pstrb                   ),
      .s_apb_pready  ( dma_ctrl_rsp_o[i].pready                  ),
      .s_apb_prdata  ( dma_ctrl_rsp_o[i].prdata                  ),
      .s_apb_pslverr ( dma_ctrl_rsp_o[i].pslverr                 ),
% elif _fam == 'obi':
      .s_obi_req     ( dma_ctrl_req_i[i].req                     ),
      .s_obi_gnt     ( dma_ctrl_rsp_o[i].gnt                     ),
      .s_obi_addr    ( dma_ctrl_req_i[i].a.addr[RegAddrWidth-1:0] ),
      .s_obi_we      ( dma_ctrl_req_i[i].a.we                    ),
      .s_obi_be      ( dma_ctrl_req_i[i].a.be                    ),
      .s_obi_wdata   ( dma_ctrl_req_i[i].a.wdata                 ),
      .s_obi_aid     ( dma_ctrl_req_i[i].a.aid                   ),
      .s_obi_rvalid  ( dma_ctrl_rsp_o[i].rvalid                  ),
      .s_obi_rready  ( dma_ctrl_req_i[i].rready                  ),
      .s_obi_rdata   ( dma_ctrl_rsp_o[i].r.rdata                 ),
      .s_obi_err     ( dma_ctrl_rsp_o[i].r.err                   ),
      .s_obi_rid     ( dma_ctrl_rsp_o[i].r.rid                   ),
% elif _fam == 'axil':
      .s_axil_awvalid ( dma_ctrl_req_i[i].aw_valid                  ),
      .s_axil_awready ( dma_ctrl_rsp_o[i].aw_ready                  ),
      .s_axil_awaddr  ( dma_ctrl_req_i[i].aw.addr[RegAddrWidth-1:0] ),
      .s_axil_awprot  ( dma_ctrl_req_i[i].aw.prot                   ),
      .s_axil_wvalid  ( dma_ctrl_req_i[i].w_valid                   ),
      .s_axil_wready  ( dma_ctrl_rsp_o[i].w_ready                   ),
      .s_axil_wdata   ( dma_ctrl_req_i[i].w.data                    ),
      .s_axil_wstrb   ( dma_ctrl_req_i[i].w.strb                    ),
      .s_axil_bvalid  ( dma_ctrl_rsp_o[i].b_valid                   ),
      .s_axil_bready  ( dma_ctrl_req_i[i].b_ready                   ),
      .s_axil_bresp   ( dma_ctrl_rsp_o[i].b.resp                    ),
      .s_axil_arvalid ( dma_ctrl_req_i[i].ar_valid                  ),
      .s_axil_arready ( dma_ctrl_rsp_o[i].ar_ready                  ),
      .s_axil_araddr  ( dma_ctrl_req_i[i].ar.addr[RegAddrWidth-1:0] ),
      .s_axil_arprot  ( dma_ctrl_req_i[i].ar.prot                   ),
      .s_axil_rvalid  ( dma_ctrl_rsp_o[i].r_valid                   ),
      .s_axil_rready  ( dma_ctrl_req_i[i].r_ready                   ),
      .s_axil_rdata   ( dma_ctrl_rsp_o[i].r.data                    ),
      .s_axil_rresp   ( dma_ctrl_rsp_o[i].r.resp                    ),
% endif

      .hwif_out  ( dma_reg2hw       [i] ),
      .hwif_in   ( dma_hw2reg       [i] )
    );

    // A next_id rd_swacc strobe attempts a launch; arbitration decides its returned ID.
    logic     read_happens;
    stream_t  read_stream;
    dma_req_t nxt_dma_req;
    logic     launch_ok;

    always_comb begin : proc_launch
        read_happens = 1'b0;
        read_stream  = '0;
        for (int c = 0; c < NumStreams; c++) begin
            if (dma_reg2hw[i].next_id[c].next_id.rd_swacc) begin
                read_happens = launch_ok;
                read_stream  = c;
            end
        end
    end

    // a compute launch needs an elaborated op; MX also an elaborated format, beat-aligned planes
    // (scale: 64 B), whole blocks and a written length that fits the length field
    always_comb begin : proc_launch_ok
      launch_ok = 1'b1;
      if (nxt_dma_req${sep}opt.compute.enable &&
          (nxt_dma_req${sep}opt.compute.op != idma_pkg::COMPUTE_NONE) &&
          !idma_pkg::compute_op_supported(ComputeOps, nxt_dma_req${sep}opt.compute.op)) begin
        launch_ok = 1'b0;
      end
      if (nxt_dma_req${sep}opt.compute.enable &&
          idma_pkg::compute_op_is_mx(nxt_dma_req${sep}opt.compute.op)) begin
        if (!idma_pkg::mx_elem_legal(nxt_dma_req${sep}opt.compute.params.mx.elem_fmt) ||
            (nxt_dma_req${sep}scale_addr[ScaleAlignWidth-1:0] != '0) ||
            (nxt_dma_req${sep}src_addr[BeatAlignWidth-1:0] != '0) ||
            (nxt_dma_req${sep}dst_addr[BeatAlignWidth-1:0] != '0) ||
            ((nxt_dma_req${sep}length &
              (idma_pkg::compute_in_bytes(nxt_dma_req${sep}opt.compute.op) - 1)) != '0) ||
            !idma_pkg::compute_out_len_fits(nxt_dma_req${sep}opt.compute.op,
                                            64'(nxt_dma_req${sep}length),
                                            $bits(nxt_dma_req${sep}length))) begin
          launch_ok = 1'b0;
        end
% for nd in range(0, num_dim-1):
        if (nxt_dma_req.d_req[${nd}].reps > 'd1 &&
            ((nxt_dma_req.d_req[${nd}].scale_strides[ScaleAlignWidth-1:0] != '0) ||
             (nxt_dma_req.d_req[${nd}].src_strides[BeatAlignWidth-1:0] != '0) ||
             (nxt_dma_req.d_req[${nd}].dst_strides[BeatAlignWidth-1:0] != '0))) begin
          launch_ok = 1'b0;
        end
% endfor
      end
    end

    assign launch_valid[i]     = read_happens;
    assign launch_candidate[i] = '{req: nxt_dma_req, stream: read_stream};

    // Combinational descriptor snapshot presented to the centralized launch allocator.
    always_comb begin : proc_hw_req_conv
      // all fields are zero per default
      nxt_dma_req = '0;

      // address and length
% if bit_width == '32':
      nxt_dma_req${sep}length   = dma_reg2hw[i].length[0].length.value;
      nxt_dma_req${sep}src_addr = dma_reg2hw[i].src_addr[0].src_addr.value;
      nxt_dma_req${sep}dst_addr = dma_reg2hw[i].dst_addr[0].dst_addr.value;
      nxt_dma_req${sep}scale_addr = dma_reg2hw[i].scale_addr[0].scale_addr.value;
% else:
      nxt_dma_req${sep}length   = {dma_reg2hw[i].length[1].length.value,     dma_reg2hw[i].length[0].length.value};
      nxt_dma_req${sep}src_addr = {dma_reg2hw[i].src_addr[1].src_addr.value, dma_reg2hw[i].src_addr[0].src_addr.value};
      nxt_dma_req${sep}dst_addr = {dma_reg2hw[i].dst_addr[1].dst_addr.value, dma_reg2hw[i].dst_addr[0].dst_addr.value};
      nxt_dma_req${sep}scale_addr = {dma_reg2hw[i].scale_addr[1].scale_addr.value,
                                    dma_reg2hw[i].scale_addr[0].scale_addr.value};
% endif

      // Protocols
      nxt_dma_req${sep}opt.src_protocol = idma_pkg::protocol_e'(dma_reg2hw[i].conf.src_protocol.value);
      nxt_dma_req${sep}opt.dst_protocol = idma_pkg::protocol_e'(dma_reg2hw[i].conf.dst_protocol.value);

      // Current backend only supports incremental burst
      nxt_dma_req${sep}opt.src.burst = axi_pkg::BURST_INCR;
      nxt_dma_req${sep}opt.dst.burst = axi_pkg::BURST_INCR;
        // this frontend currently does not support cache variations
      nxt_dma_req${sep}opt.src.cache = axi_pkg::CACHE_MODIFIABLE;
      nxt_dma_req${sep}opt.dst.cache = axi_pkg::CACHE_MODIFIABLE;

      // Backend options
      nxt_dma_req${sep}opt.beo.decouple_aw    = dma_reg2hw[i].conf.decouple_aw.value;
      nxt_dma_req${sep}opt.beo.decouple_rw    = dma_reg2hw[i].conf.decouple_rw.value;
      nxt_dma_req${sep}opt.beo.src_max_llen   = dma_reg2hw[i].conf.src_max_llen.value;
      nxt_dma_req${sep}opt.beo.dst_max_llen   = dma_reg2hw[i].conf.dst_max_llen.value;
      nxt_dma_req${sep}opt.beo.src_reduce_len = dma_reg2hw[i].conf.src_reduce_len.value;
      nxt_dma_req${sep}opt.beo.dst_reduce_len = dma_reg2hw[i].conf.dst_reduce_len.value;
      nxt_dma_req${sep}opt.beo.deadlock_free  = dma_reg2hw[i].conf.deadlock_free.value;

      // Optional on-the-fly compute settings are part of the transfer descriptor and
      // are captured together with the address/stride fields when next_id is read.
      nxt_dma_req${sep}opt.compute.enable                    =
          dma_reg2hw[i].compute_cfg.compute_enable.value;
      nxt_dma_req${sep}opt.compute.op                        =
          idma_pkg::compute_op_e'(dma_reg2hw[i].compute_cfg.compute_op.value);
      nxt_dma_req${sep}opt.compute.params.transpose.mode     =
          dma_reg2hw[i].compute_cfg.transpose_mode.value;
      nxt_dma_req${sep}opt.compute.params.transpose.tensor_m =
          dma_reg2hw[i].compute_cfg.transpose_tensor_m.value;
      nxt_dma_req${sep}opt.compute.params.transpose.tensor_n =
          dma_reg2hw[i].compute_cfg.transpose_tensor_n.value;
      // Compact mode removes tile padding from destination rows.
      nxt_dma_req${sep}opt.compute.params.transpose.compact  =
          dma_reg2hw[i].compute_cfg.transpose_compact.value;
      if (idma_pkg::compute_op_is_mx(nxt_dma_req${sep}opt.compute.op)) begin
        nxt_dma_req${sep}opt.compute.params                = '0;
        nxt_dma_req${sep}opt.compute.params.mx.poison_dis  =
            dma_reg2hw[i].mx_cfg.mx_poison_dis.value;
        nxt_dma_req${sep}opt.compute.params.mx.rceil       =
            dma_reg2hw[i].mx_cfg.mx_rceil.value;
        nxt_dma_req${sep}opt.compute.params.mx.elem_fmt    =
            idma_pkg::mx_elem_e'(dma_reg2hw[i].mx_cfg.mx_elem_fmt.value);
        nxt_dma_req${sep}opt.compute.params.mx.group       =
            dma_reg2hw[i].mx_cfg.mx_group.value;
      end

% if num_dim != 1:
      // ND connections
% for nd in range(0, num_dim-1):
% if bit_width == '32':
      nxt_dma_req.d_req[${nd}].reps = dma_reg2hw[i].dim[${nd}].reps[0].reps.value;
      nxt_dma_req.d_req[${nd}].src_strides = dma_reg2hw[i].dim[${nd}].src_stride[0].src_stride.value;
      nxt_dma_req.d_req[${nd}].dst_strides = dma_reg2hw[i].dim[${nd}].dst_stride[0].dst_stride.value;
      nxt_dma_req.d_req[${nd}].scale_strides =
          dma_reg2hw[i].mx_dim[${nd}].scale_stride[0].scale_stride.value;
% else:
      nxt_dma_req.d_req[${nd}].reps = {dma_reg2hw[i].dim[${nd}].reps[1].reps.value,
                                      dma_reg2hw[i].dim[${nd}].reps[0].reps.value };
      nxt_dma_req.d_req[${nd}].src_strides = {dma_reg2hw[i].dim[${nd}].src_stride[1].src_stride.value,
                                             dma_reg2hw[i].dim[${nd}].src_stride[0].src_stride.value};
      nxt_dma_req.d_req[${nd}].dst_strides = {dma_reg2hw[i].dim[${nd}].dst_stride[1].dst_stride.value,
                                             dma_reg2hw[i].dim[${nd}].dst_stride[0].dst_stride.value};
      nxt_dma_req.d_req[${nd}].scale_strides =
          {dma_reg2hw[i].mx_dim[${nd}].scale_stride[1].scale_stride.value,
           dma_reg2hw[i].mx_dim[${nd}].scale_stride[0].scale_stride.value};
% endif
% endfor

      // Disable higher dimensions
      if ( dma_reg2hw[i].conf.enable_nd.value == 0) begin
% for nd in range(0, num_dim-1):
        nxt_dma_req.d_req[${nd}].reps = ${"'0" if nd != num_dim-2 else "'d1"};
% endfor
      end
% for nd in range(1, num_dim-1):
      else if ( dma_reg2hw[i].conf.enable_nd.value == ${nd}) begin
% for snd in range(nd, num_dim-1):
        nxt_dma_req.d_req[${snd}].reps = 'd1;
% endfor
      end
% endfor
% endif
    end

    // observational registers: drive .next (read-side launch is the rd_swacc strobe above)
    for (genvar c = 0; c < NumStreams; c++) begin : gen_hw2reg_connections
        assign dma_hw2reg[i].status[c].busy.next     = {midend_busy_i[c], busy_i[c]};
        // ID zero reports that this launch lost arbitration or that the launch FIFO was full.
        assign dma_hw2reg[i].next_id[c].next_id.next = launch_grant[i] ? next_id_i : '0;
        assign dma_hw2reg[i].done_id[c].done_id.next = done_id_i[c];
    end

    // tie-off unused channels
    for (genvar c = NumStreams; c < MaxNumStreams; c++) begin : gen_hw2reg_unused
        assign dma_hw2reg[i].status[c].busy.next     = '0;
        assign dma_hw2reg[i].next_id[c].next_id.next = '0;
        assign dma_hw2reg[i].done_id[c].done_id.next = '0;
    end

  end

  // the RDL MX fields and idma_pkg::mx_options_t must agree
  if ($bits(dma_reg2hw[0].mx_cfg.mx_elem_fmt.value) != $bits(idma_pkg::mx_elem_e))
  begin : gen_mx_cfg_check
    $fatal(1, "idma_${identifier}: mx_cfg fields do not match idma_pkg::mx_options_t");
  end

  // At most one register port allocates an ID per cycle.  Other simultaneous reads complete with
  // ID zero and may be retried, keeping the register interfaces non-blocking without requiring a
  // multi-write FIFO or duplicated ID-counter arithmetic.
  cc_rr_arb_tree #(
    .NumIn     ( NumRegs   ),
    .data_t    ( launch_candidate_t ),
    .ExtPrio   ( 0         ),
    // Launch strobes are one-cycle events rather than held valid/ready streams. A request that
    // cannot be granted immediately completes with ID zero, so the arbiter must not lock it in.
    .AxiVldRdy ( 0         ),
    .LockIn    ( 0         )
  ) i_rr_arb_tree (
    .clk_i,
    .rst_ni,
    .clr_i   ( 1'b0        ),
    .rr_i    ( '0          ),
    .req_i   ( launch_valid          ),
    .gnt_o   ( launch_grant          ),
    .data_i  ( launch_candidate      ),
    .gnt_i   ( launch_fifo_ready     ),
    .req_o   ( selected_launch_valid ),
    .data_o  ( selected_launch       ),
    .idx_o   ( /* unused */          )
  );

  always_comb begin : proc_launch_fifo_input
    launch_fifo_in        = '0;
    launch_fifo_in.req    = selected_launch.req;
    launch_fifo_in.stream = selected_launch.stream;
    launch_fifo_in.id     = next_id_i;
  end

  assign id_alloc_o = selected_launch_valid & launch_fifo_ready;

  if (LaunchFifoDepth == 0) begin : gen_launch_bypass
    // Without frontend buffering, a launch is allocated only if the downstream request interface
    // accepts it immediately. Otherwise its next_id read returns zero and software retries it.
    assign launch_fifo_ready = req_ready_i;
    assign launch_fifo_out   = launch_fifo_in;
    assign req_valid_o       = selected_launch_valid;
  end else begin : gen_launch_fifo
    cc_stream_fifo #(
      .FallThrough ( 1'b0            ),
      .Depth       ( LaunchFifoDepth ),
      .data_t      ( launch_entry_t  )
    ) i_launch_fifo (
      .clk_i,
      .rst_ni,
      .clr_i   ( 1'b0                  ),
      .flush_i ( 1'b0                  ),
      .usage_o ( /* unused */          ),
      .data_i  ( launch_fifo_in        ),
      .valid_i ( selected_launch_valid ),
      .ready_o ( launch_fifo_ready     ),
      .data_o  ( launch_fifo_out       ),
      .valid_o ( req_valid_o           ),
      .ready_i ( req_ready_i           )
    );
  end

  assign dma_req_o    = launch_fifo_out.req;
  assign stream_idx_o = launch_fifo_out.stream;
  assign req_id_o     = launch_fifo_out.id;

  `ASSERT(OneLaunchAllocated, $onehot0(launch_grant), clk_i, !rst_ni,
      "At most one register port may allocate a transfer ID per cycle")

endmodule
