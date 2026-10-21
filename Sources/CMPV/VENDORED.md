# libmpv C API headers

The unmodified files in `include/mpv/` come from mpv **v0.41.0**:

- Source: https://github.com/mpv-player/mpv/tree/v0.41.0/include/mpv
- Client API: **2.5**
- `client.h` SHA-256: `3c073236a09cb456c6e80587d5523c8771c32fb22ca014e0f99cc3d43905b75c`
- `render.h` SHA-256: `192691941602052f00df0587f126246c48785a1cf21de68d22a92ea1908d1c55`
- `render_gl.h` SHA-256: `48662c0ed9872a14dd9e1684105c97f69f94a0414709c254c5d372adc41d2e69`

These API headers retain their upstream ISC notices. That permissive header
license does **not** apply to the complete libmpv binary: mpv is GPLv2+ by
default, and may be LGPLv2.1+ only for an appropriately configured build and
dependency set. `LICENSE.GPL` and `LICENSE.LGPL` are the unmodified upstream
v0.41.0 license texts; their presence is not a claim that every linked library
uses both licenses.

The development runtime is discovered locally and is not vendored in this
directory. See `docs/mpv-runtime.md` for runtime provenance, packaging, and the
remaining requirements before redistributing a release.
