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
| [Signalsmith Stretch](https://signalsmith-audio.co.uk/code/stretch/) by Geraint Luff / Signalsmith Audio | 1.4.0 | MIT | `app/packages/pocket_audio/src/third_party/signalsmith/stretch/` | shipped (M4, wiki/decisions/d002-pitch-time-library.md) |
| [Signalsmith Linear](https://github.com/Signalsmith-Audio/linear) by Signalsmith Audio | 0.6.4 | MIT | `app/packages/pocket_audio/src/third_party/signalsmith/linear/` | shipped (required by Stretch) |
| [path_provider](https://pub.dev/packages/path_provider) (Flutter team) | ^2.1.6 | BSD-3-Clause | Dart package | shipped (listed automatically) |
| [share_plus](https://pub.dev/packages/share_plus) (Flutter Community) | ^13.3.1 | BSD-3-Clause | Dart package + iOS/Android plugin | shipped (M7 export, wiki/decisions/d016-sampling-tools.md; listed automatically) |

Dart packages pulled in through `pub` (for example `ffi`, `hooks`,
`native_toolchain_c`, `code_assets`, `logging`, and share_plus's
`cross_file`, `mime`, `file`, `url_launcher_*`, `web`, `win32`) are BSD-3-Clause and are listed
automatically on the Licences screen by Flutter's licence registry.

Full licence texts:
- miniaudio: `app/packages/pocket_audio/src/third_party/miniaudio/LICENSE`
  (also bundled as `app/assets/licenses/miniaudio.txt` for the Licences screen)
- Signalsmith Stretch: `app/packages/pocket_audio/src/third_party/signalsmith/stretch/LICENSE.txt`
  (bundled as `app/assets/licenses/signalsmith-stretch.txt`)
- Signalsmith Linear: `app/packages/pocket_audio/src/third_party/signalsmith/linear/LICENSE.txt`
  (bundled as `app/assets/licenses/signalsmith-linear.txt`)
- Flutter: https://github.com/flutter/flutter/blob/master/LICENSE
