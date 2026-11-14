# Vendored: Signalsmith Stretch + Signalsmith Linear

Pitch/time library for transpose and tempo (wiki/decisions/d002-pitch-time-library.md,
wiki/decisions/d013-transpose-tempo-design.md). Header-only; only headers and licences are kept.

| Library | Version | Source archive (sha256) | Licence |
|---|---|---|---|
| Signalsmith Stretch | 1.4.0 | github.com/Signalsmith-Audio/signalsmith-stretch tag `1.4.0` — `077235709ecf2a358545e3ca7bdf32859f70f5c9afb4493e078bd753c9aff284` | MIT (`stretch/LICENSE.txt`) |
| Signalsmith Linear | 0.6.4 (the version Stretch 1.4.0's CMake pins) | github.com/Signalsmith-Audio/linear tag `0.6.4` — `2cb10d84b96c626255ab46c4aa4c80f64ae532be487063cff6a08903c1445a56` | MIT (`linear/LICENSE.txt`) |

Unmodified. Include path: `linear/include` (so `signalsmith-linear/stft.h` resolves). Apple builds define
`SIGNALSMITH_USE_ACCELERATE` (FFT via the Accelerate framework); others use the built-in FFT.
