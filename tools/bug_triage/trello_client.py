"""Trello REST access. The board holds the triage state (which Discord thread
already has a card, and whether it was audited); we never store state elsewhere.
It is not a work queue — the agent only ever acts on cards that carry a Discord
marker, and finds them by walking the forum, not the board.

De-dup contract: every card that tracks a Discord post carries a hidden marker
line in its description:

    discord-thread:<thread_id>

so "is this bug already on the board?" is just a scan over card descriptions —
survives workflow restarts with no external DB. A card can carry SEVERAL such
markers: when two forum threads turn out to report the same bug, the later ones
are appended to the card that reported it first instead of opening duplicates.
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
    list_id: str
    label_ids: tuple[str, ...]

    @property
    def discord_thread_ids(self) -> tuple[str, ...]:
        """Every Discord thread this card tracks, in the order they were linked."""
        return tuple(m.group(1) for m in _MARKER_RE.finditer(self.desc))

    @property
    def created_at(self) -> int:
        """Creation time as a unix timestamp.

        Trello ids are Mongo ObjectIds: the first four bytes are the creation
        time. That is what makes "the card that reported it first" answerable
        without another API call.
        """
        try:
            return int(self.id[:8], 16)
        except ValueError:
            return 0


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
            fields="name,desc,idList,idLabels",
        )
        return [
            Card(
                id=c["id"],
                name=c.get("name", ""),
                desc=c.get("desc", ""),
                list_id=c.get("idList", ""),
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

    def set_desc(self, card_id: str, desc: str) -> None:
        """Overwrite a card's description — used to write the Discord marker
        and back-link into a card a human created for the same bug."""
        if self._dry_run:
            print(f"[dry-run] would rewrite desc of {card_id}")
            return
        self._req("PUT", f"/cards/{card_id}", desc=desc)

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
