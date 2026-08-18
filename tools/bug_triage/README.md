# Bug-triage agent

A daily, **read-only** agent that keeps the Trello board in sync with the Discord
bug-report forum and drops an AI audit on each open bug. It **never** changes
code or opens PRs — it only creates Trello cards and posts comments for a human
to act on.

## What it does (once per day)

1. Fetches Discord forum posts (active + archived-public threads) via the REST
   API — no persistent gateway connection.
2. Fetches all Trello cards from the main board.
3. For any Discord post **not yet on the board**, creates a card in the "new
   bugs" list, with a back-link to the Discord thread in the description.
4. If nothing needs auditing, **exits before calling the LLM** (no token spend).
5. For each card without the `audited` label, runs a DeepSeek agent that greps /
   reads the checked-out source, then posts a structured audit as a comment and
   applies the `audited` label.

De-dup has no external database: each mirrored card carries a hidden
`discord-thread:<id>` marker in its description, and that's the source of truth.

## Architecture

Only the **audit** step is agentic (DeepSeek + `search_code`/`read_file` tools,
via Pydantic AI). Polling, card creation and de-dup are plain deterministic code
— cheaper and more reliable than handing those to the model.

```
triage.py         orchestrator + early-exit
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

Daily at 06:00 UTC (`.github/workflows/bug-triage.yml`). Trigger manually from
the Actions tab ("Run workflow"), optionally with **dry run** checked.
