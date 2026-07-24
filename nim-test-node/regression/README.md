# Regression test node

Node for nim-libp2p regression campaigns. `Dockerfile_amd64` builds the static
cluster binary; `Dockerfile_amd64_shadow` builds the dynamic one for Shadow
(its syscall interposer only hooks dynamically linked ELFs).

## The lsquic tick-floor patch (Shadow + quic only)

`lsquic-tick-floor.patch`, applied by `Dockerfile_amd64_shadow`, is the reason
quic runs under Shadow at all. lsquic re-arms its engine tick with a zero delay;
in a discrete-event simulator that self-rescheduling timer never lets simulated
time advance, so the run livelocks at one instant. mplex and yamux are fine.

The patch floors the re-arm interval, gated by `LSQUIC_TICK_FLOOR_US` (unset/0 =
stock, so the image is safe on the cluster too; campaigns use `10000`, 10 ms).
`es_clock_granularity` is a real lsquic setting, but the essential change floors
nim-lsquic's own chronos re-arm, which has no upstream knob; the durable fix is
exposing both upstream in nim-lsquic.

## Maintaining the patch

It targets lsquic 0.5.4's layout, pinned in `test_node.nimble`. `nimble c`
re-resolves deps before compiling, so the Dockerfile patches the package cache
(`~/.nimble/pkgcache`, what nimble copies from) rather than the installed copy.
The build asserts it patched something and greps the binary for
`LSQUIC_TICK_FLOOR_US`, so a stock build or a stale pin fails loudly.
