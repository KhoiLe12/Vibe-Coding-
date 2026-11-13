---
type: source
status: done
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md]
tags: [plan, bootstrap]
---
# Source: Pocket Studio build plan

**Raw file:** raw/plan/pocket-studio-plan.md (immutable from bootstrap onward).

## Summary
The founding plan. Defines the product (record → scrub → chop → transpose → play/export, on the spot), the LLM Wiki working method (raw → wiki → schema; ingest/query/lint), the stack and the M0–M9 roadmap. Its §2 became `CLAUDE.md`; §3–§5 seeded this wiki. The human's answers to its §9 questions are filed as raw/ideas/2026-10-26-*.md.

## Key takeaways
1. Non-destructive by design: recordings immutable, edits are a clip list ([[d003-non-destructive-model]]).
2. Flutter UI + shared C++17 core over `dart:ffi`, miniaudio for I/O, iOS + Android ([[d001-platform-and-stack]]).
3. Transpose/tempo render offline with Signalsmith Stretch, then play ([[d002-pitch-time-library]]).
4. A real-time loop pedal makes round-trip latency a hard M2 go/no-go gate ([[d005-loop-engine]], [[audio-latency]]).
5. Open source under Apache-2.0; every dependency must be permissive ([[d004-licence]]).

## Sources still to collect (§6)
Library docs for Signalsmith Stretch / Rubber Band / SoundTouch; AAudio/Oboe and Apple audio-session latency docs; Laroche & Dolson (1999); Verhelst & Roelands (1993); the human's notes on "on the spot" and favourite loopers; a self-recorded test-sound pack; feedback after each test session.

## Pages touched
[[overview]], [[index]], every feature, concept, component and decision page, [[q-transpose-scope]].
