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
      ]
    },
    { name: "smmu",
      desc: "Configuration Register for the SMMU",
      swaccess: "rw",
      hwaccess: "hro",
      fields: [
        { bits: "0",
          name: "f_exe",
          desc: "All PTE required to have set the executable flag"
        },
        { bits: "1",
          name: "f_user",
          desc: "All PTE required to have set the user flag"
        },
        { bits: "2",
          name: "f_bare",
          desc: "The virtual adress is a bare adress and can be translated directly"
        },
        { bits: "3",
          name: "f_update_tlb",
          desc: "Should this request result in a TLB update or not? (Only if the policy allows it)"
        }
      ]
    },
    { name: "smmu_root_pt_h",
      desc: "High Word of the root of the page table",
      swaccess: "rw",
      hwaccess: "hro",
      fields: [
        { bits: "31:0",
          name: "root_pt_h",
          desc: "High 32 bit of the root adress of the page table"
        }
      ]
    },
    { name: "smmu_root_pt_l",
      desc: "Low Word of the root of the page table (needs to be page aligned)",
      swaccess: "rw",
      hwaccess: "hro",
      fields: [
        { bits: "31:0",
          name: "root_pt_l",
          desc: "Low 32 bit of the root adress of the page table (page aligned)"
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
