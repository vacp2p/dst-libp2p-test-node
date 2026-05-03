# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

# libcrypto + libssl sources without cmake, no-asm, no fips, no tests, tools
# TODO: look into use assembly files for perf

import std/[os, strutils]

# ----- toolchain + includes -----
{.localPassC: "-DBORINGSSL_IMPLEMENTATION -DS2N_BN_HIDE_SYMBOLS".}

{.
  localPassC:
    "-fno-common -fvisibility=hidden -fno-strict-aliasing -Werror -Wformat=2 -Wsign-compare -Wwrite-strings -Wvla -Wshadow -Wtype-limits -Wmissing-field-initializers -ffunction-sections -fdata-sections -fno-exceptions -fno-rtti"
.}

const
  # use rsplit as a workaround for cross compilation path separator issue
  srcPath = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]

{.passc: "-I" & srcPath & "/libs/vac_boringssl/include".}

{.localPassC: "-DNDEBUG".}

when defined(linux):
  {.localPassC: "-D_XOPEN_SOURCE=700".}
elif defined(windows):
  {.
    localPassC:
      "-D_HAS_EXCEPTIONS=0 -DWIN32_LEAN_AND_MEAN -DNOMINMAX -D_CRT_SECURE_NO_WARNINGS"
  .}

when defined(i386):
  {.passc: "-msse2".}

const BORINGSS_USE_ASM {.booldefine.}: bool = true
when BORINGSS_USE_ASM:
  when not defined(windows):
    {.compile: "./libs/vac_boringssl/crypto/hrss/asm/poly_rq_mul.S".}
    {.compile: "./libs/vac_boringssl/third_party/fiat/asm/fiat_curve25519_adx_mul.S".}
    {.
      compile: "./libs/vac_boringssl/third_party/fiat/asm/fiat_curve25519_adx_square.S"
    .}
    {.compile: "./libs/vac_boringssl/third_party/fiat/asm/fiat_p256_adx_mul.S".}
    {.compile: "./libs/vac_boringssl/third_party/fiat/asm/fiat_p256_adx_sqr.S".}
    {.compile: "./libs/vac_boringssl/crypto/curve25519/asm/x25519-asm-arm.S".}
    {.compile: "./libs/vac_boringssl/crypto/poly1305/poly1305_arm_asm.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/aes128gcmsiv-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/aes128gcmsiv-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/chacha-armv4-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/chacha-armv8-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/chacha-armv8-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/chacha-armv8-win.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/chacha-x86-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/chacha-x86-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/chacha-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/chacha-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/chacha20_poly1305_armv8-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/chacha20_poly1305_armv8-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/chacha20_poly1305_armv8-win.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/chacha20_poly1305_x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/chacha20_poly1305_x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/md5-586-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/md5-586-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/md5-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/crypto/md5-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aes-gcm-avx2-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aes-gcm-avx2-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aes-gcm-avx512-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aes-gcm-avx512-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aesni-gcm-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aesni-gcm-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aesni-x86-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aesni-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aesni-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aesni-x86-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aesv8-armv7-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aesv8-armv8-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aesv8-armv8-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aesv8-armv8-win.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aesv8-gcm-armv8-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aesv8-gcm-armv8-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/aesv8-gcm-armv8-win.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/armv4-mont-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/armv8-mont-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/armv8-mont-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/armv8-mont-win.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/bn-586-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/bn-586-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/bn-armv8-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/bn-armv8-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/bn-armv8-win.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/bsaes-armv7-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/co-586-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/co-586-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghash-armv4-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghash-neon-armv8-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghash-neon-armv8-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghash-neon-armv8-win.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghash-ssse3-x86-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghash-ssse3-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghash-ssse3-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghash-ssse3-x86-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghash-x86-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghash-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghash-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghash-x86-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghashv8-armv7-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghashv8-armv8-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghashv8-armv8-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/ghashv8-armv8-win.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/p256-armv8-asm-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/p256-armv8-asm-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/p256-armv8-asm-win.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/p256-x86_64-asm-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/p256-x86_64-asm-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/p256_beeu-armv8-asm-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/p256_beeu-armv8-asm-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/p256_beeu-armv8-asm-win.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/p256_beeu-x86_64-asm-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/p256_beeu-x86_64-asm-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/rdrand-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/rdrand-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/rsaz-avx2-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/rsaz-avx2-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha1-586-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha1-586-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha1-armv4-large-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha1-armv8-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha1-armv8-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha1-armv8-win.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha1-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha1-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha256-586-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha256-586-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha256-armv4-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha256-armv8-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha256-armv8-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha256-armv8-win.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha256-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha256-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha512-586-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha512-586-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha512-armv4-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha512-armv8-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha512-armv8-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha512-armv8-win.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha512-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/sha512-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/vpaes-armv7-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/vpaes-armv8-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/vpaes-armv8-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/vpaes-armv8-win.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/vpaes-x86-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/vpaes-x86_64-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/vpaes-x86_64-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/vpaes-x86-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/x86-mont-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/x86_64-mont-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/x86_64-mont-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/x86-mont-linux.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/x86_64-mont5-apple.S".}
    {.compile: "./libs/vac_boringssl/gen/bcm/x86_64-mont5-linux.S".}

  when defined(windows):
    import std/[macros, md5, os, pathnorm]
    const baseDir = currentSourcePath.parentDir
    const outDir = baseDir / "libs"
    const asmFiles = [
      "./libs/vac_boringssl/gen/bcm/aes-gcm-avx2-x86_64-win.asm",
      "./libs/vac_boringssl/gen/bcm/aes-gcm-avx512-x86_64-win.asm",
      "./libs/vac_boringssl/gen/bcm/aesni-gcm-x86_64-win.asm",
      "./libs/vac_boringssl/gen/bcm/aesni-x86-win.asm",
      "./libs/vac_boringssl/gen/bcm/aesni-x86_64-win.asm",
      "./libs/vac_boringssl/gen/bcm/ghash-ssse3-x86-win.asm",
      "./libs/vac_boringssl/gen/bcm/ghash-ssse3-x86_64-win.asm",
      "./libs/vac_boringssl/gen/bcm/ghash-x86-win.asm",
      "./libs/vac_boringssl/gen/bcm/ghash-x86_64-win.asm",
      "./libs/vac_boringssl/gen/bcm/p256-x86_64-asm-win.asm",
      "./libs/vac_boringssl/gen/bcm/p256_beeu-x86_64-asm-win.asm",
      "./libs/vac_boringssl/gen/bcm/rdrand-x86_64-win.asm",
      "./libs/vac_boringssl/gen/bcm/rsaz-avx2-win.asm",
      "./libs/vac_boringssl/gen/bcm/sha1-x86_64-win.asm",
      "./libs/vac_boringssl/gen/bcm/sha256-x86_64-win.asm",
      "./libs/vac_boringssl/gen/bcm/sha512-x86_64-win.asm",
      "./libs/vac_boringssl/gen/bcm/vpaes-x86-win.asm",
      "./libs/vac_boringssl/gen/bcm/vpaes-x86_64-win.asm",
      "./libs/vac_boringssl/gen/bcm/x86-mont-win.asm",
      "./libs/vac_boringssl/gen/bcm/x86_64-mont-win.asm",
      "./libs/vac_boringssl/gen/bcm/x86_64-mont5-win.asm",
      "./libs/vac_boringssl/gen/crypto/md5-x86_64-win.asm",
      "./libs/vac_boringssl/gen/crypto/chacha20_poly1305_x86_64-win.asm",
      "./libs/vac_boringssl/gen/crypto/chacha-x86_64-win.asm",
    ]

    macro linkAsmFiles(
        files: static[openArray[string]], outDir: static[string]
    ): untyped =
      result = newStmtList()
      for f in files:
        let (_, name, _) = splitFile(f)
        let obj = normalizePath((outDir / name) & ".obj", dirSep = '/')
        let objLit = newLit(obj)
        result.add quote do:
          {.link: `objLit`.}

    static:
      for asmPathRel in asmFiles:
        let asmPath = normalizePath(baseDir / asmPathRel, dirSep = '/')
        let outObj =
          normalizePath(outDir / (asmPath.splitFile.name & ".obj"), dirSep = '/')
        let hashPath = outObj & ".md5"
        let srcHash = getMD5(staticRead(asmPath))
        let cachedHash =
          if fileExists(hashPath):
            readFile(hashPath)
          else:
            ""
        if (not fileExists(outObj)) or (cachedHash != srcHash):
          let cmd = "nasm -f win64 " & quoteShell(asmPath) & " -o " & quoteShell(outObj)
          let res = gorgeEx(cmd)
          doAssert res.exitCode == 0,
            "Failed cmd exit-code: " & $res.exitCode & " output: " & res.output
          writeFile(hashPath, srcHash)

    linkAsmFiles(asmFiles, outDir)

# ----- generated sources -----
{.compile: "./libs/vac_boringssl/crypto/fipsmodule/bcm.cc".}
{.compile: "./libs/vac_boringssl/crypto/aes/aes.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_bitstr.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_bool.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_d2i_fp.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_dup.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_gentm.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_i2d_fp.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_int.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_mbstr.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_object.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_octet.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_strex.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_strnid.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_time.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_type.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/a_utctm.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/asn1_lib.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/asn1_par.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/asn_pack.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/f_int.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/f_string.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/posix_time.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/tasn_dec.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/tasn_enc.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/tasn_fre.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/tasn_new.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/tasn_typ.cc".}
{.compile: "./libs/vac_boringssl/crypto/asn1/tasn_utl.cc".}
{.compile: "./libs/vac_boringssl/crypto/base64/base64.cc".}
{.compile: "./libs/vac_boringssl/crypto/bio/bio.cc".}
{.compile: "./libs/vac_boringssl/crypto/bio/bio_mem.cc".}
{.compile: "./libs/vac_boringssl/crypto/bio/connect.cc".}
{.compile: "./libs/vac_boringssl/crypto/bio/errno.cc".}
{.compile: "./libs/vac_boringssl/crypto/bio/fd.cc".}
{.compile: "./libs/vac_boringssl/crypto/bio/file.cc".}
{.compile: "./libs/vac_boringssl/crypto/bio/hexdump.cc".}
{.compile: "./libs/vac_boringssl/crypto/bio/pair.cc".}
{.compile: "./libs/vac_boringssl/crypto/bio/printf.cc".}
{.compile: "./libs/vac_boringssl/crypto/bio/socket.cc".}
{.compile: "./libs/vac_boringssl/crypto/bio/socket_helper.cc".}
{.compile: "./libs/vac_boringssl/crypto/blake2/blake2.cc".}
{.compile: "./libs/vac_boringssl/crypto/bn/bn_asn1.cc".}
{.compile: "./libs/vac_boringssl/crypto/bn/convert.cc".}
{.compile: "./libs/vac_boringssl/crypto/bn/div.cc".}
{.compile: "./libs/vac_boringssl/crypto/bn/exponentiation.cc".}
{.compile: "./libs/vac_boringssl/crypto/bn/sqrt.cc".}
{.compile: "./libs/vac_boringssl/crypto/buf/buf.cc".}
{.compile: "./libs/vac_boringssl/crypto/bytestring/asn1_compat.cc".}
{.compile: "./libs/vac_boringssl/crypto/bytestring/ber.cc".}
{.compile: "./libs/vac_boringssl/crypto/bytestring/cbb.cc".}
{.compile: "./libs/vac_boringssl/crypto/bytestring/cbs.cc".}
{.compile: "./libs/vac_boringssl/crypto/bytestring/unicode.cc".}
{.compile: "./libs/vac_boringssl/crypto/chacha/chacha.cc".}
{.compile: "./libs/vac_boringssl/crypto/cipher/derive_key.cc".}
{.compile: "./libs/vac_boringssl/crypto/cipher/e_aesctrhmac.cc".}
{.compile: "./libs/vac_boringssl/crypto/cipher/e_aeseax.cc".}
{.compile: "./libs/vac_boringssl/crypto/cipher/e_aesgcmsiv.cc".}
{.compile: "./libs/vac_boringssl/crypto/cipher/e_chacha20poly1305.cc".}
{.compile: "./libs/vac_boringssl/crypto/cipher/e_des.cc".}
{.compile: "./libs/vac_boringssl/crypto/cipher/e_null.cc".}
{.compile: "./libs/vac_boringssl/crypto/cipher/e_rc2.cc".}
{.compile: "./libs/vac_boringssl/crypto/cipher/e_rc4.cc".}
{.compile: "./libs/vac_boringssl/crypto/cipher/e_tls.cc".}
{.compile: "./libs/vac_boringssl/crypto/cipher/get_cipher.cc".}
{.compile: "./libs/vac_boringssl/crypto/cipher/tls_cbc.cc".}
{.compile: "./libs/vac_boringssl/crypto/cms/cms.cc".}
{.compile: "./libs/vac_boringssl/crypto/conf/conf.cc".}
{.compile: "./libs/vac_boringssl/crypto/cpu_aarch64_apple.cc".}
{.compile: "./libs/vac_boringssl/crypto/cpu_aarch64_fuchsia.cc".}
{.compile: "./libs/vac_boringssl/crypto/cpu_aarch64_linux.cc".}
{.compile: "./libs/vac_boringssl/crypto/cpu_aarch64_openbsd.cc".}
{.compile: "./libs/vac_boringssl/crypto/cpu_aarch64_sysreg.cc".}
{.compile: "./libs/vac_boringssl/crypto/cpu_aarch64_win.cc".}
{.compile: "./libs/vac_boringssl/crypto/cpu_arm_freebsd.cc".}
{.compile: "./libs/vac_boringssl/crypto/cpu_arm_linux.cc".}
{.compile: "./libs/vac_boringssl/crypto/cpu_intel.cc".}
{.compile: "./libs/vac_boringssl/crypto/crypto.cc".}
{.compile: "./libs/vac_boringssl/crypto/curve25519/curve25519.cc".}
{.compile: "./libs/vac_boringssl/crypto/curve25519/curve25519_64_adx.cc".}
{.compile: "./libs/vac_boringssl/crypto/curve25519/spake25519.cc".}
{.compile: "./libs/vac_boringssl/crypto/des/des.cc".}
{.compile: "./libs/vac_boringssl/crypto/dh/dh_asn1.cc".}
{.compile: "./libs/vac_boringssl/crypto/dh/params.cc".}
{.compile: "./libs/vac_boringssl/crypto/digest/digest_extra.cc".}
{.compile: "./libs/vac_boringssl/crypto/dsa/dsa.cc".}
{.compile: "./libs/vac_boringssl/crypto/dsa/dsa_asn1.cc".}
{.compile: "./libs/vac_boringssl/crypto/ec/ec_asn1.cc".}
{.compile: "./libs/vac_boringssl/crypto/ec/ec_derive.cc".}
{.compile: "./libs/vac_boringssl/crypto/ec/hash_to_curve.cc".}
{.compile: "./libs/vac_boringssl/crypto/ecdh/ecdh.cc".}
{.compile: "./libs/vac_boringssl/crypto/ecdsa/ecdsa_asn1.cc".}
{.compile: "./libs/vac_boringssl/crypto/ecdsa/ecdsa_p1363.cc".}
{.compile: "./libs/vac_boringssl/crypto/engine/engine.cc".}
{.compile: "./libs/vac_boringssl/crypto/err/err.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/evp.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/evp_asn1.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/evp_ctx.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/p_dh.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/p_dsa.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/p_ec.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/p_ed25519.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/p_hkdf.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/p_rsa.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/p_x25519.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/pbkdf.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/print.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/scrypt.cc".}
{.compile: "./libs/vac_boringssl/crypto/evp/sign.cc".}
{.compile: "./libs/vac_boringssl/crypto/ex_data.cc".}
{.compile: "./libs/vac_boringssl/crypto/fipsmodule/fips_shared_support.cc".}
{.compile: "./libs/vac_boringssl/crypto/fuzzer_mode.cc".}
{.compile: "./libs/vac_boringssl/crypto/hpke/hpke.cc".}
{.compile: "./libs/vac_boringssl/crypto/hrss/hrss.cc".}
{.compile: "./libs/vac_boringssl/crypto/kyber/kyber.cc".}
{.compile: "./libs/vac_boringssl/crypto/lhash/lhash.cc".}
{.compile: "./libs/vac_boringssl/crypto/md4/md4.cc".}
{.compile: "./libs/vac_boringssl/crypto/md5/md5.cc".}
{.compile: "./libs/vac_boringssl/crypto/mem.cc".}
{.compile: "./libs/vac_boringssl/crypto/mldsa/mldsa.cc".}
{.compile: "./libs/vac_boringssl/crypto/mlkem/mlkem.cc".}
{.compile: "./libs/vac_boringssl/crypto/obj/obj.cc".}
{.compile: "./libs/vac_boringssl/crypto/obj/obj_xref.cc".}
{.compile: "./libs/vac_boringssl/crypto/pem/pem_all.cc".}
{.compile: "./libs/vac_boringssl/crypto/pem/pem_info.cc".}
{.compile: "./libs/vac_boringssl/crypto/pem/pem_lib.cc".}
{.compile: "./libs/vac_boringssl/crypto/pem/pem_oth.cc".}
{.compile: "./libs/vac_boringssl/crypto/pem/pem_pk8.cc".}
{.compile: "./libs/vac_boringssl/crypto/pem/pem_pkey.cc".}
{.compile: "./libs/vac_boringssl/crypto/pem/pem_x509.cc".}
{.compile: "./libs/vac_boringssl/crypto/pem/pem_xaux.cc".}
{.compile: "./libs/vac_boringssl/crypto/pkcs7/pkcs7.cc".}
{.compile: "./libs/vac_boringssl/crypto/pkcs7/pkcs7_x509.cc".}
{.compile: "./libs/vac_boringssl/crypto/pkcs8/p5_pbev2.cc".}
{.compile: "./libs/vac_boringssl/crypto/pkcs8/pkcs8.cc".}
{.compile: "./libs/vac_boringssl/crypto/pkcs8/pkcs8_x509.cc".}
{.compile: "./libs/vac_boringssl/crypto/poly1305/poly1305.cc".}
{.compile: "./libs/vac_boringssl/crypto/poly1305/poly1305_arm.cc".}
{.compile: "./libs/vac_boringssl/crypto/poly1305/poly1305_vec.cc".}
{.compile: "./libs/vac_boringssl/crypto/pool/pool.cc".}
{.compile: "./libs/vac_boringssl/crypto/rand/deterministic.cc".}
{.compile: "./libs/vac_boringssl/crypto/rand/fork_detect.cc".}
{.compile: "./libs/vac_boringssl/crypto/rand/forkunsafe.cc".}
{.compile: "./libs/vac_boringssl/crypto/rand/getentropy.cc".}
{.compile: "./libs/vac_boringssl/crypto/rand/ios.cc".}
{.compile: "./libs/vac_boringssl/crypto/rand/passive.cc".}
{.compile: "./libs/vac_boringssl/crypto/rand/rand.cc".}
{.compile: "./libs/vac_boringssl/crypto/rand/trusty.cc".}
{.compile: "./libs/vac_boringssl/crypto/rand/urandom.cc".}
{.compile: "./libs/vac_boringssl/crypto/rand/windows.cc".}
{.compile: "./libs/vac_boringssl/crypto/rc4/rc4.cc".}
{.compile: "./libs/vac_boringssl/crypto/refcount.cc".}
{.compile: "./libs/vac_boringssl/crypto/rsa/rsa_asn1.cc".}
{.compile: "./libs/vac_boringssl/crypto/rsa/rsa_crypt.cc".}
{.compile: "./libs/vac_boringssl/crypto/rsa/rsa_extra.cc".}
{.compile: "./libs/vac_boringssl/crypto/rsa/rsa_print.cc".}
{.compile: "./libs/vac_boringssl/crypto/sha/sha1.cc".}
{.compile: "./libs/vac_boringssl/crypto/sha/sha256.cc".}
{.compile: "./libs/vac_boringssl/crypto/sha/sha512.cc".}
{.compile: "./libs/vac_boringssl/crypto/siphash/siphash.cc".}
{.compile: "./libs/vac_boringssl/crypto/slhdsa/slhdsa.cc".}
{.compile: "./libs/vac_boringssl/crypto/spake2plus/spake2plus.cc".}
{.compile: "./libs/vac_boringssl/crypto/stack/stack.cc".}
{.compile: "./libs/vac_boringssl/crypto/thread.cc".}
{.compile: "./libs/vac_boringssl/crypto/thread_none.cc".}
{.compile: "./libs/vac_boringssl/crypto/thread_pthread.cc".}
{.compile: "./libs/vac_boringssl/crypto/thread_win.cc".}
{.compile: "./libs/vac_boringssl/crypto/trust_token/pmbtoken.cc".}
{.compile: "./libs/vac_boringssl/crypto/trust_token/trust_token.cc".}
{.compile: "./libs/vac_boringssl/crypto/trust_token/voprf.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/a_digest.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/a_sign.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/a_verify.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/algorithm.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/asn1_gen.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/by_dir.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/by_file.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/i2d_pr.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/name_print.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/policy.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/rsa_pss.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/t_crl.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/t_req.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/t_x509.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/t_x509a.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_akey.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_akeya.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_alt.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_bcons.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_bitst.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_conf.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_cpols.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_crld.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_enum.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_extku.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_genn.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_ia5.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_info.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_int.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_lib.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_ncons.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_ocsp.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_pcons.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_pmaps.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_prn.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_purp.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_skey.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/v3_utl.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_att.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_cmp.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_d2.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_def.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_ext.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_lu.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_obj.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_req.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_set.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_trs.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_txt.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_v3.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_vfy.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509_vpm.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509cset.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509name.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509rset.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x509spki.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x_algor.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x_all.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x_attrib.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x_crl.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x_exten.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x_name.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x_pubkey.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x_req.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x_sig.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x_spki.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x_x509.cc".}
{.compile: "./libs/vac_boringssl/crypto/x509/x_x509a.cc".}
{.compile: "./libs/vac_boringssl/crypto/xwing/xwing.cc".}
{.compile: "./libs/vac_boringssl/gen/crypto//err_data.cc".}
{.compile: "./libs/vac_boringssl/ssl/bio_ssl.cc".}
{.compile: "./libs/vac_boringssl/ssl/d1_both.cc".}
{.compile: "./libs/vac_boringssl/ssl/d1_lib.cc".}
{.compile: "./libs/vac_boringssl/ssl/d1_pkt.cc".}
{.compile: "./libs/vac_boringssl/ssl/d1_srtp.cc".}
{.compile: "./libs/vac_boringssl/ssl/dtls_method.cc".}
{.compile: "./libs/vac_boringssl/ssl/dtls_record.cc".}
{.compile: "./libs/vac_boringssl/ssl/encrypted_client_hello.cc".}
{.compile: "./libs/vac_boringssl/ssl/extensions.cc".}
{.compile: "./libs/vac_boringssl/ssl/handoff.cc".}
{.compile: "./libs/vac_boringssl/ssl/handshake.cc".}
{.compile: "./libs/vac_boringssl/ssl/handshake_client.cc".}
{.compile: "./libs/vac_boringssl/ssl/handshake_server.cc".}
{.compile: "./libs/vac_boringssl/ssl/s3_both.cc".}
{.compile: "./libs/vac_boringssl/ssl/s3_lib.cc".}
{.compile: "./libs/vac_boringssl/ssl/s3_pkt.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_aead_ctx.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_asn1.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_buffer.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_cert.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_cipher.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_credential.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_file.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_key_share.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_lib.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_privkey.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_session.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_stat.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_transcript.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_versions.cc".}
{.compile: "./libs/vac_boringssl/ssl/ssl_x509.cc".}
{.compile: "./libs/vac_boringssl/ssl/t1_enc.cc".}
{.compile: "./libs/vac_boringssl/ssl/tls13_both.cc".}
{.compile: "./libs/vac_boringssl/ssl/tls13_client.cc".}
{.compile: "./libs/vac_boringssl/ssl/tls13_enc.cc".}
{.compile: "./libs/vac_boringssl/ssl/tls13_server.cc".}
{.compile: "./libs/vac_boringssl/ssl/tls_method.cc".}
{.compile: "./libs/vac_boringssl/ssl/tls_record.cc".}
{.compile: "./libs/vac_boringssl/decrepit/x509/x509_decrepit.cc".}
