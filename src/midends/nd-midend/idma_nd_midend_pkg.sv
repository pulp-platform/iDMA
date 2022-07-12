package idma_nd_midend_pkg;

    localparam NumDims = 3;

    typedef struct packed {
        int unsigned SrcStrideWidth;
        int unsigned DstStrideWidth;
        int unsigned RepWidth;
    } d_cfg_t;

    typedef d_cfg_t [NumDims-2:0] nd_cfg_t;

    localparam nd_cfg_t nd_cfg = '{
        '{SrcStrideWidth: 'd16, DstStrideWidth: 'd16, RepWidth: 'd16}, // Dim 3
        '{SrcStrideWidth: 'd32, DstStrideWidth: 'd32, RepWidth: 'd32}  // Dim 2
    };

    localparam MaxRepWidth    = 32;
    localparam MaxStrideWidth = 32;
    localparam AddrWidth      = 32;

    typedef logic [MaxRepWidth-1:0]    reps_t;
    typedef logic [MaxStrideWidth-1:0] strides_t;
    typedef logic [AddrWidth-1:0]      addr_t;

    typedef struct packed {
        reps_t    reps;
        strides_t src_strides;
        strides_t dst_strides;
    } d_req_t;

    typedef struct packed {
        addr_t src;
        addr_t dst;
    } burst_req_t;

    typedef struct packed {
        burst_req_t           burst_req;
        d_req_t [NumDims-2:0] d_req;
    } nd_req_t;

endpackage
