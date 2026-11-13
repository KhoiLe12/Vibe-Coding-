#!/usr/bin/env python3
# Copyright 2026 The Pocket Studio Authors
# SPDX-License-Identifier: Apache-2.0
"""Mechanical half of the wiki lint (CLAUDE.md, "Lint").

Checks what a script can: frontmatter, broken [[links]], orphan pages, feature
pages without acceptance criteria, component pages pointing at missing app/
files, raw citations that don't exist, and vendored code missing from
THIRD_PARTY_NOTICES.md. Judgement calls (contradictions, stale claims) stay
with the agent and the human. Exits 1 on errors; warnings don't fail.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WIKI = ROOT / "wiki"
TYPES = {"feature", "concept", "component", "decision", "question", "source", "overview"}
NAV = {"index", "log"}  # navigation files: no frontmatter

LINK = re.compile(r"\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]")
RAW_CITE = re.compile(r"\braw/[\w./-]+\.md\b")
APP_PATH = re.compile(r"`(app/[^`\s]+)`")

errors, warnings = [], []


def frontmatter(text):
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---\n", 4)
    if end < 0:
        return None
    fields = {}
    for line in text[4:end].splitlines():
        if ":" in line and not line.startswith(" "):
            key, _, value = line.partition(":")
            fields[key.strip()] = value.split("#")[0].strip()
    return fields


pages = {p.stem: p for p in WIKI.rglob("*.md")}
inbound = {name: 0 for name in pages}

for name, path in sorted(pages.items()):
    rel = path.relative_to(ROOT)
    text = path.read_text(encoding="utf-8")

    for target in LINK.findall(text):
        target = target.strip()
        if target not in pages:
            errors.append(f"{rel}: broken link [[{target}]]")
        elif target != name:
            inbound[target] += 1

    for cite in set(RAW_CITE.findall(text)):
        if not (ROOT / cite).exists():
            errors.append(f"{rel}: cites missing raw file {cite}")

    if name in NAV:
        continue
    fm = frontmatter(text)
    if fm is None:
        errors.append(f"{rel}: missing YAML frontmatter")
        continue
    for key in ("type", "status", "updated", "sources", "tags"):
        if key not in fm:
            errors.append(f"{rel}: frontmatter lacks '{key}'")
    page_type = fm.get("type")
    if page_type not in TYPES:
        errors.append(f"{rel}: unknown type '{page_type}'")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", fm.get("updated", "")):
        errors.append(f"{rel}: 'updated' is not YYYY-MM-DD")

    if page_type == "feature":
        section = re.search(r"^## Acceptance criteria\n(.*?)(?=^## |\Z)", text, re.S | re.M)
        if not section:
            errors.append(f"{rel}: no '## Acceptance criteria' section")
        elif not re.search(r"^- \[[ x~]\]", section.group(1), re.M):
            warnings.append(f"{rel}: acceptance criteria not defined yet")

    if page_type == "component":
        for app_path in APP_PATH.findall(text):
            if not (ROOT / app_path.rstrip("/")).exists():
                errors.append(f"{rel}: lists {app_path}, which does not exist")

for name, count in sorted(inbound.items()):
    if count == 0 and name not in NAV:
        errors.append(f"wiki/.../{name}.md: orphan page (no inbound [[link]])")

notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8").lower()
for vendored in sorted(ROOT.glob("app/packages/*/src/third_party/*/")):
    if vendored.name.lower() not in notices:
        errors.append(f"THIRD_PARTY_NOTICES.md: does not list vendored {vendored.relative_to(ROOT)}")

for w in warnings:
    print(f"warning: {w}")
for e in errors:
    print(f"error: {e}")
print(f"wiki lint: {len(pages)} pages, {len(errors)} errors, {len(warnings)} warnings")
sys.exit(1 if errors else 0)
