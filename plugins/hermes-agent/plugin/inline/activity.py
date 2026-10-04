"""Inline activity presentation. Host events are data; previews are never titles."""
from __future__ import annotations

import asyncio
import math
import queue
import re
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Any, Callable, Optional


def duration_label(seconds: float) -> str:
    total = max(0, int(seconds)) if math.isfinite(seconds) else 0
    if total < 1:
        return "less than 1s"
    hours, rest = divmod(total, 3600)
    minutes, seconds = divmod(rest, 60)
    return " ".join(value for value in (
        f"{hours}h" if hours else "", f"{minutes}m" if minutes else "", f"{seconds}s" if seconds else "",
    ) if value)


def step_title(name: str, args: Optional[dict] = None) -> str:
    args = args or {}
    # Only these explicit presentation fields describe intent. Never use a
    # command, arbitrary output, or an assistant reasoning message as a title.
    description = args.get("description")
    if isinstance(description, str) and description.strip():
        return " ".join(description.split())[:100]
    labels = {
        "terminal": "Running a script", "exec": "Running a script", "execute_code": "Running code",
        "web_search": "Searching the web", "web_extract": "Reading a web page",
        "browser": "Using the browser", "browser_exec": "Using the browser",
        "read_file": "Reading a file", "write_file": "Writing a file", "file_read": "Reading a file",
        "file_write": "Writing a file", "file_edit": "Editing a file", "apply_patch": "Editing files",
        "tool_describe": "Checking available tools", "skill_view": "Reading instructions",
        "delegate_task": "Delegating a task", "image_generate": "Generating an image",
    }
    title = labels.get(name, "Using a tool")
    if name in {"read_file", "write_file", "file_read", "file_write", "file_edit"}:
        path = args.get("path") or args.get("file_path")
        if isinstance(path, str) and path.strip():
            title = title.replace("a file", PurePosixPath(path).name)
    return title[:100]


@dataclass(frozen=True)
class ActivityEvent:
    title: str
    detail: str
    at: float
    failed: bool = False


def tool_event(event_type: str, name: str, preview: Optional[str], args: Optional[dict], **kwargs: Any) -> Optional[ActivityEvent]:
    if event_type == "tool.completed":
        # The legacy callback has no call ID. Do not guess which parallel call
        # completed; record explicit failures as separate factual events.
        if kwargs.get("is_error") is True:
            return ActivityEvent(step_title(name), f"{name}: tool reported an error", time.monotonic(), True)
        return None
    if event_type != "tool.started" or name in {"_thinking", "clarify"}:
        return None
    detail = preview or ""
    if name in {"terminal", "exec", "execute_code"}:
        detail = (args or {}).get("command") or (args or {}).get("code") or detail
    if not isinstance(detail, str):
        detail = ""
    # Input is already display-redacted by Hermes. Bound each preview, and label
    # truncation rather than promising a complete execution log.
    requested_limit = kwargs.get("preview_limit", 1200)
    limit = min(1200, requested_limit) if isinstance(requested_limit, int) and requested_limit > 0 else 1200
    if len(detail) > limit:
        detail = detail[:limit] + "\n[preview truncated]"
    return ActivityEvent(step_title(name, args), detail, time.monotonic())


def render_activity(title: str, details: list[str], *, elapsed: Optional[float] = None, outcome: str = "success", tool_failed: bool = False) -> str:
    if elapsed is not None:
        prefix = {"failure": "Failed after", "cancelled": "Stopped after"}.get(outcome, "Worked for")
        title = f"{prefix} {duration_label(elapsed)}"
        if tool_failed and outcome == "success":
            title += " · tool error recorded"
    escaped = re.sub(r"([\\`*_{}\[\]<>#!|])", r"\\\1", title)
    content = "\n\n".join(details)
    fence = "`" * max(3, max((len(run) for run in re.findall(r"`+", content)), default=0) + 1)
    kind = ' kind="progress"' if elapsed is None else ""
    return f'<details>\n<summary{kind} activity="agent">{escaped}</summary>\n\n{fence}\n{content}\n{fence}\n\n</details>'


class ActivityTimeline:
    """One turn, one existing progress queue; transport and boundaries serialize."""
    def __init__(self, publish: Callable, target: dict, *, clock: Callable = time.monotonic, ctx: Any = None, handles_replies: bool = False):
        self.publish = publish
        self.target = target
        self.clock = clock
        self.lock = asyncio.Lock()
        self.details: list[str] = []
        self.title = "Working"
        self.started_at: Optional[float] = None
        self.ended_at: Optional[float] = None
        self.message_id: Optional[str] = None
        self.tool_failed = False
        self.last_closed: Optional[dict] = None
        self.closed = False
        self.pending_outcome: Optional[str] = None
        self.ctx = ctx
        self.handles_replies = handles_replies

    async def _publish(self, *, outcome: Optional[str] = None) -> None:
        if self.started_at is None:
            return
        elapsed = max(0, (self.ended_at if self.ended_at is not None else self.clock()) - self.started_at) if outcome else None
        text = render_activity(self.title, self.details, elapsed=elapsed, outcome=outcome or "success", tool_failed=self.tool_failed)
        body = {"target": self.target, "text": text, "parseMarkdown": True}
        if self.message_id:
            body["messageId"] = self.message_id
        else:
            body["sendMode"] = "silent"
        result = await self.publish("/edit" if self.message_id else "/send", body)
        if not getattr(result, "success", False):
            raise RuntimeError("Inline activity delivery failed")
        if not self.message_id:
            self.message_id = str(result.message_id) if getattr(result, "message_id", None) else None
            if not self.message_id:
                raise RuntimeError("Inline activity delivery returned no message ID")

    async def add(self, event: ActivityEvent, *, publish: bool = True) -> None:
        async with self.lock:
            await self._add(event)
            if publish and not self.closed:
                await self._publish()

    async def _add(self, event: ActivityEvent) -> None:
        if self.closed:
            return
        detail = event.title + (f"\n{event.detail}" if event.detail else "")
        if self.details and len(render_activity(event.title, self.details + [detail])) > 3600:
            await self._finish_block("success", event.at)
        if self.started_at is None:
            self.started_at = event.at
        self.title = ("Tool reported an error" if event.failed else event.title)
        self.tool_failed |= event.failed
        self.details.append(detail)

    async def _finish_block(self, outcome: str, at: float) -> None:
        if self.started_at is None:
            return
        # Freeze before I/O. Retrying the edit must not inflate duration.
        if self.ended_at is None:
            self.ended_at = at
        await self._publish(outcome=outcome)
        self.last_closed = {"target": self.target, "messageId": self.message_id, "details": self.details[:],
                            "elapsed": max(0, self.ended_at - self.started_at), "tool_failed": self.tool_failed}
        self.details = []
        self.started_at = self.ended_at = self.message_id = None
        self.tool_failed = False

    async def boundary(self, at: Optional[float] = None) -> None:
        at = self.clock() if at is None else at
        async with self.lock:
            await self._drain()
            await self._finish_block("success", at)

    @asynccontextmanager
    async def reply_boundary(self):
        """Flush earlier events and keep later ones behind the reply transport."""
        at = self.clock()
        async with self.lock:
            try:
                await self._drain()
                await self._finish_block(self.processing_outcome(), at)
            except Exception:
                # A failed progress edit must not prevent the actual reply.
                pass
            yield

    def stopped(self) -> bool:
        if self.ctx is None:
            return False
        holder = getattr(self.ctx, "agent_holder", None)
        return bool(holder and getattr(holder[0], "is_interrupted", False)) or not self.ctx._run_still_current()

    def processing_outcome(self) -> str:
        holder = getattr(self.ctx, "result_holder", None)
        result = holder[0] if holder else None
        if isinstance(result, dict):
            if result.get("interrupted"):
                return "cancelled"
            if result.get("failed"):
                return "failure"
        return "cancelled" if self.stopped() else "success"

    async def _drain(self) -> bool:
        """Consume a snapshot under lock; never dequeue ahead of a reply."""
        if self.ctx is None or self.closed or self.stopped():
            return False
        pending = []
        while True:
            try:
                pending.append(self.ctx.progress_queue.get_nowait())
            except queue.Empty:
                break
        for raw in pending:
            if isinstance(raw, ActivityEvent):
                await self._add(raw)
            elif isinstance(raw, tuple) and raw and raw[0] == "__reset__":
                # The host emits this AFTER sending commentary. Owned turns
                # already close before send; replaying it would close new work.
                if not self.handles_replies:
                    await self._finish_block("success", self.clock())
            elif isinstance(raw, str) and raw.strip():
                await self._add(ActivityEvent("Working", raw[:1200], self.clock()))
        return bool(pending)

    async def finish(self, outcome: Optional[str] = None) -> None:
        at = self.clock()
        async with self.lock:
            # A predecessor already closed before a queued child starts keeps
            # its own outcome; a later generation invalidation is not its stop.
            if self.closed and self.pending_outcome is None and outcome in {None, "success"}:
                return
            # Admission closes even if the terminal edit fails. Keep its
            # outcome until delivery succeeds, so a later public success hook
            # retries the frozen failure/stop payload instead of losing it.
            if outcome in {None, "success"}:
                if self.pending_outcome in {"failure", "cancelled"}:
                    outcome = self.pending_outcome
                elif outcome == "success":
                    # The public hook belongs to the CURRENT child. Its
                    # actual stop/failure beats a pending successful edit.
                    outcome = self.processing_outcome()
                else:
                    # A queued predecessor is retried without an outcome;
                    # preserve its frozen result across generation changes.
                    outcome = self.pending_outcome or self.processing_outcome()
            self.pending_outcome = outcome
            await self._drain()
            self.closed = True
            if self.started_at is not None:
                await self._finish_block(outcome, at)
            elif self.last_closed and outcome != "success":
                row = self.last_closed
                result = await self.publish("/edit", {"target": row["target"], "messageId": row["messageId"],
                    "text": render_activity("", row["details"], elapsed=row["elapsed"], outcome=outcome, tool_failed=row["tool_failed"]),
                    "parseMarkdown": True})
                if not getattr(result, "success", False):
                    raise RuntimeError("Inline activity outcome delivery failed")
            self.pending_outcome = None

    async def consume(self, ctx: Any) -> None:
        self.ctx = ctx
        try:
            while not self.closed and not self.stopped():
                async with self.lock:
                    changed = await self._drain()
                    if changed and self.started_at is not None:
                        await self._publish()
                await asyncio.sleep(0.5 if changed else 0.15)
        except asyncio.CancelledError:
            # Hermes cancels its sender on normal completion too. The official
            # processing hook supplies the authoritative outcome afterward.
            pass
        finally:
            await self.finish()
