"""Orchestrator. Runs once per invocation (the workflow schedules it daily).

Discord is the only work queue: the run walks the open forum threads and uses
Trello purely to cross-check them. The board is never scanned for work of its
own, so a card written by hand — anywhere on the board, in any list — is never
picked up, commented on or labelled by this agent.

Flow (only the audit step touches the LLM):
  1. Pull the open Discord forum posts.
  2. Pull Trello cards ONCE, to index them by their `discord-thread:<id>`
     marker. That index answers two questions per thread and nothing else:
     does it already have a card, and was that card already audited?
  3. Any thread with no matching card -> check whether a human already wrote
     a card for that same bug (matcher.py, one DeepSeek call over the cards
     that carry no marker yet). On a hit, write the marker + back-link into
     that card; otherwise create a new card.
  4. EARLY EXIT: if every thread already carries the audited label, stop
     before the (far more expensive) audit agent is ever built. A run with no
     new threads and nothing to audit spends zero tokens.
  5. For each remaining thread: run the agent on that ONE report (title +
     post + replies, read live from Discord), post the result as a comment on
     its card, then apply the "audited" label.

Nothing here ever modifies source code or opens a PR.
"""

from __future__ import annotations

import sys
from dataclasses import replace

from auditor import build_agent, format_comment
from config import Config
from discord_client import DiscordClient, ForumPost
from matcher import build_matcher, find_existing_card
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


def _linked_desc(card: Card, post: ForumPost) -> str:
    """A human-written card's description with the Discord link glued on.

    Only the footer is appended — whatever a human typed stays untouched, so
    linking a card can never destroy the report they wrote.
    """
    return (
        f"{card.desc.rstrip()}\n\n---\n"
        f"Also reported on Discord: {post.url}\n"
        f"{marker_for(post.thread_id)}"
    )


def _report_text(post: ForumPost) -> str:
    """The human-written part of a thread — what the auditor has to read."""
    return "\n".join([post.body, *post.replies]).strip()


def _unreadable_comment(source_url: str) -> str:
    return (
        f"⚠️ **NEED MORE INFO** — this report carries no readable "
        f"text.\nSource: {source_url}\n\n"
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

    # --- Step 1+2: the forum is the queue, the board is only the cross-check --
    posts = discord.fetch_posts()
    cards = trello.fetch_cards()
    by_thread: dict[str, Card] = {
        c.discord_thread_id: c for c in cards if c.discord_thread_id
    }
    print(f"[triage] discord posts={len(posts)} trello cards={len(cards)} "
          f"already-linked-threads={len(by_thread)}")

    # --- Step 3: mirror new Discord posts into Trello -----------------------
    new_posts = [p for p in posts if p.thread_id not in by_thread]
    if cfg.max_new_cards_per_run and len(new_posts) > cfg.max_new_cards_per_run:
        print(f"[triage] {len(new_posts)} new thread(s); capped to "
              f"{cfg.max_new_cards_per_run} this run (MAX_NEW_CARDS_PER_RUN)")
        new_posts = new_posts[: cfg.max_new_cards_per_run]

    # Cards a human wrote by hand: candidates for "this bug is already on the
    # board". A card claimed by one thread drops out for the rest of the run.
    unlinked = [c for c in cards if not c.discord_thread_id]
    matcher = None  # built lazily: no new threads -> no lookup, no tokens

    for post in new_posts:
        hit = None
        if cfg.match_existing_cards and unlinked:
            if matcher is None:
                matcher = build_matcher(
                    cfg.deepseek_api_key, cfg.deepseek_base_url, cfg.deepseek_model
                )
            hit = find_existing_card(
                matcher, post, unlinked, cfg.max_match_candidates
            )

        if hit is not None:
            desc = _linked_desc(hit, post)
            trello.set_desc(hit.id, desc)
            print(f"[triage] linked thread {post.thread_id} to existing card "
                  f"{hit.id}: {hit.name!r} (no duplicate created)")
            by_thread[post.thread_id] = replace(hit, desc=desc)
            unlinked.remove(hit)
            continue

        body = _card_body(post)
        new_id = trello.create_card(cfg.trello_new_bug_list_id, post.title, body)
        print(f"[triage] created card for thread {post.thread_id}: {post.title!r}")
        by_thread[post.thread_id] = Card(
            id=new_id,
            name=post.title,
            desc=body,
            list_id=cfg.trello_new_bug_list_id,
            label_ids=(),
        )

    # --- Step 4: which threads still need an audit? -------------------------
    # Driven by the forum, never by the board: a thread is a candidate only if
    # its own card is missing the audited label. Threads whose card creation was
    # capped above simply wait for the next run.
    to_audit: list[tuple[ForumPost, Card]] = [
        (p, by_thread[p.thread_id])
        for p in posts
        if p.thread_id in by_thread
        and cfg.trello_audited_label_id not in by_thread[p.thread_id].label_ids
    ]

    # --- Step 5: early exit before spending any tokens ---------------------
    if not to_audit:
        print("[triage] nothing new to audit — exiting before LLM.")
        return 0

    if cfg.max_audits_per_run and len(to_audit) > cfg.max_audits_per_run:
        print(f"[triage] {len(to_audit)} thread(s) pending; auditing "
              f"{cfg.max_audits_per_run} this run (MAX_AUDITS_PER_RUN)")
        to_audit = to_audit[: cfg.max_audits_per_run]

    agent = None  # built lazily: unreadable-only batches never need the LLM
    failures = 0

    for post, card in to_audit:
        # Cheap path: nothing to read -> ask a human, don't call DeepSeek.
        if len(_report_text(post)) < _MIN_REPORT_CHARS:
            trello.add_comment(card.id, _unreadable_comment(post.url))
            trello.add_label(card.id, cfg.trello_audited_label_id)
            print(f"[triage] NEED MORE INFO (no text) for thread {post.thread_id}")
            continue

        if agent is None:
            print(f"[triage] using model {cfg.deepseek_model}")
            agent = build_agent(
                cfg.deepseek_api_key, cfg.deepseek_base_url, cfg.deepseek_model
            )

        # Read from the thread, not from the card: replies posted after the
        # card was mirrored are part of the report the agent sees.
        prompt = f"Bug title: {post.title}\n\nBug report:\n{_card_body(post)}"
        try:
            result = agent.run_sync(prompt)
        except Exception as e:  # noqa: BLE001 — one bad thread must not sink the run
            print(f"[triage] audit FAILED for thread {post.thread_id}: {e}",
                  file=sys.stderr)
            failures += 1
            continue

        trello.add_comment(card.id, format_comment(result.output, post.url))
        trello.add_label(card.id, cfg.trello_audited_label_id)
        flag = " [NEED MORE INFO]" if result.output.needs_more_info else ""
        print(f"[triage] audited thread {post.thread_id}: {post.title!r}{flag}")

    if failures:
        print(f"[triage] completed with {failures} audit failure(s).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
