---
type: decision
status: accepted
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-scope.md, raw/ideas/2026-10-26-licence.md]
tags: [licence, legal]
---
# d004 — Licence

*Status: accepted (2026-10-26).* The app is open source under **Apache-2.0** (raw/ideas/2026-10-26-scope.md, raw/ideas/2026-10-26-licence.md).

## Why
Permissive like MIT, so it is fine on both app stores and easy for contributors. It adds an explicit patent grant from contributors, which matters in audio DSP.

## Options considered
MIT (simpler, no patent grant); GPLv3 (keeps forks open, but needs contributor agreements to stay on the App Store). Both rejected.

## Dependency check
Every dependency must stay permissive:
- Flutter: BSD
- miniaudio: public domain / MIT-0 (verified from the vendored 0.11.25 LICENSE, 2026-10-26)
- Signalsmith Stretch: MIT

Avoid GPL dependencies in anything that ships (see [[d002-pitch-time-library]]).

## M0 actions
- [x] Add `LICENSE` (Apache-2.0 full text) and a `NOTICE` file naming the copyright holder. *(2026-10-26; holder written as "The Pocket Studio Authors" until the human names one.)*
- [x] Add `THIRD_PARTY_NOTICES.md` listing Flutter, miniaudio and Signalsmith Stretch with their licences, and show it on an in-app "Licences" screen. *(2026-10-26; Signalsmith listed as planned for M4; Licences screen is `showLicensePage` in `app/lib/main.dart`.)*
- [x] Add `CONTRIBUTING.md`: contributions are accepted under Apache-2.0 (inbound = outbound, no separate agreement needed).
- [x] Lint rule: any new dependency must be permissive (MIT, BSD, Apache-2.0, zlib, public domain); GPL/LGPL needs a decision page first. *(Stated in `CONTRIBUTING.md`; `tools/wiki_lint.py` checks every vendored `third_party/` folder is in `THIRD_PARTY_NOTICES.md`.)*
