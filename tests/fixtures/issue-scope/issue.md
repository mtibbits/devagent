# gnuradio/volk#999 — Add SIMD path for foo_kernel

- State: open
- Author: @example
- Labels: enhancement, performance
- URL: https://github.com/gnuradio/volk/issues/999

---

We need an AVX2 implementation of `foo_kernel` to match the SSE one.
Should follow the existing pattern in `bar_kernel`. Bonus points if
ARM NEON gets added too.

---

## Comments (1)

### @maintainer · 2026-05-10

Please open a separate issue for NEON.
