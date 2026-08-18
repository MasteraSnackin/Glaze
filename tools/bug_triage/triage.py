"""Orchestrator. Runs once per invocation (the workflow schedules it daily).

Flow (only the audit step touches the LLM):
  1. Pull Discord forum posts + Trello cards.
  2. Any Discord post with no matching card  -> create a card (with back-link).
  3. Collect cards that still lack the "audited" label.
  4. EARLY EXIT: if nothing needs auditing, stop before calling DeepSeek.
  5. For each un-audited card: run the agent, post the audit as a comment,
     then apply the "audited" label.

Nothing here ever modifies source code or opens a PR.
"""

from __future__ import annotations

import sys

from auditor import build_agent, format_comment
from config import Config
from discord_client import DiscordClient, ForumPost
from trello_client import Card, TrelloClient, marker_for


def _card_body(post: ForumPost) -> str:
    body = post.body.strip() or "(no text in the Discord post)"
    return (
        f"{body}\n\n"
        f"---\n"
        f"Reported on Discord: {post.url}\n"
        f"{marker_for(post.thread_id)}"
    )


def main() -> int:
    cfg = Config.load()

    discord = DiscordClient(
        cfg.discord_bot_token, cfg.discord_guild_id, cfg.discord_forum_channel_id
    )
    trello = TrelloClient(
        cfg.trello_key, cfg.trello_token, cfg.trello_board_id, dry_run=cfg.dry_run
    )

    posts = discord.fetch_posts()
    cards = trello.fetch_cards()
    known_threads = {c.discord_thread_id for c in cards if c.discord_thread_id}
    print(f"[triage] discord posts={len(posts)} trello cards={len(cards)} "
          f"already-linked-threads={len(known_threads)}")

    # --- Step 2: mirror new Discord posts into Trello -----------------------
    created: list[Card] = []
    for post in posts:
        if post.thread_id in known_threads:
            continue
        new_id = trello.create_card(
            cfg.trello_new_bug_list_id, post.title, _card_body(post)
        )
        print(f"[triage] created card for discord thread {post.thread_id}: {post.title!r}")
        created.append(
            Card(id=new_id, name=post.title, desc=_card_body(post), label_ids=())
        )

    # --- Step 3: which cards still need an AI audit? ------------------------
    to_audit = [
        c for c in (cards + created)
        if cfg.trello_audited_label_id not in c.label_ids
    ]

    # --- Step 4: early exit before spending any tokens ---------------------
    if not to_audit:
        print("[triage] nothing new to audit — exiting before LLM.")
        return 0

    print(f"[triage] auditing {len(to_audit)} card(s) with {cfg.deepseek_model}")
    agent = build_agent(cfg.deepseek_api_key, cfg.deepseek_base_url, cfg.deepseek_model)

    failures = 0
    for card in to_audit:
        source_url = None
        if card.discord_thread_id:
            source_url = (
                f"https://discord.com/channels/{cfg.discord_guild_id}/"
                f"{card.discord_thread_id}"
            )
        prompt = f"Bug title: {card.name}\n\nBug report:\n{card.desc}"
        try:
            result = agent.run_sync(prompt)
        except Exception as e:  # noqa: BLE001 — one bad card must not sink the run
            print(f"[triage] audit FAILED for card {card.id}: {e}", file=sys.stderr)
            failures += 1
            continue

        trello.add_comment(card.id, format_comment(result.output, source_url))
        trello.add_label(card.id, cfg.trello_audited_label_id)
        print(f"[triage] audited card {card.id}: {card.name!r}")

    if failures:
        print(f"[triage] completed with {failures} audit failure(s).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
