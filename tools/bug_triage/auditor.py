"""The only agentic part of the pipeline.

A DeepSeek-backed Pydantic AI agent gets two read-only tools to explore the
checked-out repo (ripgrep search + file read) and must return a *structured*
audit. It never edits code, never opens PRs — the orchestrator only posts its
output as a Trello comment for a human to act on.

One report is audited per agent run: title, original post and replies travel
together, but threads are never mixed.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field
from pydantic_ai import Agent, PromptedOutput
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider

# The tree the agent is allowed to grep and read. Defaults to this checkout
# (two levels up from tools/bug_triage/auditor.py); CI points AUDIT_REPO_ROOT at
# a separate nightly checkout, so a scheduled run started from stable still
# judges reports against current code rather than a months-old tree.
REPO_ROOT = Path(
    os.environ.get("AUDIT_REPO_ROOT") or Path(__file__).resolve().parents[2]
).resolve()

_MAX_FILE_BYTES = 40_000
_MAX_RG_MATCHES = 60

_SYSTEM_PROMPT = """\
You are a bug-triage engineer for Glaze, a Flutter (Dart) LLM roleplay frontend.
You receive ONE bug report at a time: its title, the original post, and any
replies from the thread. Judge them together — a reply often carries the repro
steps or the correction that the title alone is missing.

Your job: investigate the CURRENT source code using the `search_code` and
`read_file` tools, then produce a structured audit. Rules:
- Only claim something is a bug if the code actually supports it. If you cannot
  reproduce the cause from the code, say so and set confidence low.
- Prefer concrete file:line references over vague statements.
- Propose a fix as a description, NOT as a patch. Do not invent files.
- Be concise. A human will read this in a Trello comment.

You CANNOT see images. When a report leans on screenshots, or the text is too
vague to tell what actually went wrong, set `needs_more_info` to true and put
the specific questions a human should ask in `missing_info`. Never guess the
contents of an attachment, and never invent repro steps that were not reported.
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
    needs_more_info: bool = Field(
        default=False,
        description=(
            "True when the report cannot be judged from text alone — e.g. it "
            "relies on screenshots you cannot see, or lacks repro steps."
        ),
    )
    missing_info: str = Field(
        default="",
        description="What exactly to ask the reporter, when needs_more_info is true.",
    )
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
    model = OpenAIChatModel(
        model_name,
        provider=OpenAIProvider(base_url=base_url, api_key=api_key),
    )
    agent: Agent[None, BugAudit] = Agent(
        model,
        # PromptedOutput, not the default forced output tool: DeepSeek's
        # thinking models reject `tool_choice` pinned to a specific tool
        # ("Thinking mode does not support this tool_choice", HTTP 400). Asking
        # for the JSON in the prompt keeps `search_code` / `read_file` as
        # ordinary optional tools, which those models do accept.
        output_type=PromptedOutput(BugAudit),
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
    src = f"\nSource: {source_url}" if source_url else ""

    if audit.needs_more_info:
        asks = audit.missing_info.strip() or (
            "The report relies on context that is not readable from text "
            "(screenshots?). Ask the reporter for steps to reproduce."
        )
        return (
            f"\u26a0\ufe0f **NEED MORE INFO** \u2014 automated triage could not "
            f"judge this report.{src}\n\n"
            f"**What was understood**\n{audit.summary}\n\n"
            f"**What is missing**\n{asks}\n\n"
            f"*(No audit was performed. Nothing was changed.)*"
        )

    files = "\n".join(f"- {f}" for f in audit.relevant_files) or "- (none identified)"
    verdict = "actionable" if audit.is_actionable else "NOT clearly actionable"
    notes = f"\n**Notes:** {audit.notes}" if audit.notes else ""
    return (
        f"\U0001f916 **Automated audit** (DeepSeek) \u2014 {verdict}, severity "
        f"**{audit.severity}**, confidence **{audit.confidence}**{src}\n\n"
        f"**Summary**\n{audit.summary}\n\n"
        f"**Suspected root cause**\n{audit.root_cause}\n\n"
        f"**Proposed fix (needs human approval \u2014 nothing was changed)**\n"
        f"{audit.proposed_fix}\n\n"
        f"**Relevant files**\n{files}{notes}"
    )
