// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// AXI protocol and MX plane monitor for the AXI ports of a backend: bursts, beats, strobes, planes.

module idma_mx_axi_mon #(
  parameter int unsigned StrbWidth  = 32'd8,
  parameter int unsigned AddrWidth  = 32'd32,
  parameter int unsigned LenWidth   = 32'd32
) (
  input logic                         clk_i,
  input logic                         rst_ni,
  input logic                         req_valid_i,
  input logic                         req_ready_i,
  input logic [LenWidth-1:0]          req_len_i,
  input logic [AddrWidth-1:0]         req_src_i,
  input logic [AddrWidth-1:0]         req_dst_i,
  input logic [AddrWidth-1:0]         req_scale_i,
  input logic [1:0]                   req_src_burst_i,
  input logic [1:0]                   req_dst_burst_i,
  input logic                         req_decouple_rw_i,
  input idma_pkg::compute_options_t   req_cmp_i,
  input logic                         ar_valid_i,
  input logic                         ar_ready_i,
  input logic [AddrWidth-1:0]         ar_addr_i,
  input logic [7:0]                   ar_len_i,
  input logic [2:0]                   ar_size_i,
  input logic [1:0]                   ar_burst_i,
  input logic                         r_valid_i,
  input logic                         r_ready_i,
  input logic                         r_last_i,
  input logic                         aw_valid_i,
  input logic                         aw_ready_i,
  input logic [AddrWidth-1:0]         aw_addr_i,
  input logic [7:0]                   aw_len_i,
  input logic [2:0]                   aw_size_i,
  input logic [1:0]                   aw_burst_i,
  input logic                         w_valid_i,
  input logic                         w_ready_i,
  input logic [StrbWidth-1:0][7:0]    w_data_i,
  input logic [StrbWidth-1:0]         w_strb_i,
  input logic                         w_last_i,
  input logic                         b_valid_i,
  input logic                         b_ready_i
);

  // pragma translate_off
  localparam int unsigned LgS = $clog2(StrbWidth);
  localparam longint      S   = longint'(StrbWidth);
  // legalizer burst limit: a 4 KiB page or 256 beats
  localparam longint      PS  = (256 * S < 4096) ? 256 * S : 4096;

  typedef logic [StrbWidth-1:0] strb_t;
  typedef struct { longint lo, hi; } seg_t;
  typedef struct { longint addr, lo, hi; int len, k; int x; } bur_t;
  typedef struct { strb_t strb; bit last; } wb_t;

  class xfer_c;
    int   idx;
    bit   coupled;
    logic [1:0] burst [2];
    seg_t seg [2][$];
    int   si [2];
    longint na [2], base [2];
  endclass

  xfer_c  xq [2][$];
  bur_t   wq [$];
  wb_t    wpend [$];
  int     rq [$];
  int     nx, bcred, nerr, nbur [2], nbeat [2];
  bit     planes = 1'b1;

  function automatic longint dn(longint a); return a >> LgS << LgS; endfunction
  function automatic longint up(longint a); return (a + S - 1) >> LgS << LgS; endfunction

  function automatic void err(string m);
    nerr++;
    $error("[AXIMON] %s", m);
  endfunction

  // the planes a request reads and writes, in the order the legalizer emits them
  function automatic void plan(xfer_c x, longint len, longint src, longint dst, longint scl,
                              idma_pkg::compute_options_t c);
    longint g, nb, sb, drem, sg;
    idma_pkg::mx_options_t mx = c.params.mx;
    g  = (mx.group == idma_pkg::MX_GROUP_G32) ? 32 : 64;
    sb = scl;
    unique case (c.enable ? c.op : idma_pkg::COMPUTE_NONE)
      idma_pkg::COMPUTE_NONE: begin
        x.seg[0].push_back('{src, src + len});
        x.seg[1].push_back('{dst, dst + len});
      end
      idma_pkg::COMPUTE_MXQUANT, idma_pkg::COMPUTE_MXQUANT_FP16: begin
        nb = len / ((c.op == idma_pkg::COMPUTE_MXQUANT) ? 128 : 64);
        x.seg[0].push_back('{src, src + len});
        for (longint b = 0; b < nb; b += g) begin
          longint n = (nb - b < g) ? nb - b : g;
          x.seg[1].push_back('{dst + b * 32, dst + (b + n) * 32});
          x.seg[1].push_back('{sb + b, sb + b + n});
        end
      end
      idma_pkg::COMPUTE_MXDEQUANT, idma_pkg::COMPUTE_MXDEQUANT_FP16: begin
        nb   = len / 32;
        drem = up(len);
        for (longint b = 0; drem > 0; b += g) begin
          longint n = (nb - b < g) ? nb - b : g;
          sg = (drem > g * 32) ? g * 32 : drem;
          x.seg[0].push_back('{dn(sb + b), up(sb + b + n)});
          x.seg[0].push_back('{src + b * 32, src + b * 32 + sg});
          drem -= sg;
        end
        x.seg[1].push_back('{dst, dst + nb * ((c.op == idma_pkg::COMPUTE_MXDEQUANT) ? 128 : 64)});
      end
      default: begin
        if (planes) $display("[AXIMON] compute op %0d: plane checks off from here", c.op);
        planes = 1'b0;
      end
    endcase
  endfunction

  // AXI rules of an AR/AW; it carries the next bytes of its segment up to the burst limit
  function automatic void burst(int s, longint a, int len, int size, logic [1:0] bt);
    xfer_c  x;
    longint e = dn(a) + (longint'(len) + 1) * S, n, na;
    string  ch = s ? "AW" : "AR";
    nbur[s]++;
    if (size > LgS) err($sformatf("%s size %0d wider than the bus", ch, size));
    if (bt == axi_pkg::BURST_INCR && ((a >> 12) != ((e - 1) >> 12)))
      err($sformatf("%s %0h len %0d crosses a 4 KiB page", ch, a, len));
    if (bt == 2'b11) err($sformatf("%s reserved burst type", ch));
    if (bt == axi_pkg::BURST_WRAP && !(len inside {1, 3, 7, 15}))
      err($sformatf("%s WRAP with len %0d", ch, len));
    if (bt == axi_pkg::BURST_FIXED && len > 15) err($sformatf("%s FIXED with len %0d", ch, len));
    if (s) wq.push_back('{addr: a, lo: a, hi: e, len: len, k: 0, x: -1});
    if (!planes) return;
    if (xq[s].size() == 0) begin
      err($sformatf("%s %0h len %0d without an open transfer", ch, a, len));
      return;
    end
    x  = xq[s][0];
    na = x.na[s];
    n  = x.seg[s][x.si[s]].hi - na;
    if (PS - (na % PS) < n) n = PS - (na % PS);
    if (x.coupled) begin
      automatic longint o = na - x.base[s], q = x.base[!s] + o;
      if (PS - (q % PS) < n) n = PS - (q % PS);
    end
    if (bt != x.burst[s]) err($sformatf("%s burst type %0d, request %0d", ch, bt, x.burst[s]));
    if (dn(a) != dn(na) || a > na || len != int'(((na + n - 1) >> LgS) - (na >> LgS)))
      err($sformatf("x%0d %s %0h len %0d: expected %0h len %0d (segment %0d [%0h, %0h))", x.idx, ch,
                    a, len, na, int'(((na + n - 1) >> LgS) - (na >> LgS)), x.si[s],
                    x.seg[s][x.si[s]].lo, x.seg[s][x.si[s]].hi));
    if (s) begin
      automatic bur_t b = wq.pop_back();
      b.lo = na; b.hi = na + n; b.x = x.idx;
      wq.push_back(b);
    end
    x.na[s] = na + n;
    if (x.na[s] >= x.seg[s][x.si[s]].hi) begin
      x.si[s]++;
      if (x.si[s] < x.seg[s].size()) x.na[s] = x.seg[s][x.si[s]].lo;
      else void'(xq[s].pop_front());
    end
  endfunction

  // one W beat against the head AW burst: strobes inside the addressed bytes and the plane, WLAST
  function automatic void wbeat(wb_t w);
    longint ba = dn(wq[0].addr) + longint'(wq[0].k) * S;
    strb_t  ax = '1, ex = '0;
    if (wq[0].k == 0) ax = strb_t'('1) << (wq[0].addr - dn(wq[0].addr));
    for (int i = 0; i < StrbWidth; i++) ex[i] = (ba + i >= wq[0].lo) && (ba + i < wq[0].hi);
    if ((w.strb & ~ax) != '0)
      err($sformatf("W beat %0d of AW %0h: strobe %0h outside the addressed bytes %0h", wq[0].k,
                    wq[0].addr, w.strb, ax));
    if (planes && wq[0].x >= 0 && w.strb != ex)
      err($sformatf("x%0d W beat %0d of AW %0h: strobe %0h, plane bytes %0h", wq[0].x, wq[0].k,
                    wq[0].addr, w.strb, ex));
    if (w.last != (wq[0].k == wq[0].len))
      err($sformatf("W beat %0d of AW %0h len %0d: WLAST %0d", wq[0].k, wq[0].addr, wq[0].len,
                    w.last));
    nbeat[1]++;
    if (w.last || wq[0].k == wq[0].len) begin
      void'(wq.pop_front());
      bcred++;
    end else wq[0].k++;
  endfunction

  typedef struct packed {
    logic [AddrWidth-1:0] addr;
    logic [7:0]           len;
    logic [2:0]           size;
    logic [1:0]           burst;
  } ax_t;

  clocking cb @(posedge clk_i);
    default input #1step;
    input rst_ni, req_valid_i, req_ready_i, req_len_i, req_src_i, req_dst_i, req_scale_i,
          req_src_burst_i, req_dst_burst_i, req_decouple_rw_i, req_cmp_i, ar_valid_i,
          ar_ready_i, ar_addr_i, ar_len_i, ar_size_i, ar_burst_i, r_valid_i, r_ready_i,
          r_last_i, aw_valid_i, aw_ready_i, aw_addr_i, aw_len_i, aw_size_i, aw_burst_i,
          w_valid_i, w_ready_i, w_data_i, w_strb_i, w_last_i, b_valid_i, b_ready_i;
  endclocking

  ax_t                       ar_q, aw_q;
  logic [StrbWidth-1:0][7:0] wd_q;
  logic [StrbWidth-1:0]      ws_q;
  logic                      wl_q, rl_q;
  bit                        hold_ar, hold_aw, hold_w, hold_r, hold_b;

  always @(cb) begin
    if (cb.rst_ni) begin
      automatic ax_t ar = '{cb.ar_addr_i, cb.ar_len_i, cb.ar_size_i, cb.ar_burst_i};
      automatic ax_t aw = '{cb.aw_addr_i, cb.aw_len_i, cb.aw_size_i, cb.aw_burst_i};
      // a valid stays up with a stable payload until its handshake
      if (hold_ar && !(cb.ar_valid_i && ar == ar_q)) err("AR dropped or changed before AR ready");
      if (hold_aw && !(cb.aw_valid_i && aw == aw_q)) err("AW dropped or changed before AW ready");
      if (hold_w && !(cb.w_valid_i && cb.w_data_i == wd_q && cb.w_strb_i == ws_q &&
                      cb.w_last_i == wl_q)) err("W dropped or changed before W ready");
      if (hold_r && !(cb.r_valid_i && cb.r_last_i == rl_q))
        err("R dropped or changed before R ready");
      if (hold_b && !cb.b_valid_i) err("B dropped before B ready");
      hold_ar = cb.ar_valid_i && !cb.ar_ready_i;
      hold_aw = cb.aw_valid_i && !cb.aw_ready_i;
      hold_w  = cb.w_valid_i && !cb.w_ready_i;
      hold_r  = cb.r_valid_i && !cb.r_ready_i;
      hold_b  = cb.b_valid_i && !cb.b_ready_i;
      ar_q = ar; aw_q = aw; rl_q = cb.r_last_i;
      wd_q = cb.w_data_i; ws_q = cb.w_strb_i; wl_q = cb.w_last_i;

      if (cb.req_valid_i && cb.req_ready_i && cb.req_len_i != '0) begin
        automatic xfer_c x = new();
        automatic idma_pkg::compute_options_t c = cb.req_cmp_i;
        x.idx      = nx++;
        x.coupled  = !cb.req_decouple_rw_i && !c.enable;
        x.burst[0] = cb.req_src_burst_i;
        x.burst[1] = cb.req_dst_burst_i;
        plan(x, longint'(cb.req_len_i), longint'(cb.req_src_i), longint'(cb.req_dst_i),
             longint'(cb.req_scale_i), c);
        x.base[0] = longint'(cb.req_src_i);
        x.base[1] = longint'(cb.req_dst_i);
        for (int s = 0; s < 2; s++) begin
          x.na[s] = x.seg[s].size() ? x.seg[s][0].lo : 0;
          if (planes) xq[s].push_back(x);
        end
      end
      if (cb.ar_valid_i && cb.ar_ready_i) begin
        burst(0, longint'(ar.addr), int'(ar.len), int'(ar.size), ar.burst);
        rq.push_back(int'(ar.len));
      end
      if (cb.aw_valid_i && cb.aw_ready_i) begin
        burst(1, longint'(aw.addr), int'(aw.len), int'(aw.size), aw.burst);
        while (wpend.size() && wq.size()) wbeat(wpend.pop_front());
      end
      if (cb.w_valid_i && cb.w_ready_i) begin
        if (wq.size() == 0) begin
          err("W beat without an open AW burst");
          wpend.push_back('{strb: cb.w_strb_i, last: cb.w_last_i});
        end else wbeat('{strb: cb.w_strb_i, last: cb.w_last_i});
      end
      if (cb.r_valid_i && cb.r_ready_i) begin
        nbeat[0]++;
        if (rq.size() == 0) err("R beat without an outstanding AR");
        else begin
          if (cb.r_last_i != (rq[0] == 0))
            err($sformatf("RLAST %0d with %0d beats left", cb.r_last_i, rq[0]));
          if (rq[0] == 0) void'(rq.pop_front());
          else rq[0]--;
        end
      end
      if (cb.b_valid_i && cb.b_ready_i) begin
        if (bcred == 0) err("B without a completed write burst");
        else bcred--;
      end
    end
  end

  final begin
    if (planes && (xq[0].size() || xq[1].size()))
      err($sformatf("%0d/%0d transfers with planes not fully read/written", xq[0].size(),
                    xq[1].size()));
    if (wq.size() || wpend.size() || rq.size())
      err($sformatf("open at the end: %0d AW bursts, %0d W beats, %0d AR bursts", wq.size(),
                    wpend.size(), rq.size()));
    $display("[AXIMON] transfers=%0d AR=%0d AW=%0d R=%0d W=%0d planes=%0d violations=%0d", nx,
             nbur[0], nbur[1], nbeat[0], nbeat[1], planes, nerr);
  end
  // pragma translate_on

endmodule
