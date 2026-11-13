# Contributing to Pocket Studio

Thanks for helping! Pocket Studio is open source under the Apache License 2.0.

## Licence of contributions

Contributions are accepted under Apache-2.0, the same licence as the project
(**inbound = outbound**). This is what section 5 of the licence already says;
there is no separate contributor agreement to sign. By opening a pull request
you confirm you have the right to submit the work under that licence.

New source files start with:

    // Copyright 2026 The Pocket Studio Authors
    // SPDX-License-Identifier: Apache-2.0

## Dependencies

Every new dependency must be permissive (MIT, BSD, Apache-2.0, zlib, public
domain) and listed in `THIRD_PARTY_NOTICES.md`. GPL or LGPL code needs a
decision page in `wiki/decisions/` first, because it is a problem on the App
Store (see `wiki/decisions/d004-licence.md`).

## How the repo works

- `raw/` holds immutable sources (plan, docs, ideas, feedback). Never edit it.
- `wiki/` is the project's knowledge base, maintained mostly by a coding agent
  following `CLAUDE.md`. Code changes should update the matching component and
  decision pages and add a line to `wiki/log.md`.
- `app/` is the Flutter app; `app/packages/pocket_audio/` is the C++ audio core.

## Before you open a PR

    python3 tools/wiki_lint.py
    (cd app/packages/pocket_audio && dart analyze && dart test)
    (cd app && flutter analyze && flutter test)

Audio code that runs on the real-time thread must not allocate, lock or do
file I/O (`wiki/concepts/audio-latency.md`).
