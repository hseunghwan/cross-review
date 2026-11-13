---
name: open-code-review-local
description: >
  Runs AI code review on Git changes with NO separate LLM API key, using the
  deterministic `ocr core` command group as building blocks and Claude Code
  itself (your subscription) as the review brain. Follows the v1.13.8
  `ocr review` pipeline: file grouping, plan phase, multi-round main review
  and a default-on isolated REVIEW_FILTER pass. Use when the user asks to
  review code / a PR / staged changes without configuring an Anthropic or
  OpenAI key — i.e. on a Claude Code subscription login. For the full LLM
  binary path (`ocr review`), use the `open-code-review` skill instead.
license: Apache-2.0
compatibility: >
  Requires an `ocr` build that carries the `core` command group at v1.13.8 or
  later (`ocr core template` must succeed). The upstream npm/GitHub release
  does NOT ship `core`; use the local fork build (v1.13.8+core). Requires
  Claude Code authenticated via a Pro/Max/Team subscription (OAuth) — this path
  does not read or need ANTHROPIC_API_KEY. Intended for local, interactive use.
  Parity with `ocr review` is not benchmarked; treat results as best-effort.
metadata:
  author: alibaba (core fork)
  homepage: https://github.com/alibaba/open-code-review
  version: "0.3.0"
  engine: "v1.13.8"
---

# Open Code Review (Local / No-API-Key)

Run [open-code-review](https://github.com/alibaba/open-code-review)-style code
review **without a separate model API key**. `ocr core` performs every
deterministic step of `ocr review` — file selection, grouping decisions, prompt
rendering with all placeholders filled, line relocation, output formatting —
and makes **zero LLM/network calls**. Claude Code, on your subscription,
supplies the reasoning. `ocr` is the machine, you are the brain.

> **Data notice.** This skill reads your local source and diffs into the Claude
> Code context (your Anthropic subscription). On confidential or NDA-covered
> code, confirm your organization's data-handling policy first.

> **Scope.** Local, interactive use. Unattended CI use is out of scope.

## Phase reference

| Phase | When | `ocr core` building block | Who answers |
|-------|------|---------------------------|-------------|
| Diff | always | `ocr core diff` | — |
| Grouping | ≥ `grouping_min_files` reviewable files | `ocr core group` (→ prompt → `--response-file`) | orchestrator (file list only) |
| Plan | per group, `plan_required: true` | `ocr core render plan` | group subagent, no tools |
| Main | per group, up to `max_review_rounds` rounds | `ocr core render main` (+ `--plan-file`, `--confirmed-file`) | fresh group subagent per round |
| Relocate | per comment | `ocr core relocate` → `ocr core prompt relocation` fallback | group subagent |
| REVIEW_FILTER | after every round, **default on** | `ocr core render filter` | isolated diff-only subagent |
| Emit | optional | `ocr core emit` | — |

## Prerequisites check

```bash
ocr core template >/dev/null 2>&1 || echo "ocr core (v1.13.8+core) NOT AVAILABLE — install the fork build"
ocr --version
```

`ocr core template` prints the thresholds this run must follow. **Read them
from that output; never hardcode them.** Fields: `plan_mode_line_threshold`,
`plan_mode_group_line_threshold`, `grouping_min_files`,
`grouping_bundle_line_threshold`, `max_review_rounds`, `max_files_per_group`,
`confirmed_cap`, `main_task_tools`, `filter_tools`. `--effort low|medium|high`
changes `max_review_rounds` (1 / 2 / 3; default medium = 2), matching
`ocr review --effort`.

## Working conventions

- Shell variables do not survive between Bash calls. Create one run directory
  (`mktemp -d`), print it, and substitute its literal path in later commands.
- Pass the **same diff flags** (`--repo`, `--from/--to` or `--commit`,
  `--exclude`, `--rule`) to every `diff`, `group` and `render` call so all steps
  see one change set.
- All `ocr core` output is JSON on stdout (except `rule`, which prints text).

## Workflow

### Step 1: Review targets

| User says | Diff flags |
|-----------|-----------|
| "review my changes" (default) | *(none — workspace: staged + unstaged + untracked)* |
| "review this branch" | `--from <base> --to <branch>` |
| "review commit abc123" | `--commit abc123` |

```bash
ocr core diff --repo . <diff flags>
```

Output: `mode`, `merge_base`, `total_files`, `reviewable_count`,
`excluded_count`, and `files[]`. Each reviewable entry (`will_review: true`)
carries `diff`, `new_file_content`, `hunks`, `changed_lines`. Excluded entries
carry `exclude_reason`: `binary`, `unsupported_ext`, `default_path`, `deleted`,
`large_diff`, `user_exclude` (rule.json / `--exclude`), `secret_exclude`,
`provider_directory`. Skip excluded entries silently. The selection is the one
`ocr review --preview` makes, **including** the repo's `.opencodereview/rule.json`
include/exclude patterns.

**GitLab MR / GitHub PR:** `glab mr checkout <id>` (or `gh pr checkout <id>`),
read the target branch (`glab mr view <id>` / `gh pr view <id> --json baseRefName`),
then use `--from <target> --to HEAD`.

### Step 2: Grouping

```bash
ocr core group --repo . <diff flags>
```

- `needs_answer: false` → `groups[]` is final (`strategy` is `per_file` or
  `bundle_all`: a small change set bundled into one group).
- `needs_answer: true` (`strategy: llm`) → `messages[]` is the grouping prompt.
  Answer it yourself (it contains only an indexed file list) with the JSON array
  it asks for, write the raw answer to `<run>/grouping.txt`, then:

  ```bash
  ocr core group --repo . <diff flags> --response-file <run>/grouping.txt
  ```

  The CLI applies the review's own post-processing (unassigned files become
  single groups, `max_files_per_group` split, token-budget split).

Each group: `label`, `key`, `files[]`, `total_changed`, `max_file_changed`,
`plan_required`. Deleted files never appear in groups.

### Step 3: Review each group (plan + rounds + filter)

Run groups concurrently, ≈3–5 at a time (subscription usage is the limit;
lower it when many groups have `plan_required`). Subagents cannot spawn
subagents, so **the orchestrator drives the round loop** and dispatches each
round and each filter pass as its own subagent.

**Failure isolation.** If a group's subagent fails (tool error, timeout, usage
limit), keep going with the other groups. Record a skipped-group record
`{files, reason}` separately from comments; it appears only in the coverage
line, never in comments or `emit`. A round ≥ 2 that fails keeps the earlier
rounds' findings (like `ocr review`).

For each group, with `confirmed = []`:

**Round 1, plan (only when `plan_required`).** In the round-1 subagent, first:

```bash
ocr core render plan --repo . <diff flags> --files <comma-separated group files>
```

Answer the rendered `messages` as one completion **without using tools** (the
prompt's `{{plan_tools}}` list is already filled; it names the tools the main
review will have). Write the answer verbatim to `<run>/<group>/plan.txt`.

**Round r (1 … `max_review_rounds`).** A fresh subagent per round runs:

```bash
ocr core render main --repo . <diff flags> --files <group files> \
  [--plan-file <run>/<group>/plan.txt]        # round 1 only
  [--confirmed-file <run>/<group>/confirmed.json]  # round ≥ 2 only
```

The output has `messages` (system + user, every placeholder filled: other
changed files, `<review_files>` diffs, merged rules, plan, prior confirmed
findings) and `tools` (the main-task tool schemas). Treat `messages` as the
review directive. Map the engine tools to yours:

| Engine tool | Use |
|-------------|-----|
| `file_read` | `Read` |
| `code_search` | `Grep` |
| `file_find` | `Glob` |
| `file_read_diff` | the file's `diff` from Step 1, or `git diff <merge_base>..<to> -- <path>` |
| `code_comment` | emit a comment object (below) |
| `task_done` | finish the round |

Focus on added/modified lines. Every finding is one comment with the
`code_comment` item schema — **all of** `path`, `content`, `existing_code`,
`category` (`bug|security|performance|maintainability|test|style|documentation|other`),
`severity` (`critical|high|medium|low`), plus optional `suggestion_code`.
Never put findings only in prose. `existing_code` must be copied verbatim from
added (`+`) or context lines — never from a deleted (`-`) line.

**Relocate** each comment (deterministic first):

```bash
echo '{"diff":"<file diff>","new_file_content":"<content>","comment":{"content":"<text>","existing_code":"<snippet>"}}' \
  | ocr core relocate        # → {"start_line","end_line","matched"}
```

- `matched: false` → try the same snippet against the **other files of the
  group**; if exactly one file matches, move the comment there (path and lines
  together), like the engine's cross-file relocation. Zero or several matches:
  keep it on its own path.
- Still unmatched → `ocr core prompt relocation` (placeholders `{diff}`,
  `{existing_code}`, `{suggestion_content}`), produce one fenced block copied
  verbatim from the diff, re-run `relocate`. Still unmatched → keep the comment
  with `start_line: 0, end_line: 0`. Never invent line numbers.

The round subagent returns its comments (with lines) as a JSON array.

**REVIEW_FILTER (default on; skip only if the user opts out, e.g. "no filter",
matching `ocr review --no-filter`).** After every round with at least one new
comment, write **only this round's new comments** to
`<run>/<group>/round<r>.json` and render:

```bash
ocr core render filter --repo . <diff flags> --files <group files> \
  --comments-file <run>/<group>/round<r>.json
```

Dispatch a **fresh, isolated subagent** and give it **only** the rendered
`messages`, the `tools` schemas and the instruction: do not open, read, search
or `git`-inspect anything; judge solely from the text given. It must answer
with exactly one tool-shaped JSON object:

- `{"tool":"report_incorrect_comments","analysis":["c-0: …", …],"comment_ids":["c-1"]}` —
  `analysis` covers **every** candidate first (protected-subject veto, value
  veto, the exact refuting diff line), and only ids concluded removable there
  may appear in `comment_ids`; or
- `{"tool":"approve_all_comments"}`.

Candidate `c-i` is the i-th comment of the file (`comment_ids` in the render
output lists them). Drop the reported ids; keep the rest. The filter can only
**falsify** using the diff; anything merely unverifiable stays. A comment
grounded in context the diff does not show is preserved by design.

**Round bookkeeping.** `confirmed += surviving new comments`; write `confirmed`
to `<run>/<group>/confirmed.json`. Stop the group when the round added no new
surviving comment, when `len(confirmed) >= confirmed_cap`, or after
`max_review_rounds`. Round ≥ 2 subagents get **no plan**, only the confirmed
block (the render handles both).

### Step 4: Report (and optionally emit)

Collect every group's `confirmed` comments. Report by the comments' own
`severity` (critical → high → medium → low) with `category`:

```markdown
## Code Review Results

**Files reviewed**: 4 of 5 in 3 groups (1 skipped: `src/api.go` — timeout)
**Issues found**: 1 critical / 2 high / 3 medium / 1 low

### Critical
- **`path/to/file.go:42`** [security] — Brief description
  > Recommendation: how to fix
```

Coverage counts files whose groups **completed**; list skipped files with the
reason.

Machine-readable output, same contract as `ocr review --format json`
(`status`, `message`, `tool_calls`, `comments` with `severity`/`category`,
optional `groups`):

```bash
echo '{"comments":[…],"groups":[{"label":"…","files":["…"]}]}' | ocr core emit
```

### Step 5: Fix (only if asked)

If the user asked to "review and fix", apply critical/high fixes directly,
describe medium fixes, skip low unless trivial, and confirm with the user before
committing.

## Command reference

| Command | Purpose |
|---------|---------|
| `ocr core diff` | Change set with the review's selection verdicts, diffs, hunks |
| `ocr core group [--response-file f]` | Grouping prompt or final groups (+ `plan_required`) |
| `ocr core render plan\|main\|filter --files …` | Fully rendered phase prompt for one group |
| `ocr core relocate` | Deterministic line pinning (stdin JSON) |
| `ocr core emit` | Wrap comments in the `ocr review` JSON contract (stdin JSON) |
| `ocr core rule <path>` | Resolved review rule text for a path |
| `ocr core prompt <phase>` | Raw prompt template (`main\|plan\|filter\|relocation\|grouping\|memory_compression`) |
| `ocr core tools main\|plan\|filter` | Tool schemas a phase offers the model |
| `ocr core template [--effort]` | Thresholds and limits |

`render` flags: `--files` (required), `--plan-file`, `--confirmed-file`,
`--comments-file`, `--background/-b`, `--date "YYYY-MM-DD HH:MM"`.
`diff`/`group`/`render` flags: `--repo`, `--from`, `--to`, `--commit/-c`,
`--rule`, `--exclude`, `--max-tokens`, `--max-git-procs`.

## Gotchas

- **`ocr core` never calls an LLM.** Every step that needs judgment is yours or
  a subagent's.
- **The filter subagent must stay blind.** If it can read files it starts
  rescuing false positives instead of vetoing them (KTD7).
- **Do not hand-fill placeholders.** Use `ocr core render`; raw `prompt`
  output still contains `{{diffs}}`, `{{system_rule}}`, `{{change_files}}`,
  `{{plan_guidance}}`, `{{confirmed_comments}}`, `{{requirement_background}}`,
  `{{current_system_date_time}}`, `{{plan_tools}}`, `{{file_list}}`,
  `{{diff}}`, `{{comments}}`, `{{path}}`, and relocation's `{diff}`,
  `{existing_code}`, `{suggestion_content}`.
- **One change set per run.** Workspace mode reads the live tree; if files
  change mid-run, later `render` calls see different diffs. For a stable view
  use `--from <base> --to <snapshot-commit>`.
- **Comment language follows your output.** Report in the user's language.

## Known limitations

- `relocate` returns old-file line numbers when `existing_code` only matches a
  deleted line (no side marker); quote added or context lines.
- `diff` keeps the historical `large_diff` spelling for what the engine calls
  `too_large`.
- Memory compression and token budgets are not reproduced; Claude Code manages
  its own context.
- Parity with `ocr review` is unbenchmarked.

## References

- Full docs: https://github.com/alibaba/open-code-review
- LLM-binary path: the `open-code-review` skill (`ocr review` + a model key or
  `anthropic-oauth`)
