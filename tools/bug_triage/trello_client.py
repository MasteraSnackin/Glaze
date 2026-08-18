"""Trello REST access. The board is the source of truth; we never store state
elsewhere.

De-dup contract: every card created from a Discord post carries a hidden marker
line in its description:

    discord-thread:<thread_id>

so "is this bug already on the board?" is just a substring scan over card
descriptions — survives workflow restarts with no external DB.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

import requests

_API = "https://api.trello.com/1"
_MARKER_RE = re.compile(r"discord-thread:(\d+)")


def marker_for(thread_id: str) -> str:
    return f"discord-thread:{thread_id}"


@dataclass(frozen=True)
class Card:
    id: str
    name: str
    desc: str
    label_ids: tuple[str, ...]

    @property
    def discord_thread_id(self) -> str | None:
        m = _MARKER_RE.search(self.desc)
        return m.group(1) if m else None


class TrelloClient:
    def __init__(self, key: str, token: str, board_id: str, dry_run: bool = False):
        self._board_id = board_id
        self._dry_run = dry_run
        self._auth = {"key": key, "token": token}
        self._s = requests.Session()

    def _req(self, method: str, path: str, **params) -> dict | list:
        r = self._s.request(
            method, f"{_API}{path}", params={**self._auth, **params}, timeout=30
        )
        r.raise_for_status()
        return r.json() if r.text else {}

    def fetch_cards(self) -> list[Card]:
        raw = self._req(
            "GET",
            f"/boards/{self._board_id}/cards",
            fields="name,desc,idLabels",
        )
        return [
            Card(
                id=c["id"],
                name=c.get("name", ""),
                desc=c.get("desc", ""),
                label_ids=tuple(c.get("idLabels", [])),
            )
            for c in raw  # type: ignore[union-attr]
        ]

    def create_card(self, list_id: str, name: str, desc: str) -> str:
        if self._dry_run:
            print(f"[dry-run] would create card: {name!r}")
            return "dry-run-card-id"
        card = self._req("POST", "/cards", idList=list_id, name=name, desc=desc)
        return card["id"]  # type: ignore[index]

    def add_comment(self, card_id: str, text: str) -> None:
        if self._dry_run:
            print(f"[dry-run] would comment on {card_id}: {text[:80]}...")
            return
        self._req("POST", f"/cards/{card_id}/actions/comments", text=text)

    def add_label(self, card_id: str, label_id: str) -> None:
        if self._dry_run:
            print(f"[dry-run] would label {card_id} with {label_id}")
            return
        self._req("POST", f"/cards/{card_id}/idLabels", value=label_id)
