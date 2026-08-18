"""Read-only Discord forum access via the REST API (no gateway/socket needed).

A forum channel's "posts" are threads. For every thread we collect the title,
the starter message, and the replies — each thread is audited on its own, so
the whole conversation travels together as one bug report.

Closed posts are skipped. "Closed" is not one flag in Discord, so three cases
are handled separately:
  * locked      — a moderator closed the post. Always skipped.
  * tagged      — forum tags like "Solved"/"Duplicate"; skipped when their ids
                  are listed in DISCORD_IGNORED_TAG_IDS.
  * archived    — often just inactivity, NOT a decision, so kept by default;
                  set DISCORD_SKIP_ARCHIVED=true to treat it as closed too.

Attachments are counted but never downloaded: the auditor cannot see images, so
a report that leans on screenshots is flagged for a human instead of guessed at.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import requests

_API = "https://discord.com/api/v10"

# How many messages of a thread to pull (newest page). Plenty for a bug report.
_MSG_LIMIT = 100
# Replies longer than this are trimmed so one rambling thread can't blow up the
# prompt; the auditor gets the gist, a human still has the Discord link.
_MAX_REPLY_CHARS = 1500


@dataclass(frozen=True)
class ForumPost:
    thread_id: str
    title: str
    body: str
    replies: tuple[str, ...]
    attachment_count: int
    url: str

    @property
    def has_text(self) -> bool:
        return bool(self.body.strip() or any(r.strip() for r in self.replies))


class DiscordClient:
    def __init__(
        self,
        bot_token: str,
        guild_id: str,
        forum_channel_id: str,
        ignored_tag_ids: tuple[str, ...] = (),
        skip_archived: bool = False,
    ):
        self._guild_id = guild_id
        self._forum_channel_id = forum_channel_id
        self._ignored_tags = set(ignored_tag_ids)
        self._skip_archived = skip_archived
        self._s = requests.Session()
        self._s.headers.update(
            {
                "Authorization": f"Bot {bot_token}",
                "User-Agent": "GlazeBugTriage (https://github.com/hydall/Glaze, 1.0)",
            }
        )

    def _get(self, path: str, **params) -> Any:
        r = self._s.get(f"{_API}{path}", params=params or None, timeout=30)
        r.raise_for_status()
        return r.json()

    def available_tags(self) -> list[dict]:
        """Forum tags configured on the channel (id + name), for configuring
        DISCORD_IGNORED_TAG_IDS."""
        ch = self._get(f"/channels/{self._forum_channel_id}")
        return ch.get("available_tags", []) or []

    def _threads(self) -> list[dict]:
        """Active + archived-public threads belonging to the forum channel."""
        by_id: dict[str, dict] = {}

        # Active threads are returned guild-wide; filter by parent channel.
        active = self._get(f"/guilds/{self._guild_id}/threads/active")
        for t in active.get("threads", []):
            if str(t.get("parent_id")) == self._forum_channel_id:
                by_id[str(t["id"])] = t

        # Archived public threads live under the channel itself.
        archived = self._get(
            f"/channels/{self._forum_channel_id}/threads/archived/public"
        )
        for t in archived.get("threads", []):
            by_id.setdefault(str(t["id"]), t)

        return [by_id[k] for k in sorted(by_id)]

    def is_closed(self, thread: dict) -> tuple[bool, str]:
        """(closed?, reason) for one thread object."""
        meta = thread.get("thread_metadata") or {}
        if meta.get("locked"):
            return True, "locked"
        tags = {str(t) for t in (thread.get("applied_tags") or [])}
        hit = tags & self._ignored_tags
        if hit:
            return True, f"tagged {sorted(hit)}"
        if self._skip_archived and meta.get("archived"):
            return True, "archived"
        return False, ""

    @staticmethod
    def _attachment_count(msg: dict) -> int:
        embeds = [e for e in msg.get("embeds", []) if e.get("type") == "image"]
        return len(msg.get("attachments", [])) + len(embeds)

    def _thread_content(self, thread_id: str) -> tuple[str, tuple[str, ...], int]:
        """Return (starter_body, replies, attachment_count) for one thread."""
        msgs: list[dict] = self._get(
            f"/channels/{thread_id}/messages", limit=_MSG_LIMIT
        )
        msgs = list(reversed(msgs))  # API returns newest-first; read chronologically
        if not msgs:
            return "", (), 0

        attachments = sum(self._attachment_count(m) for m in msgs)

        # In a forum thread the starter message shares the thread's id.
        starter = next((m for m in msgs if str(m.get("id")) == thread_id), msgs[0])
        body = (starter.get("content") or "").strip()

        replies: list[str] = []
        for m in msgs:
            if m is starter:
                continue
            text = (m.get("content") or "").strip()
            if not text and not self._attachment_count(m):
                continue  # join/system noise
            author = (m.get("author") or {}).get("username", "unknown")
            if len(text) > _MAX_REPLY_CHARS:
                text = text[:_MAX_REPLY_CHARS] + " …[trimmed]"
            if not text:
                text = "(image/attachment only)"
            replies.append(f"{author}: {text}")

        return body, tuple(replies), attachments

    def fetch_posts(self) -> list[ForumPost]:
        posts: list[ForumPost] = []
        skipped = 0
        for thread in self._threads():
            closed, reason = self.is_closed(thread)
            if closed:
                skipped += 1
                print(f"[discord] skip closed thread {thread.get('id')} ({reason})")
                continue
            tid = str(thread["id"])
            body, replies, attachments = self._thread_content(tid)
            posts.append(
                ForumPost(
                    thread_id=tid,
                    title=(thread.get("name") or "(untitled)").strip(),
                    body=body,
                    replies=replies,
                    attachment_count=attachments,
                    url=f"https://discord.com/channels/{self._guild_id}/{tid}",
                )
            )
        if skipped:
            print(f"[discord] {skipped} closed thread(s) ignored")
        return posts
