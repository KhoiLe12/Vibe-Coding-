# Third-party notices

Pocket Studio is licensed under Apache-2.0 (see `LICENSE`). It includes or
depends on the following third-party software. Every dependency must be
permissive (MIT, BSD, Apache-2.0, zlib, public domain); a GPL/LGPL dependency
needs a decision page first (wiki/decisions/d004-licence.md).

The app shows these licences on its in-app **Licences** screen.

| Component | Version | Licence | Where | Status |
|---|---|---|---|---|
| [Flutter](https://flutter.dev) (framework and engine) | 3.47.8 | BSD-3-Clause | build toolchain + app runtime | shipped |
| [miniaudio](https://miniaud.io) by David Reid | 0.11.25 | Public domain (Unlicense) **or** MIT-0, at our choice | `app/packages/pocket_audio/src/third_party/miniaudio/` | shipped |
| [Signalsmith Stretch](https://signalsmith-audio.co.uk/code/stretch/) | — | MIT | not vendored yet | planned for M4 (wiki/decisions/d002-pitch-time-library.md) |

Dart packages pulled in through `pub` (for example `ffi`, `hooks`,
`native_toolchain_c`, `code_assets`, `logging`) are BSD-3-Clause and are listed
automatically on the Licences screen by Flutter's licence registry.

Full licence texts:
- miniaudio: `app/packages/pocket_audio/src/third_party/miniaudio/LICENSE`
  (also bundled as `app/assets/licenses/miniaudio.txt` for the Licences screen)
- Flutter: https://github.com/flutter/flutter/blob/master/LICENSE
