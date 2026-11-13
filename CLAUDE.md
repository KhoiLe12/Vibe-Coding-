# CLAUDE.md — Pocket Studio wiki maintainer

You maintain two things: the wiki in `wiki/` and the app in `app/`.
The human curates sources, asks questions and makes product calls. You do the bookkeeping.

## Layers
- `raw/` is immutable. Read it; never modify, move or delete anything in it.
- `wiki/` is yours. Create, update, merge and cross-link pages freely.
- `app/` is code. Every non-trivial code change must be reflected in the wiki
  (component page + decision page if a choice was made).

## Page types and frontmatter
Every wiki page starts with YAML frontmatter:
    ---
    type: feature | concept | component | decision | question | source | overview
    status: draft | active | done | superseded | open      # as relevant
    updated: YYYY-MM-DD
    sources: [raw/..., ...]        # raw files this page draws on
    tags: []
    ---
- feature: user story, UX behaviour, acceptance criteria, linked components/concepts.
- concept: explanation, trade-offs, parameters, links to sources.
- component: responsibility, public interface, files in `app/`, dependencies.
- decision: context, options considered, choice, consequences, status.
- question: the question, current best answer, what would settle it.
- source: summary of one raw file, key takeaways, pages it touched.

## Conventions
- Link with [[page-name]]. Every new page gets at least one inbound link.
- Extend, don't duplicate: check index.md and search wiki/ before creating a page.
- Never silently overwrite a claim. If new info contradicts a page, add a
  `## Contradictions` section citing both sources, then resolve with the human.
- Rewrite summaries when they drift; don't just append.
- Cite raw sources inline as (raw/path.md).

## Workflows
### Ingest (one source at a time, human in the loop)
1. Read the source. 2. Tell the human the 3–5 key takeaways and ask what to emphasize.
3. Write `wiki/sources/<slug>.md`. 4. Update every affected feature/concept/component/
decision page. 5. Update `overview.md` if the big picture changed.
6. Update `index.md`. 7. Append to `log.md`.

### Query
1. Read `index.md`. 2. Open relevant pages. 3. Answer with [[links]] and raw citations.
4. If the answer is reusable (comparison, design, analysis), offer to file it in
`wiki/questions/` and do so on a yes. 5. Append to `log.md`.

### Build (after any coding session)
1. Update component pages for touched modules. 2. Record any choice as a decision page.
3. Tick acceptance criteria on feature pages. 4. Append to `log.md`.

### Lint (on request, and at the end of each milestone)
Check: contradictions between pages; decisions that the code no longer matches;
stale claims; orphan pages; concepts mentioned without a page; features without
acceptance criteria; open questions that a source now answers. Suggest sources to find.
Report findings; fix only what the human approves. Append to `log.md`.

## Log format (greppable)
    ## [YYYY-MM-DD] <ingest|query|build|lint|decision> | <title>
    - pages touched: [[a]], [[b]]
    - notes: one or two lines
`grep "^## \[" wiki/log.md | tail -5` shows recent activity.
