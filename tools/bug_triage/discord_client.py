"""Read-only Discord forum access via the REST API (no gateway/socket needed).

A forum channel's "posts" are threads. We collect both the currently-active
threads and the recently-archived public ones, then read each thread's starter
message for the bug body.
"""

from __future__ import annotations

from dataclasses import dataclass

import requests

_API = "https://discord.com/api/v10"


@dataclass(frozen=True)
class ForumPost:
    thread_id: str
    title: str
    body: str
    url: str


class DiscordClient:
    def __init__(self, bot_token: str, guild_id: str, forum_channel_id: str):
        self._guild_id = guild_id
        self._forum_channel_id = forum_channel_id
        self._s = requests.Session()
        self._s.headers.update(
            {
                "Authorization": f"Bot {bot_token}",
                "User-Agent": "GlazeBugTriage (https://github.com/hydall/Glaze, 1.0)",
            }
        )

    def _get(self, path: str, **params) -> dict:
        r = self._s.get(f"{_API}{path}", params=params or None, timeout=30)
        r.raise_for_status()
        return r.json()

    def _thread_ids(self) -> list[str]:
        """Active + archived-public threads that belong to the forum channel."""
        ids: set[str] = set()

        # Active threads are returned guild-wide; filter by parent channel.
        active = self._get(f"/guilds/{self._guild_id}/threads/active")
        for t in active.get("threads", []):
            if str(t.get("parent_id")) == self._forum_channel_id:
                ids.add(str(t["id"]))

        # Archived public threads live under the channel itself.
        archived = self._get(
            f"/channels/{self._forum_channel_id}/threads/archived/public"
        )
        for t in archived.get("threads", []):
            ids.add(str(t["id"]))

        return sorted(ids)

    def _starter_message(self, thread_id: str) -> str:
        # In a forum thread the starter message shares the thread id.
        try:
            msg = self._get(f"/channels/{thread_id}/messages/{thread_id}")
            return (msg.get("content") or "").strip()
        except requests.HTTPError:
            # Fallback: oldest message in the thread.
            msgs = self._get(f"/channels/{thread_id}/messages", limit=1, after=0)
            if msgs:
                return (msgs[0].get("content") or "").strip()
            return ""

    def fetch_posts(self) -> list[ForumPost]:
        posts: list[ForumPost] = []
        for tid in self._thread_ids():
            meta = self._get(f"/channels/{tid}")
            posts.append(
                ForumPost(
                    thread_id=tid,
                    title=(meta.get("name") or "(untitled)").strip(),
                    body=self._starter_message(tid),
                    url=f"https://discord.com/channels/{self._guild_id}/{tid}",
                )
            )
        return posts
