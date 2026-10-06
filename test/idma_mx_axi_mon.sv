// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// AXI protocol, MX plane and busy monitor of a backend: bursts, beats, strobes, planes, reduce_len
// lengths, AR/AW/R/B attributes against the request, busy flags while bytes are outstanding.

module idma_mx_axi_mon #(
  parameter int unsigned StrbWidth  = 32'd8,
  parameter int unsigned AddrWidth  = 32'd32,
  parameter int unsigned LenWidth   = 32'd32,
  parameter int unsigned IdWidth    = 32'd1,
  parameter int unsigned UserWidth  = 32'd1,
  parameter bit          EnableCompute = 1'b1,
  parameter idma_pkg::compute_enable_t ComputeOps = '1
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
  input idma_pkg::backend_options_t   req_beo_i,
  input logic [IdWidth-1:0]           req_id_i,
  input idma_pkg::axi_options_t       req_src_opt_i,
  input idma_pkg::axi_options_t       req_dst_opt_i,
  input logic [UserWidth-1:0]         req_user_i,
  input logic [IdWidth-1:0]           ar_id_i,
  input idma_pkg::axi_options_t       ar_opt_i,
  input logic [UserWidth-1:0]         ar_user_i,
  input logic [IdWidth-1:0]           r_id_i,
  input logic [IdWidth-1:0]           aw_id_i,
  input idma_pkg::axi_options_t       aw_opt_i,
  input logic [UserWidth-1:0]         aw_user_i,
  input logic [5:0]                   aw_atop_i,
  input logic [IdWidth-1:0]           b_id_i,
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
  input logic                         b_ready_i,
  input idma_pkg::idma_busy_t         busy_i
);

  // pragma translate_off
  // one bit above the address space: a plane may end at 2^AddrWidth
  typedef logic [64:0] u64_t;
  typedef logic [IdWidth-1:0] id_t;
  localparam int unsigned LgS = $clog2(StrbWidth);
  localparam u64_t        S   = u64_t'(StrbWidth);

  typedef logic [StrbWidth-1:0] strb_t;
  typedef struct packed { u64_t lo, hi; } seg_t;
  typedef struct packed { u64_t addr, lo, hi; int len, k; int x, seg; id_t id; } bur_t;
  typedef struct packed { strb_t strb; bit last; } wb_t;
  typedef struct packed { u64_t addr, lo, hi; int len, k; int x, seg; id_t id; } rb_t;
  typedef enum int { K_NONE, K_COPY, K_QUANT, K_DEQUANT } kind_e;

  class xfer_c;
    int   idx;
    bit   coupled;
    logic [1:0] burst [2];
    seg_t seg [2][$];
    int   si [2];
    u64_t na [2], base [2], ps [2];
    id_t  id;
    idma_pkg::axi_options_t opt [2];
    logic [UserWidth-1:0] user;
    // buffer accounting: FP element bytes, dequant element range, bytes owed to the write side
    kind_e   kind;
    int      eb;
    u64_t    elo, ehi;
    longint  owed, qin, qdat, qscl;
  endclass

  xfer_c  xq [2][$];
  xfer_c  xs [$];
  longint held;
  bit     need_buf, need_r, need_w;
  int     nbusy;
  int     ax_x, ax_seg;
  u64_t   ax_lo, ax_hi;
  bur_t   wq [$];
  wb_t    wpend [$];
  rb_t    rq [$];
  id_t    bq [$];
  int     nx, nerr, nbur [2], nbeat [2];
  bit     planes = 1'b1;

  // legalizer burst limit: a 4 KiB page, 256 beats or 2^max_llen beats under reduce_len
  function automatic u64_t page(logic reduce, logic [2:0] llen);
    u64_t p = S << (reduce ? llen : 8);
    return (p < 4096) ? p : 4096;
  endfunction

  function automatic u64_t dn(u64_t a); return a >> LgS << LgS; endfunction
  function automatic u64_t up(u64_t a); return (a + S - 1) >> LgS << LgS; endfunction

  function automatic void err(string m);
    nerr++;
    $error("[AXIMON] %s", m);
  endfunction

  // the planes a request reads and writes, in the order the legalizer emits them
  function automatic void plan(xfer_c x, u64_t len, u64_t src, u64_t dst, u64_t scl,
                              idma_pkg::compute_options_t c);
    u64_t g, nb, sb, drem, sg;
    idma_pkg::mx_options_t mx = c.params.mx;
    idma_pkg::compute_op_e op;
    g  = (mx.group == idma_pkg::MX_GROUP_G32) ? 32 : 64;
    sb = scl;
    op = (c.enable && EnableCompute && idma_pkg::compute_op_supported(ComputeOps, c.op)) ?
         c.op : idma_pkg::COMPUTE_NONE;
    x.kind = K_NONE;
    unique case (op)
      idma_pkg::COMPUTE_NONE: begin
        x.kind = K_COPY;
        x.seg[0].push_back(seg_t'{src, src + len});
        x.seg[1].push_back(seg_t'{dst, dst + len});
      end
      idma_pkg::COMPUTE_MXQUANT, idma_pkg::COMPUTE_MXQUANT_FP16: begin
        x.kind = K_QUANT;
        x.eb   = (c.op == idma_pkg::COMPUTE_MXQUANT) ? 4 : 2;
        nb = len / ((c.op == idma_pkg::COMPUTE_MXQUANT) ? 128 : 64);
        x.seg[0].push_back(seg_t'{src, src + len});
        for (u64_t b = 0; b < nb; b += g) begin
          automatic u64_t n = (nb - b < g) ? nb - b : g;
          x.seg[1].push_back(seg_t'{dst + b * 32, dst + (b + n) * 32});
          x.seg[1].push_back(seg_t'{sb + b, sb + b + n});
        end
      end
      idma_pkg::COMPUTE_MXDEQUANT, idma_pkg::COMPUTE_MXDEQUANT_FP16: begin
        nb   = len / 32;
        drem = up(len);
        x.kind = K_DEQUANT;
        x.eb   = (c.op == idma_pkg::COMPUTE_MXDEQUANT) ? 4 : 2;
        x.elo  = src;
        x.ehi  = src + nb * 32;
        for (u64_t b = 0; drem > 0; b += g) begin
          automatic u64_t n = (nb - b < g) ? nb - b : g;
          sg = (drem > g * 32) ? g * 32 : drem;
          x.seg[0].push_back(seg_t'{dn(sb + b), up(sb + b + n)});
          x.seg[0].push_back(seg_t'{src + b * 32, src + b * 32 + sg});
          drem -= sg;
        end
        x.seg[1].push_back(seg_t'{dst,
                                  dst + nb * ((c.op == idma_pkg::COMPUTE_MXDEQUANT) ? 128 : 64)});
      end
      default: begin
        if (planes) $display("[AXIMON] compute op %0d: plane checks off from here", c.op);
        planes = 1'b0;
      end
    endcase
  endfunction

  // AXI rules of an AR/AW; it carries the next bytes of its segment up to the burst limit
  function automatic void burst(int s, u64_t a, int len, int size, logic [1:0] bt, id_t id,
                                idma_pkg::axi_options_t o, logic [UserWidth-1:0] user,
                                logic [5:0] atop);
    xfer_c  x;
    u64_t   e = dn(a) + (u64_t'(len) + 1) * S, n, na;
    string  ch = s ? "AW" : "AR";
    nbur[s]++;
    ax_x = -1;
    // the legalizer issues full-width beats only; strobes are checked against whole beats
    if (size != LgS) err($sformatf("%s size %0d, the bus beat is size %0d", ch, size, LgS));
    if (bt == axi_pkg::BURST_INCR && ((a >> 12) != ((e - 1) >> 12)))
      err($sformatf("%s %0h len %0d crosses a 4 KiB page", ch, a, len));
    if (bt == 2'b11) err($sformatf("%s reserved burst type", ch));
    if (bt == axi_pkg::BURST_WRAP && !(len inside {1, 3, 7, 15}))
      err($sformatf("%s WRAP with len %0d", ch, len));
    if (bt == axi_pkg::BURST_FIXED && len > 15) err($sformatf("%s FIXED with len %0d", ch, len));
    if (atop != '0) err($sformatf("%s ATOP %0h", ch, atop));
    if (s) wq.push_back(bur_t'{addr: a, lo: a, hi: e, len: len, k: 0, x: -1, seg: -1, id: id});
    if (!planes) return;
    if (xq[s].size() == 0) begin
      err($sformatf("%s %0h len %0d without an open transfer", ch, a, len));
      return;
    end
    x  = xq[s][0];
    na = x.na[s];
    n  = x.seg[s][x.si[s]].hi - na;
    if (x.ps[s] - (na % x.ps[s]) < n) n = x.ps[s] - (na % x.ps[s]);
    if (x.coupled) begin
      automatic u64_t q = x.base[!s] + (na - x.base[s]);
      if (x.ps[!s] - (q % x.ps[!s]) < n) n = x.ps[!s] - (q % x.ps[!s]);
    end
    if (bt != x.burst[s]) err($sformatf("%s burst type %0d, request %0d", ch, bt, x.burst[s]));
    if (id != x.id || o.lock != x.opt[s].lock || o.cache != x.opt[s].cache ||
        o.prot != x.opt[s].prot || o.qos != x.opt[s].qos || o.region != x.opt[s].region ||
        user != (s ? x.user : '0))
      err($sformatf("x%0d %s %0h: id/lock/cache/prot/qos/region/user %0h %0b %0h %0h %0h %0h %0h%s",
                    x.idx, ch, a, id, o.lock, o.cache, o.prot, o.qos, o.region, user,
                    $sformatf(", request %0h %0b %0h %0h %0h %0h %0h", x.id, x.opt[s].lock,
                              x.opt[s].cache, x.opt[s].prot, x.opt[s].qos, x.opt[s].region,
                              s ? x.user : '0)));
    if (dn(a) != dn(na) || a > na || len != int'(((na + n - 1) >> LgS) - (na >> LgS)))
      err($sformatf("x%0d %s %0h len %0d: expected %0h len %0d (segment %0d [%0h, %0h))", x.idx, ch,
                    a, len, na, int'(((na + n - 1) >> LgS) - (na >> LgS)), x.si[s],
                    x.seg[s][x.si[s]].lo, x.seg[s][x.si[s]].hi));
    if (s) begin
      automatic bur_t b = wq.pop_back();
      b.lo = na; b.hi = na + n; b.x = x.idx; b.seg = x.si[s];
      wq.push_back(b);
    end
    ax_x = x.idx; ax_seg = x.si[s]; ax_lo = na; ax_hi = na + n;
    x.na[s] = na + n;
    if (x.na[s] >= x.seg[s][x.si[s]].hi) begin
      x.si[s]++;
      if (x.si[s] < x.seg[s].size()) x.na[s] = x.seg[s][x.si[s]].lo;
      else void'(xq[s].pop_front());
    end
  endfunction

  function automatic u64_t overlap(u64_t a, u64_t b, u64_t lo, u64_t hi);
    u64_t l = (a > lo) ? a : lo, h = (b < hi) ? b : hi;
    return (h > l) ? h - l : 0;
  endfunction

  // owed: quant elements not yet written plus scale bytes of written blocks, else counted bytes
  function automatic longint owed_of(xfer_c x);
    if (x.kind == K_QUANT) return (x.qin - x.qdat) + (x.qdat / 32 - x.qscl);
    return x.owed;
  endfunction

  // R (rd) or W bytes of segment seg; dequant reads and quant writes alternate data and scale
  function automatic void account(int xi, int seg, u64_t ba, u64_t lo, u64_t hi, bit rd);
    xfer_c  x;
    longint p;
    if (xi < 0 || xi >= xs.size()) return;
    x = xs[xi];
    held -= owed_of(x);
    p = longint'(overlap(ba, ba + S, lo, hi));
    unique case (x.kind)
      K_COPY: x.owed += rd ? p : -p;
      K_DEQUANT:
        if (!rd) x.owed -= p;
        else if (seg % 2 != 0) x.owed += longint'(overlap(ba, ba + S, (lo > x.elo) ? lo : x.elo,
                                                            (hi < x.ehi) ? hi : x.ehi)) * x.eb;
      K_QUANT:
        if (rd) x.qin += p / longint'(x.eb);
        else if (seg % 2 != 0) x.qscl += p;
        else x.qdat += p;
      default: ;
    endcase
    held += owed_of(x);
  endfunction

  // one W beat against the head AW burst: strobes inside the addressed bytes and the plane, WLAST
  function automatic void wbeat(wb_t w);
    u64_t   ba = dn(wq[0].addr) + u64_t'(wq[0].k) * S;
    strb_t  ax = '1, ex = '0;
    if (wq[0].k == 0) ax = strb_t'('1) << (wq[0].addr - dn(wq[0].addr));
    for (int i = 0; i < StrbWidth; i++) ex[i] = (ba + i >= wq[0].lo) && (ba + i < wq[0].hi);
    if ((w.strb & ~ax) != '0)
      err($sformatf("W beat %0d of AW %0h: strobe %0h outside the addressed bytes %0h", wq[0].k,
                    wq[0].addr, w.strb, ax));
    if (planes && wq[0].x >= 0 && w.strb != ex)
      err($sformatf("x%0d W beat %0d of AW %0h: strobe %0h, plane bytes %0h", wq[0].x, wq[0].k,
                    wq[0].addr, w.strb, ex));
    if (planes && wq[0].x >= 0) begin
      for (int i = 0; i < StrbWidth; i++) if (!w.strb[i]) ex[i] = 1'b0;
      account(wq[0].x, wq[0].seg, ba, ba, ba + u64_t'($countones(ex)), 1'b0);
    end
    if (w.last != (wq[0].k == wq[0].len))
      err($sformatf("W beat %0d of AW %0h len %0d: WLAST %0d", wq[0].k, wq[0].addr, wq[0].len,
                    w.last));
    nbeat[1]++;
    if (w.last || wq[0].k == wq[0].len) begin
      bq.push_back(wq[0].id);
      void'(wq.pop_front());
    end else wq[0].k++;
  endfunction

  typedef struct packed {
    logic [AddrWidth-1:0]   addr;
    logic [7:0]             len;
    logic [2:0]             size;
    logic [1:0]             burst;
    id_t                    id;
    idma_pkg::axi_options_t opt;
    logic [UserWidth-1:0]   user;
    logic [5:0]             atop;
  } ax_t;

  clocking cb @(posedge clk_i);
    default input #1step;
    input rst_ni, req_valid_i, req_ready_i, req_len_i, req_src_i, req_dst_i, req_scale_i,
          req_src_burst_i, req_dst_burst_i, req_decouple_rw_i, req_cmp_i, req_beo_i, req_id_i,
          req_src_opt_i, req_dst_opt_i, req_user_i, ar_valid_i, ar_ready_i, ar_addr_i,
          ar_len_i, ar_size_i, ar_burst_i, ar_id_i, ar_opt_i, ar_user_i, r_valid_i, r_ready_i,
          r_last_i, r_id_i, aw_valid_i, aw_ready_i, aw_addr_i, aw_len_i, aw_size_i, aw_burst_i,
          aw_id_i, aw_opt_i, aw_user_i, aw_atop_i, w_valid_i, w_ready_i, w_data_i, w_strb_i,
          w_last_i, b_valid_i, b_ready_i, b_id_i, busy_i;
  endclocking

  function automatic bit wdata_same(logic [StrbWidth-1:0][7:0] a, logic [StrbWidth-1:0][7:0] b,
                                    strb_t m);
    for (int i = 0; i < StrbWidth; i++) if (m[i] && a[i] !== b[i]) return 1'b0;
    return 1'b1;
  endfunction

  ax_t                       ar_q, aw_q;
  logic [StrbWidth-1:0][7:0] wd_q;
  logic [StrbWidth-1:0]      ws_q;
  logic                      wl_q, rl_q;
  id_t                       rid_q, bid_q;
  bit                        hold_ar, hold_aw, hold_w, hold_r, hold_b;

  always @(cb) begin
    if (cb.rst_ni) begin
      automatic ax_t ar = '{cb.ar_addr_i, cb.ar_len_i, cb.ar_size_i, cb.ar_burst_i, cb.ar_id_i,
                            cb.ar_opt_i, cb.ar_user_i, '0};
      automatic ax_t aw = '{cb.aw_addr_i, cb.aw_len_i, cb.aw_size_i, cb.aw_burst_i, cb.aw_id_i,
                            cb.aw_opt_i, cb.aw_user_i, cb.aw_atop_i};
      // a valid stays up with a stable payload until its handshake
      if (hold_ar && !(cb.ar_valid_i && ar == ar_q)) err("AR dropped or changed before AR ready");
      if (hold_aw && !(cb.aw_valid_i && aw == aw_q)) err("AW dropped or changed before AW ready");
      // WDATA must hold on the strobed lanes only (AXI4_ERRM_WDATA_STABLE)
      if (hold_w && !(cb.w_valid_i && cb.w_strb_i == ws_q && cb.w_last_i == wl_q &&
                      wdata_same(cb.w_data_i, wd_q, ws_q)))
        err("W dropped or changed before W ready");
      if (hold_r && !(cb.r_valid_i && cb.r_last_i == rl_q && cb.r_id_i == rid_q))
        err("R dropped or changed before R ready");
      if (hold_b && !(cb.b_valid_i && cb.b_id_i == bid_q))
        err("B dropped or changed before B ready");
      // busy in the cycle after bytes became outstanding (documented: idle when all flags are 0)
      if (need_buf && !cb.busy_i.buffer_busy)
        busy_err($sformatf("buffer_busy low while the buffer holds %0d bytes", held));
      if (need_r && !(cb.busy_i.r_leg_busy || cb.busy_i.r_dp_busy))
        busy_err("r_leg_busy and r_dp_busy low while read bursts or R beats are outstanding");
      if (need_w && !(cb.busy_i.w_leg_busy || cb.busy_i.w_dp_busy))
        busy_err("w_leg_busy and w_dp_busy low while write bursts or W beats are outstanding");
      hold_ar = cb.ar_valid_i && !cb.ar_ready_i;
      hold_aw = cb.aw_valid_i && !cb.aw_ready_i;
      hold_w  = cb.w_valid_i && !cb.w_ready_i;
      hold_r  = cb.r_valid_i && !cb.r_ready_i;
      hold_b  = cb.b_valid_i && !cb.b_ready_i;
      ar_q = ar; aw_q = aw; rl_q = cb.r_last_i; rid_q = cb.r_id_i; bid_q = cb.b_id_i;
      wd_q = cb.w_data_i; ws_q = cb.w_strb_i; wl_q = cb.w_last_i;

      if (cb.req_valid_i && cb.req_ready_i && cb.req_len_i != '0) begin
        automatic xfer_c x = new();
        automatic idma_pkg::compute_options_t c = cb.req_cmp_i;
        x.idx      = nx++;
        x.coupled  = !cb.req_decouple_rw_i && !c.enable;
        x.burst[0] = cb.req_src_burst_i;
        x.burst[1] = cb.req_dst_burst_i;
        x.ps[0]    = page(cb.req_beo_i.src_reduce_len, cb.req_beo_i.src_max_llen);
        x.ps[1]    = page(cb.req_beo_i.dst_reduce_len, cb.req_beo_i.dst_max_llen);
        x.id       = cb.req_id_i;
        x.opt[0]   = cb.req_src_opt_i;
        x.opt[1]   = cb.req_dst_opt_i;
        x.user     = cb.req_user_i;
        plan(x, u64_t'(cb.req_len_i), u64_t'(cb.req_src_i), u64_t'(cb.req_dst_i),
             u64_t'(cb.req_scale_i), c);
        xs.push_back(x);
        x.base[0] = u64_t'(cb.req_src_i);
        x.base[1] = u64_t'(cb.req_dst_i);
        for (int s = 0; s < 2; s++) begin
          x.na[s] = x.seg[s].size() ? x.seg[s][0].lo : 0;
          if (planes) xq[s].push_back(x);
        end
      end
      if (cb.ar_valid_i && cb.ar_ready_i) begin
        burst(0, u64_t'(ar.addr), int'(ar.len), int'(ar.size), ar.burst, ar.id, ar.opt, ar.user,
              '0);
        rq.push_back(rb_t'{addr: u64_t'(ar.addr), lo: ax_lo, hi: ax_hi, len: int'(ar.len), k: 0,
                           x: ax_x, seg: ax_seg, id: ar.id});
      end
      if (cb.aw_valid_i && cb.aw_ready_i) begin
        burst(1, u64_t'(aw.addr), int'(aw.len), int'(aw.size), aw.burst, aw.id, aw.opt, aw.user,
              aw.atop);
        while (wpend.size() && wq.size()) wbeat(wpend.pop_front());
      end
      if (cb.w_valid_i && cb.w_ready_i) begin
        if (wq.size() == 0) begin
          err("W beat without an open AW burst");
          wpend.push_back(wb_t'{strb: cb.w_strb_i, last: cb.w_last_i});
        end else wbeat(wb_t'{strb: cb.w_strb_i, last: cb.w_last_i});
      end
      if (cb.r_valid_i && cb.r_ready_i) begin
        automatic int i = 0;
        nbeat[0]++;
        while (i < rq.size() && rq[i].id != cb.r_id_i) i++;
        if (i == rq.size()) err($sformatf("R beat id %0h without an outstanding AR", cb.r_id_i));
        else begin
          if (cb.r_last_i != (rq[i].len == 0))
            err($sformatf("RLAST %0d with %0d beats left", cb.r_last_i, rq[i].len));
          if (planes) account(rq[i].x, rq[i].seg, dn(rq[i].addr) + u64_t'(rq[i].k) * S, rq[i].lo,
                              rq[i].hi, 1'b1);
          if (rq[i].len == 0) rq.delete(i);
          else begin rq[i].len--; rq[i].k++; end
        end
      end
      if (cb.b_valid_i && cb.b_ready_i) begin
        automatic int i = 0;
        while (i < bq.size() && bq[i] != cb.b_id_i) i++;
        if (i == bq.size()) err($sformatf("B id %0h without a completed write burst", cb.b_id_i));
        else bq.delete(i);
      end
      need_buf = planes && held > 0;
      need_r   = (planes && xq[0].size() > 0) || rq.size() > 0;
      need_w   = (planes && xq[1].size() > 0) || wq.size() > 0 || wpend.size() > 0;
    end else {need_buf, need_r, need_w} = '0;
  end

  function automatic void busy_err(string m);
    nbusy++;
    if (nbusy <= 8) err(m);
    else nerr++;
  endfunction

  final begin
    if (planes && (xq[0].size() || xq[1].size()))
      err($sformatf("%0d/%0d transfers with planes not fully read/written", xq[0].size(),
                    xq[1].size()));
    if (wq.size() || wpend.size() || rq.size())
      err($sformatf("open at the end: %0d AW bursts, %0d W beats, %0d AR bursts", wq.size(),
                    wpend.size(), rq.size()));
    if (planes && held != 0) err($sformatf("%0d bytes held in the buffer at the end", held));
    $display("[AXIMON] transfers=%0d AR=%0d AW=%0d R=%0d W=%0d planes=%0d violations=%0d", nx,
             nbur[0], nbur[1], nbeat[0], nbeat[1], planes, nerr);
  end
  // pragma translate_on

endmodule
