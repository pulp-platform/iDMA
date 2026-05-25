// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Michael Rogenmoser <michaero@iis.ee.ethz.ch>
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

{
  name: "idma_${identifier}",
  clock_primary: "clk_i",
  reset_primary: "rst_ni",
  bus_interfaces: [
    { protocol: "reg_iface",
      direction: "device"
    }
  ],
  regwidth: "32",
  param_list: [
${params}
  ],
  registers: [
    { name: "conf",
      desc: "Configuration Register for DMA settings",
      swaccess: "rw",
      hwaccess: "hro",
      fields: [
        { bits: "0",
          name: "decouple_aw",
          desc: "Decouple R-AW"
        },
        { bits: "1",
          name: "decouple_rw",
          desc: "Decouple R-W"
        },
        { bits: "2",
          name: "src_reduce_len",
          desc: "Reduce maximal source burst length"
        },
        { bits: "3",
          name: "dst_reduce_len",
          desc: "Reduce maximal destination burst length"
        }
        { bits: "6:4",
          name: "src_max_llen",
          desc: "Maximal logarithmic source burst length"
        }
        { bits: "9:7",
          name: "dst_max_llen",
          desc: "Maximal logarithmic destination burst length"
        }
        { bits: "${dim_range}",
          name: "enable_nd",
          desc: "ND-extension enabled"
        }
        { bits: "${src_prot_range}",
          name: "src_protocol",
          desc: "Selection of the source protocol"
        }
        { bits: "${dst_prot_range}",
          name: "dst_protocol",
          desc: "Selection of the destination protocol"
        }
      ]
    },
    { multireg:
      { name: "status",
        desc: "DMA Status",
        swaccess: "ro",
        hwaccess: "hwo",
        count: "16",
        cname: "status",
        hwext: "true",
        compact: "false",
        fields: [
          { bits: "9:0",
            name: "busy",
            desc: "DMA busy"
          }
        ]
      }
    },
    { multireg:
      { name: "next_id",
        desc: "Next ID, launches transfer, returns 0 if transfer not set up properly.",
        swaccess: "ro",
        hwaccess: "hrw",
        hwre: "true",
        count: "16",
        cname: "next_id",
        hwext: "true",
        compact: "false",
        fields: [
          { bits: "31:0",
            name: "next_id",
            desc: "Next ID, launches transfer, returns 0 if transfer not set up properly."
          }
        ]
      }
    },
    { multireg:
      { name: "done_id",
        desc: "Get ID of finished transactions.",
        swaccess: "ro",
        hwaccess: "hwo",
        count: "16",
        cname: "done_id",
        hwext: "true",
        compact: "false",
        fields: [
          { bits: "31:0",
            name: "done_id",
            desc: "Get ID of finished transactions."
          }
        ]
      }
    },
${registers}
  ]
}
