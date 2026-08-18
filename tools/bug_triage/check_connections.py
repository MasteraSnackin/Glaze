"""Read-only smoke test. Verifies every credential/ID works BEFORE the real run.

Creates nothing, comments nothing. For DeepSeek it sends one tiny 1-token
request just to confirm the key + model are valid.

Run:  python check_connections.py
"""

from __future__ import annotations

import sys

import requests

from config import Config
from discord_client import DiscordClient
from trello_client import TrelloClient

OK = "OK  "
BAD = "FAIL"


def _line(status: str, label: str, detail: str = "") -> None:
    print(f"[{status}] {label}" + (f" — {detail}" if detail else ""))


def check_discord(cfg: Config) -> bool:
    h = {"Authorization": f"Bot {cfg.discord_bot_token}"}
    try:
        me = requests.get(
            "https://discord.com/api/v10/users/@me", headers=h, timeout=20
        )
        me.raise_for_status()
        _line(OK, "Discord token", f"bot = {me.json().get('username')}")

        ch = requests.get(
            f"https://discord.com/api/v10/channels/{cfg.discord_forum_channel_id}",
            headers=h, timeout=20,
        )
        ch.raise_for_status()
        c = ch.json()
        kind = "forum" if c.get("type") == 15 else f"type={c.get('type')} (NOT a forum?)"
        _line(OK, "Discord forum channel", f"{c.get('name')} [{kind}]")

        posts = DiscordClient(
            cfg.discord_bot_token, cfg.discord_guild_id, cfg.discord_forum_channel_id
        ).fetch_posts()
        empty = sum(1 for p in posts if not p.body)
        _line(OK, "Discord forum read", f"{len(posts)} post(s), {empty} with empty body")
        if posts and empty == len(posts):
            _line(BAD, "Discord message content",
                  "all bodies empty → enable MESSAGE CONTENT INTENT")
            return False
        return True
    except requests.HTTPError as e:
        _line(BAD, "Discord", f"{e.response.status_code} {e.response.text[:120]}")
        return False
    except Exception as e:  # noqa: BLE001
        _line(BAD, "Discord", str(e))
        return False


def check_trello(cfg: Config) -> bool:
    auth = {"key": cfg.trello_key, "token": cfg.trello_token}
    try:
        b = requests.get(
            f"https://api.trello.com/1/boards/{cfg.trello_board_id}",
            params={**auth, "fields": "name"}, timeout=20,
        )
        b.raise_for_status()
        _line(OK, "Trello board", b.json().get("name"))

        cards = TrelloClient(
            cfg.trello_key, cfg.trello_token, cfg.trello_board_id
        ).fetch_cards()
        linked = sum(1 for c in cards if c.discord_thread_id)
        _line(OK, "Trello cards read", f"{len(cards)} card(s), {linked} discord-linked")

        lst = requests.get(
            f"https://api.trello.com/1/lists/{cfg.trello_new_bug_list_id}",
            params={**auth, "fields": "name,idBoard"}, timeout=20,
        )
        lst.raise_for_status()
        lj = lst.json()
        on_board = lj.get("idBoard") == cfg.trello_board_id
        _line(OK if on_board else BAD, "Trello new-bug list",
              f"{lj.get('name')}" + ("" if on_board else " — list is NOT on this board!"))
        if not on_board:
            return False

        lbls = requests.get(
            f"https://api.trello.com/1/boards/{cfg.trello_board_id}/labels",
            params={**auth, "fields": "name"}, timeout=20,
        )
        lbls.raise_for_status()
        ids = {l["id"] for l in lbls.json()}
        if cfg.trello_audited_label_id in ids:
            _line(OK, "Trello audited label", "found on board")
        else:
            _line(BAD, "Trello audited label",
                  "id not found on this board → wrong TRELLO_AUDITED_LABEL_ID")
            return False
        return True
    except requests.HTTPError as e:
        _line(BAD, "Trello", f"{e.response.status_code} {e.response.text[:120]}")
        return False
    except Exception as e:  # noqa: BLE001
        _line(BAD, "Trello", str(e))
        return False


def check_deepseek(cfg: Config) -> bool:
    try:
        r = requests.post(
            f"{cfg.deepseek_base_url}/chat/completions",
            headers={"Authorization": f"Bearer {cfg.deepseek_api_key}"},
            json={
                "model": cfg.deepseek_model,
                "messages": [{"role": "user", "content": "ping"}],
                "max_tokens": 1,
            },
            timeout=30,
        )
        r.raise_for_status()
        _line(OK, "DeepSeek", f"model {cfg.deepseek_model} responded")
        return True
    except requests.HTTPError as e:
        _line(BAD, "DeepSeek", f"{e.response.status_code} {e.response.text[:160]}")
        return False
    except Exception as e:  # noqa: BLE001
        _line(BAD, "DeepSeek", str(e))
        return False


def main() -> int:
    try:
        cfg = Config.load()
    except SystemExit as e:
        print(e)
        return 2

    print("=== bug-triage connection check (read-only) ===")
    results = [check_discord(cfg), check_trello(cfg), check_deepseek(cfg)]
    print("=" * 47)
    if all(results):
        print("ALL GOOD ✅  — safe to run triage.py (try DRY_RUN=true first).")
        return 0
    print("SOME CHECKS FAILED ❌ — fix the FAIL lines above.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
