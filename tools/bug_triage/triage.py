"""Orchestrator. Runs once per invocation (the workflow schedules it daily).

Flow (only the audit step touches the LLM):
  1. Pull Discord forum posts + Trello cards.
  2. Any Discord post with no matching card  -> create a card (with back-link).
  3. Collect cards that are in an audited list and still lack the label.
  4. EARLY EXIT: if nothing needs auditing, stop before calling DeepSeek.
  5. For each such card: run the agent on that ONE report (title + post +
     replies), post the result as a comment, then apply the "audited" label.

Nothing here ever modifies source code or opens a PR.
"""

from __future__ import annotations

import sys

from auditor import build_agent, format_comment
from config import Config
from discord_client import DiscordClient, ForumPost
from trello_client import Card, TrelloClient, marker_for

# Below this much readable text a report cannot be audited at all, so we skip
# the LLM entirely and ask a human for details instead of burning tokens.
_MIN_REPORT_CHARS = 15


def _card_body(post: ForumPost) -> str:
    """Title/body/replies of one thread, plus the de-dup marker footer."""
    parts = [post.body.strip() or "(no text in the original post)"]

    if post.replies:
        parts.append("**Replies from the thread:**")
        parts.extend(f"- {r}" for r in post.replies)

    footer = ["---"]
    if post.attachment_count:
        footer.append(
            f"Attachments: {post.attachment_count} — images are NOT readable by "
            f"the triage agent."
        )
    footer.append(f"Reported on Discord: {post.url}")
    footer.append(marker_for(post.thread_id))

    return "\n\n".join(parts) + "\n\n" + "\n".join(footer)


def _report_text(desc: str) -> str:
    """The human-written part of a card description (footer stripped)."""
    return desc.split("\n---\n", 1)[0].replace(
        "(no text in the original post)", ""
    ).strip()


def _unreadable_comment(card: Card, source_url: str | None) -> str:
    src = f"\nSource: {source_url}" if source_url else ""
    return (
        f"\u26a0\ufe0f **NEED MORE INFO** \u2014 this report carries no readable "
        f"text.{src}\n\n"
        f"It looks like screenshots or attachments only. Please add: what you "
        f"did, what you expected, and what happened instead.\n\n"
        f"*(No audit was performed. Nothing was changed.)*"
    )


def main() -> int:
    cfg = Config.load()

    discord = DiscordClient(
        cfg.discord_bot_token,
        cfg.discord_guild_id,
        cfg.discord_forum_channel_id,
        ignored_tag_ids=cfg.discord_ignored_tag_ids,
        skip_archived=cfg.discord_skip_archived,
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
    new_posts = [p for p in posts if p.thread_id not in known_threads]
    if cfg.max_new_cards_per_run and len(new_posts) > cfg.max_new_cards_per_run:
        print(f"[triage] {len(new_posts)} new thread(s); capped to "
              f"{cfg.max_new_cards_per_run} this run (MAX_NEW_CARDS_PER_RUN)")
        new_posts = new_posts[: cfg.max_new_cards_per_run]

    created: list[Card] = []
    for post in new_posts:
        body = _card_body(post)
        new_id = trello.create_card(cfg.trello_new_bug_list_id, post.title, body)
        print(f"[triage] created card for thread {post.thread_id}: {post.title!r}")
        created.append(
            Card(
                id=new_id,
                name=post.title,
                desc=body,
                list_id=cfg.trello_new_bug_list_id,
                label_ids=(),
            )
        )

    # --- Step 3: which cards may be audited? --------------------------------
    # Scope is deliberately narrow: only the configured bug list(s), never the
    # whole board, so the agent can't comment on unrelated cards.
    to_audit = [
        c for c in (cards + created)
        if c.list_id in cfg.trello_audit_list_ids
        and cfg.trello_audited_label_id not in c.label_ids
    ]

    # --- Step 4: early exit before spending any tokens ---------------------
    if not to_audit:
        print("[triage] nothing new to audit — exiting before LLM.")
        return 0

    if cfg.max_audits_per_run and len(to_audit) > cfg.max_audits_per_run:
        print(f"[triage] {len(to_audit)} card(s) pending; auditing "
              f"{cfg.max_audits_per_run} this run (MAX_AUDITS_PER_RUN)")
        to_audit = to_audit[: cfg.max_audits_per_run]

    agent = None  # built lazily: unreadable-only batches never need the LLM
    failures = 0

    for card in to_audit:
        source_url = None
        if card.discord_thread_id:
            source_url = (
                f"https://discord.com/channels/{cfg.discord_guild_id}/"
                f"{card.discord_thread_id}"
            )

        # Cheap path: nothing to read -> ask a human, don't call DeepSeek.
        if len(_report_text(card.desc)) < _MIN_REPORT_CHARS:
            trello.add_comment(card.id, _unreadable_comment(card, source_url))
            trello.add_label(card.id, cfg.trello_audited_label_id)
            print(f"[triage] NEED MORE INFO (no text) for card {card.id}")
            continue

        if agent is None:
            print(f"[triage] using model {cfg.deepseek_model}")
            agent = build_agent(
                cfg.deepseek_api_key, cfg.deepseek_base_url, cfg.deepseek_model
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
        flag = " [NEED MORE INFO]" if result.output.needs_more_info else ""
        print(f"[triage] audited card {card.id}: {card.name!r}{flag}")

    if failures:
        print(f"[triage] completed with {failures} audit failure(s).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
