# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

when defined(windows):
  {.passl: "-lws2_32".}
  when defined(clang):
    {.passl: "-lpthread".}

import std/[os, strutils]
import chronos/osdefs
import zlib
import ../boringssl

type ptrdiff_t* {.importc: "ptrdiff_t", header: "<stddef.h>".} = int

# use rsplit as a workaround for cross compilation path separator issue
const root = currentSourcePath.rsplit({DirSep, AltSep}, 2)[0]
const lsquicInclude = root & "/libs/lsquic/include"
const boringsslInclude = root & "/libs/vac_boringssl/include"
const liblsquicInclude = root & "/libs/lsquic/src/liblsquic"
const lsqpack = root & "/libs/lsquic/src/liblsquic/ls-qpack"
const lshpack = root & "/libs/lsquic/src/lshpack"
const xxhash = root & "/libs/lsquic/src/lshpack/deps/xxhash"

when defined(windows):
  const wincompat = root & "/libs/lsquic/wincompat"
  {.passc: "-I" & wincompat.}

{.passc: "-I" & lsquicInclude.}
{.passc: "-I" & boringsslInclude.}
{.passc: "-I" & liblsquicInclude.}
{.passc: "-I" & lsqpack.}
{.passc: "-I" & lshpack.}
{.passc: "-I" & xxhash.}

const HAVE_BORINGSSL = "-DHAVE_BORINGSSL"
const XXH_HEADER_NAME = "-DXXH_HEADER_NAME=\"<lsquic_xxhash.h>\""

{.compile: "../libs/lsquic/src/liblsquic/lsquic_xxhash.c".}
{.compile("../libs/lsquic/src/liblsquic/ls-qpack/lsqpack.c", XXH_HEADER_NAME).}
{.compile("../libs/lsquic/src/lshpack/lshpack.c", XXH_HEADER_NAME).}
{.compile: "../libs/lsquic/src/liblsquic/ls-sfparser.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_adaptive_cc.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_alarmset.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_arr.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_attq.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_bbr.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_bw_sampler.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_cfcw.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_chsk_stream.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_conn.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_crand.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_crt_compress.c".}
{.compile("../libs/lsquic/src/liblsquic/lsquic_crypto.c", HAVE_BORINGSSL).}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_cubic.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_di_error.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_di_hash.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_di_nocopy.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_enc_sess_common.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_enc_sess_ietf.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_eng_hist.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_engine.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_ev_log.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_frab_list.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_frame_common.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_frame_reader.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_frame_writer.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_full_conn.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_full_conn_ietf.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_global.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_handshake.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_hash.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_hcsi_reader.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_hcso_writer.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_headers_stream.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_hkdf.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_hpi.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_hspack_valid.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_http.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_http1x_if.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_logger.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_malo.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_min_heap.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_mini_conn.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_mini_conn_ietf.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_minmax.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_mm.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_pacer.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_packet_common.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_packet_gquic.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_packet_in.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_packet_out.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_packet_resize.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_parse_Q046.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_parse_Q050.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_parse_common.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_parse_gquic_be.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_parse_gquic_common.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_parse_ietf_v1.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_parse_iquic_common.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_pr_queue.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_purga.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_qdec_hdl.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_qenc_hdl.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_qlog.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_qpack_exp.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_rechist.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_rtt.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_send_ctl.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_senhist.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_set.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_sfcw.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_shsk_stream.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_spi.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_stock_shi.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_str.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_stream.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_tokgen.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_trans_params.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_trechist.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_util.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_varint.c".}
{.compile: "../libs/lsquic/src/liblsquic/lsquic_version.c".}
