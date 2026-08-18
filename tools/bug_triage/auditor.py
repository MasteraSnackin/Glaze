"""The only agentic part of the pipeline.

A DeepSeek-backed Pydantic AI agent gets two read-only tools to explore the
checked-out repo (ripgrep search + file read) and must return a *structured*
audit. It never edits code, never opens PRs — the orchestrator only posts its
output as a Trello comment for a human to act on.
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field
from pydantic_ai import Agent, RunContext
from pydantic_ai.models.openai import OpenAIModel
from pydantic_ai.providers.openai import OpenAIProvider

# Repo root = two levels up from this file (tools/bug_triage/auditor.py).
REPO_ROOT = Path(__file__).resolve().parents[2]

_MAX_FILE_BYTES = 40_000
_MAX_RG_MATCHES = 60

_SYSTEM_PROMPT = """\
You are a bug-triage engineer for Glaze, a Flutter (Dart) LLM roleplay frontend.
You receive a single bug report copied from Discord or a Trello card.

Your job: investigate the CURRENT source code using the `search_code` and
`read_file` tools, then produce a structured audit. Rules:
- Only claim something is a bug if the code actually supports it. If you cannot
  reproduce the cause from the code, say so and set confidence low.
- Prefer concrete file:line references over vague statements.
- Propose a fix as a description, NOT as a patch. Do not invent files.
- Be concise. A human will read this in a Trello comment.
"""


class BugAudit(BaseModel):
    is_actionable: bool = Field(
        description="True if this is a real, reproducible bug worth fixing."
    )
    severity: Literal["low", "medium", "high", "critical", "unknown"]
    summary: str = Field(description="One-paragraph restatement of the bug.")
    root_cause: str = Field(
        description="Suspected cause with file:line refs, or why it's unclear."
    )
    proposed_fix: str = Field(description="Fix direction in prose, no code patch.")
    relevant_files: list[str] = Field(default_factory=list)
    confidence: Literal["low", "medium", "high"]
    notes: str = Field(default="", description="Anything a human should double-check.")


def _safe_path(rel: str) -> Path | None:
    """Resolve a user-supplied path and confine it inside the repo."""
    p = (REPO_ROOT / rel).resolve()
    try:
        p.relative_to(REPO_ROOT)
    except ValueError:
        return None
    return p


def build_agent(api_key: str, base_url: str, model_name: str) -> Agent[None, BugAudit]:
    model = OpenAIModel(
        model_name,
        provider=OpenAIProvider(base_url=base_url, api_key=api_key),
    )
    agent: Agent[None, BugAudit] = Agent(
        model,
        output_type=BugAudit,
        system_prompt=_SYSTEM_PROMPT,
        retries=2,
    )

    @agent.tool_plain
    def search_code(pattern: str) -> str:
        """Regex-search the repo (ripgrep). Returns matching `path:line: text`."""
        try:
            out = subprocess.run(
                ["rg", "--line-number", "--no-heading", "--max-count", "20",
                 "--glob", "!**/*.g.dart", "--glob", "!**/*.freezed.dart",
                 pattern],
                cwd=REPO_ROOT, capture_output=True, text=True, timeout=30,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired) as e:
            return f"search unavailable: {e}"
        lines = out.stdout.splitlines()
        if not lines:
            return "no matches"
        return "\n".join(lines[:_MAX_RG_MATCHES])

    @agent.tool_plain
    def read_file(path: str) -> str:
        """Read a repo file (relative path). Truncated to 40KB."""
        p = _safe_path(path)
        if p is None or not p.is_file():
            return f"not found or outside repo: {path}"
        data = p.read_text(encoding="utf-8", errors="replace")
        if len(data) > _MAX_FILE_BYTES:
            return data[:_MAX_FILE_BYTES] + "\n... [truncated]"
        return data

    return agent


def format_comment(audit: BugAudit, source_url: str | None) -> str:
    """Render the audit as a Trello comment (markdown-ish)."""
    files = "\n".join(f"- {f}" for f in audit.relevant_files) or "- (none identified)"
    src = f"\nSource: {source_url}" if source_url else ""
    verdict = "actionable" if audit.is_actionable else "NOT clearly actionable"
    return f"""\
🤖 **Automated audit** (DeepSeek) — {verdict}, severity **{audit.severity}**, confidence **{audit.confidence}**{src}

**Summary**
{audit.summary}

**Suspected root cause**
{audit.root_cause}

**Proposed fix (needs human approval — nothing was changed)**
{audit.proposed_fix}

**Relevant files**
{files}

{('**Notes:** ' + audit.notes) if audit.notes else ''}""".rstrip()
