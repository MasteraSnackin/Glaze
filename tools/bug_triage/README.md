# Bug-triage agent

A daily, **read-only** agent that keeps the Trello board in sync with the Discord
bug-report forum and drops an AI audit on each open bug. The **Discord forum is
the only work queue**; Trello is consulted purely to cross-check those threads
(has this one a card? was that card already audited?). It **never** changes code
or opens PRs — it only creates Trello cards and posts comments for a human to
act on.

## What it does (once per day)

1. Fetches Discord forum posts (active + archived-public threads) via the REST
   API — no persistent gateway connection. **Closed posts are skipped**: locked
   threads, archived (closed) threads, and posts carrying an ignored forum tag.
   Note Discord also auto-archives inactive posts, so a quiet-but-open report is
   dropped too; set `DISCORD_SKIP_ARCHIVED=false` to triage those as well.
2. Fetches the Trello cards once and indexes them by their
   `discord-thread:<id>` marker. The board is **only a cross-check** for the
   threads found in step 1 — it is never scanned for work of its own, so a card
   written by hand (in any list, anywhere on the board) is never commented on
   or labelled.
3. For any Discord post **not yet on the board**, creates a card in the "new
   bugs" list, with a back-link to the Discord thread in the description.
4. If every open thread already carries the `audited` label, **exits before
   calling the LLM** (no token spend).
5. For each remaining thread, runs a DeepSeek agent over that ONE report —
   title, original post and replies, read live from Discord, so replies added
   after the card was mirrored are included — that greps / reads the
   checked-out source, then posts a structured audit as a comment on the
   thread's card and applies the `audited` label.

Reports that cannot be judged from text (screenshot-only posts, missing repro
steps) get a **NEED MORE INFO** comment naming what to ask instead of a guess.
A post with no readable text at all skips the LLM entirely.

De-dup has no external database: each mirrored card carries a hidden
`discord-thread:<id>` marker in its description, and that's the source of truth.

## Architecture

Only the **audit** step is agentic (DeepSeek + `search_code`/`read_file` tools,
via Pydantic AI). Polling, card creation and de-dup are plain deterministic code
— cheaper and more reliable than handing those to the model.

```
triage.py         orchestrator (Discord-driven) + early-exit
config.py         env-var loading (fails fast on missing secrets)
discord_client.py read-only forum access (REST)
trello_client.py  cards / comments / labels (source of truth)
auditor.py        Pydantic AI agent (DeepSeek) + structured BugAudit output
```

## Secrets & variables (GitHub → Settings)

**Secrets** (`Settings → Secrets and variables → Actions → Secrets`):

| Name | What |
|------|------|
| `DEEPSEEK_API_KEY` | DeepSeek API key |
| `TRELLO_KEY` / `TRELLO_TOKEN` | Trello API key + token |
| `DISCORD_BOT_TOKEN` | Bot token (scope `bot`, perms: Read Messages, Read Message History) |

**Variables** (`… → Variables`) — non-secret IDs:

| Name | What | Default |
|------|------|---------|
| `DEEPSEEK_MODEL` | model id | `deepseek-chat` |
| `TRELLO_BOARD_ID` | main board id | — |
| `TRELLO_NEW_BUG_LIST_ID` | list where new bugs land | — |
| `TRELLO_AUDITED_LABEL_ID` | label id meaning "AI audited" | — |
| `DISCORD_GUILD_ID` | your server id | — |
| `DISCORD_FORUM_CHANNEL_ID` | the bug-report forum channel id | — |
| `DISCORD_IGNORED_TAG_IDS` | forum tag ids meaning closed (comma-separated) | empty |
| `DISCORD_SKIP_ARCHIVED` | treat archived threads as closed | `true` |
| `MAX_NEW_CARDS_PER_RUN` | cap on cards created per run (0 = unlimited) | `25` |
| `MAX_AUDITS_PER_RUN` | cap on DeepSeek audits per run (0 = unlimited) | `15` |

The connection check prints the forum's tag names with their ids, so run it
once and copy the closed/solved tag id into `DISCORD_IGNORED_TAG_IDS`.

Finding IDs:
- Trello: append `.json` to a board URL, or hit
  `https://api.trello.com/1/members/me/boards?key=…&token=…`.
- Discord: enable Developer Mode → right-click → "Copy ID".

## Running locally

```bash
pip install -r requirements.txt
# export all the env vars above, then:
DRY_RUN=true python triage.py   # dry-run: fetches + logs, no writes
```

## Schedule

Daily at 18:00 UTC (`.github/workflows/bug-triage.yml`). Trigger manually from
the Actions tab ("Run workflow"), optionally with **dry run** checked.

> **Scheduled runs only fire from the repository's default branch** (`stable`).
> On `nightly` or a feature branch the cron is inert — only `workflow_dispatch`
> works there. The daily 18:00 UTC run starts once this file reaches `stable`
> through the normal `nightly` → `staging` → `stable` promotion.
