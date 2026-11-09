"""Inline message widgets: AFM ``<iframe>`` previews in bot Markdown.

The server turns one ``<iframe title=… id=… height=…>HTML</iframe>`` block in a
bot's Markdown into a sandboxed widget. These helpers mirror its parsing rules
so outbound text is never split inside a widget, and build the Markdown for the
``send_widget`` tool action.
"""
from __future__ import annotations

import html as _html
import re
from typing import Any, Callable, List, NamedTuple, Optional


# Server limits (server/src/modules/message/messageWidgets.ts, messageTextLimits.ts).
MAX_MESSAGE_TEXT_UTF16_UNITS = 100_000
MAX_MESSAGE_TEXT_UTF8_BYTES = 400_000
MAX_WIDGET_HTML_BYTES = 256 * 1024
MAX_WIDGET_TITLE_CHARS = 256
MIN_WIDGET_HEIGHT = 80
MAX_WIDGET_HEIGHT = 2000

_WIDGET_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")
# Same shapes as the server: the opener starts a line; the first closer ends the payload.
_OPENER_RE = re.compile(r"""<iframe(?=[\s>])((?:[^"'<>]|"[^"]*"|'[^']*')*)>""", re.IGNORECASE)
_CLOSER_RE = re.compile(r"</iframe\s*>", re.IGNORECASE)
_CLOSER_PREFIX_RE = re.compile(r"</iframe", re.IGNORECASE)
_OPENER_PREFIX_RE = re.compile(r"<iframe", re.IGNORECASE)
_OPENING_FENCE_RE = re.compile(r"( {0,3})(`{3,}|~{3,})(.*)")
_CLOSING_FENCE_RE = re.compile(r" {0,3}(`+|~+)[ \t]*")
_ATTRIBUTE_RE = re.compile(r"""([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?""")


class WidgetSpan(NamedTuple):
    """A complete widget block from its opener line start to the end of its closing line."""
    start: int
    end: int
    title: str


class WidgetScan(NamedTuple):
    widgets: List[WidgetSpan]
    # Offset of an opener whose closing tag has not arrived (a streaming preview), else None.
    unclosed_at: Optional[int]


class WidgetError(ValueError):
    """A widget problem the model can fix."""


def utf16_len(text: str) -> int:
    return len(text.encode("utf-16-le")) // 2


def _read_line(text: str, start: int) -> tuple[int, int]:
    """(content_end, next_line_start) for the line starting at ``start``."""
    newline = text.find("\n", start)
    raw_end = newline if newline >= 0 else len(text)
    content_end = raw_end - 1 if raw_end > start and text[raw_end - 1] == "\r" else raw_end
    return content_end, (raw_end + 1 if raw_end < len(text) else len(text))


def _opener_title(attributes: str) -> str:
    for match in _ATTRIBUTE_RE.finditer(attributes):
        if match.group(1).lower() != "title":
            continue
        value = next((group for group in match.groups()[1:] if group is not None), "")
        return " ".join(_html.unescape(value).split())[:MAX_WIDGET_TITLE_CHARS]
    return ""


def scan_widgets(text: str) -> WidgetScan:
    """Find widget blocks as the server does: outside code fences, with the opener at a line start."""
    widgets: List[WidgetSpan] = []
    fence: Optional[tuple[str, int]] = None
    cursor = 0
    while cursor < len(text):
        content_end, next_line = _read_line(text, cursor)
        line = text[cursor:content_end]
        if fence:
            closing = _CLOSING_FENCE_RE.fullmatch(line)
            if closing and closing.group(1)[0] == fence[0] and len(closing.group(1)) >= fence[1]:
                fence = None
            cursor = next_line
            continue
        opening = _OPENING_FENCE_RE.fullmatch(line)
        if opening and not (opening.group(2)[0] == "`" and "`" in opening.group(3)):
            fence = (opening.group(2)[0], len(opening.group(2)))
            cursor = next_line
            continue
        opener = _OPENER_RE.match(line)
        if not opener:
            cursor = next_line
            continue
        closer = _CLOSER_RE.search(text, cursor + opener.end())
        if not closer:
            return WidgetScan(widgets, cursor)
        closing_start = text.rfind("\n", 0, closer.start()) + 1
        closing_end, after_closing = _read_line(text, closing_start)
        widgets.append(WidgetSpan(cursor, closing_end, _opener_title(opener.group(1) or "")))
        cursor = after_closing
    return WidgetScan(widgets, None)


def has_widget_markup(text: str) -> bool:
    """Cheap pre-check before a full scan."""
    return _OPENER_PREFIX_RE.search(text) is not None


def split_widget_aware(
    text: str,
    max_length: int,
    split_plain: Callable[[str, int], List[str]],
    len_fn: Callable[[str], int] = len,
) -> Optional[List[str]]:
    """Split ``text`` into messages without cutting a widget or putting two in one message.

    Returns None when the text has no complete widget, so the caller keeps its plain splitter.
    A widget block longer than ``max_length`` becomes its own message (the server allows
    100,000 UTF-16 units); prose around widgets is split with ``split_plain``.
    """
    if not has_widget_markup(text):
        return None
    scan = scan_widgets(text)
    if not scan.widgets:
        return None
    if len(scan.widgets) == 1 and len_fn(text) <= max_length:
        return [text]

    segments: List[tuple[bool, str]] = []
    cursor = 0
    for widget in scan.widgets:
        segments.append((False, text[cursor:widget.start]))
        segments.append((True, text[widget.start:widget.end]))
        cursor = widget.end
    segments.append((False, text[cursor:]))

    chunks: List[str] = []
    current = ""
    current_has_widget = False

    def joined(part: str) -> str:
        return f"{current}\n\n{part}" if current else part

    def flush() -> None:
        nonlocal current, current_has_widget
        if current.strip():
            chunks.append(current)
        current = ""
        current_has_widget = False

    for is_widget, raw in segments:
        part = raw.strip("\r\n")
        if not part.strip():
            continue
        if is_widget:
            if current and (current_has_widget or len_fn(joined(part)) > max_length):
                flush()
            current = joined(part)
            current_has_widget = True
            continue
        if len_fn(joined(part)) <= max_length:
            current = joined(part)
            continue
        flush()
        pieces = [piece for piece in split_plain(part, max_length) if piece.strip()]
        chunks.extend(pieces[:-1])
        current = pieces[-1] if pieces else ""
    flush()
    return chunks or [text]


def streaming_preview(text: str) -> str:
    """Text safe to show while a reply streams: hide a widget whose closing tag hasn't arrived."""
    if not has_widget_markup(text):
        return text
    scan = scan_widgets(text)
    if scan.unclosed_at is None:
        return text
    return text[:scan.unclosed_at].rstrip() or "…"


def replace_widgets(text: str, replacement: Callable[[WidgetSpan], str]) -> str:
    if not has_widget_markup(text):
        return text
    scan = scan_widgets(text)
    out: List[str] = []
    cursor = 0
    for widget in scan.widgets:
        out.append(text[cursor:widget.start])
        out.append(replacement(widget))
        cursor = widget.end
    out.append(text[cursor:])
    return "".join(out)


def without_widgets(text: str) -> str:
    """Replace each widget with a short notice, for a fallback after the server rejected one."""
    def notice(widget: WidgetSpan) -> str:
        return f'[Widget "{widget.title or "HTML preview"}" could not be displayed]'

    replaced = replace_widgets(text, notice)
    scan = scan_widgets(replaced)
    if scan.unclosed_at is not None:
        replaced = replaced[:scan.unclosed_at].rstrip() + "\n\n[Widget could not be displayed]"
    return replaced


def _escape_attribute(value: str) -> str:
    # The server decodes exactly &quot; &amp; &lt; &gt; &#39; &apos; in attribute values.
    return value.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")


def _height(value: Any) -> Optional[int]:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        raise WidgetError("height must be a whole number of CSS pixels from 80 to 2000")
    text = str(value).strip().lower().removesuffix("px")
    if not text.isdigit():
        raise WidgetError("height must be a whole number of CSS pixels from 80 to 2000")
    height = int(text)
    if height < MIN_WIDGET_HEIGHT or height > MAX_WIDGET_HEIGHT:
        raise WidgetError("height must be from 80 to 2000 CSS pixels")
    return height


def build_widget_markdown(
    *,
    html: str,
    title: Optional[str] = None,
    widget_id: Optional[str] = None,
    height: Any = None,
    text: Optional[str] = None,
) -> str:
    """Markdown for one widget message: optional lead text, then the ``<iframe>`` block."""
    body = str(html or "").strip("\r\n")
    if not body.strip():
        raise WidgetError("html is required")
    if _CLOSER_PREFIX_RE.search(body):
        raise WidgetError("html must not contain </iframe: it would end the widget early (nested iframes are not allowed)")
    if len(body.encode("utf-8")) > MAX_WIDGET_HTML_BYTES:
        raise WidgetError("html exceeds 256 KiB")
    attributes: List[str] = []
    clean_title = " ".join(str(title or "").split())
    if len(clean_title) > MAX_WIDGET_TITLE_CHARS:
        raise WidgetError(f"title is longer than {MAX_WIDGET_TITLE_CHARS} characters")
    if clean_title:
        attributes.append(f'title="{_escape_attribute(clean_title)}"')
    clean_id = str(widget_id or "").strip()
    if clean_id:
        if not _WIDGET_ID_RE.fullmatch(clean_id):
            raise WidgetError("widget_id must be 1-64 characters of letters, digits, _ . : -")
        attributes.append(f'id="{clean_id}"')
    parsed_height = _height(height)
    if parsed_height is not None:
        attributes.append(f'height="{parsed_height}"')
    opener = "<iframe" + "".join(f" {attribute}" for attribute in attributes) + ">"
    block = f"{opener}\n{body}\n</iframe>"
    lead = str(text or "").strip()
    markdown = f"{lead}\n\n{block}" if lead else block
    scan = scan_widgets(markdown)
    if len(scan.widgets) != 1 or scan.unclosed_at is not None or scan.widgets[0].end != len(markdown):
        raise WidgetError("text must not contain another <iframe> or an unclosed code fence; a message holds one widget")
    if utf16_len(markdown) > MAX_MESSAGE_TEXT_UTF16_UNITS or len(markdown.encode("utf-8")) > MAX_MESSAGE_TEXT_UTF8_BYTES:
        raise WidgetError("message exceeds Inline's 100,000 character limit")
    return markdown
