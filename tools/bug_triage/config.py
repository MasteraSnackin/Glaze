"""Central config: everything comes from env vars (GitHub Secrets in CI).

Nothing here has a real default for a secret — a missing secret raises loudly
so a misconfigured workflow fails fast instead of silently doing nothing.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


def _require(name: str) -> str:
    val = os.environ.get(name, "").strip()
    if not val:
        raise SystemExit(f"[config] missing required env var: {name}")
    return val


def _optional(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _csv(name: str) -> tuple[str, ...]:
    raw = _optional(name)
    return tuple(x.strip() for x in raw.split(",") if x.strip())


def _audit_lists() -> tuple[str, ...]:
    """Lists whose cards may be audited (comma-separated ids).

    Falls back to the new-bug list alone, which is the intended scope: the AI
    must never comment on unrelated cards elsewhere on the board.
    """
    raw = _optional("TRELLO_AUDIT_LIST_IDS")
    if raw:
        return tuple(x.strip() for x in raw.split(",") if x.strip())
    return (_require("TRELLO_NEW_BUG_LIST_ID"),)


@dataclass(frozen=True)
class Config:
    # --- DeepSeek (OpenAI-compatible) ---
    deepseek_api_key: str
    deepseek_base_url: str
    deepseek_model: str

    # --- Trello ---
    trello_key: str
    trello_token: str
    trello_board_id: str
    trello_new_bug_list_id: str  # where freshly-discovered bugs land
    trello_audited_label_id: str  # label meaning "AI already audited this"
    # Only cards in these lists are ever audited. Defaults to the new-bug list,
    # so the rest of the board is never touched.
    trello_audit_list_ids: tuple[str, ...]

    # --- Discord ---
    discord_bot_token: str
    discord_guild_id: str
    discord_forum_channel_id: str
    # Forum tag ids that mean "closed" (e.g. Solved / Duplicate / Won't fix).
    discord_ignored_tag_ids: tuple[str, ...]
    # Closed forum posts show up as archived, so they are skipped like locked
    # ones. Set DISCORD_SKIP_ARCHIVED=false to also triage auto-archived posts.
    discord_skip_archived: bool

    # --- Behaviour ---
    dry_run: bool  # if true: don't create cards / post comments, just log
    # Per-run ceilings so a first run over a long-lived forum can't flood the
    # board or the token budget in one go. 0 = unlimited.
    max_new_cards_per_run: int
    max_audits_per_run: int

    @staticmethod
    def load() -> "Config":
        return Config(
            deepseek_api_key=_require("DEEPSEEK_API_KEY"),
            deepseek_base_url=_optional("DEEPSEEK_BASE_URL", "https://api.deepseek.com"),
            deepseek_model=_optional("DEEPSEEK_MODEL", "deepseek-chat"),
            trello_key=_require("TRELLO_KEY"),
            trello_token=_require("TRELLO_TOKEN"),
            trello_board_id=_require("TRELLO_BOARD_ID"),
            trello_new_bug_list_id=_require("TRELLO_NEW_BUG_LIST_ID"),
            trello_audited_label_id=_require("TRELLO_AUDITED_LABEL_ID"),
            trello_audit_list_ids=_audit_lists(),
            discord_bot_token=_require("DISCORD_BOT_TOKEN"),
            discord_guild_id=_require("DISCORD_GUILD_ID"),
            discord_forum_channel_id=_require("DISCORD_FORUM_CHANNEL_ID"),
            discord_ignored_tag_ids=_csv("DISCORD_IGNORED_TAG_IDS"),
            discord_skip_archived=_optional("DISCORD_SKIP_ARCHIVED", "true").lower()
            in ("1", "true", "yes"),
            dry_run=_optional("DRY_RUN", "false").lower() in ("1", "true", "yes"),
            max_new_cards_per_run=int(_optional("MAX_NEW_CARDS_PER_RUN", "25")),
            max_audits_per_run=int(_optional("MAX_AUDITS_PER_RUN", "15")),
        )
