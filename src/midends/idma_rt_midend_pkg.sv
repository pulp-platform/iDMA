`include "idma/typedef.svh"

package idma_rt_midend_pkg;

    localparam int unsigned NumDim    = 3;

    typedef logic [5:0]  axi_id_t;
    typedef logic [31:0] tf_len_t;
    typedef logic [31:0] axi_addr_t;
    typedef logic [31:0] reps_t;
    typedef logic [31:0] strides_t;

    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, axi_id_t, axi_addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, axi_addr_t)
    `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, strides_t)

endpackage
