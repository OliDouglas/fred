#!/usr/bin/env python3
"""
scrape_followed_playwright.py

Requirements:
    pip install playwright
    playwright install
    # If using Tor dependencies on Linux:
    # python3 -m playwright install --with-deps chromium

Place your cookies.txt (Netscape format) in the same directory.

Run:
    python3 scrape_followed_playwright.py

Run tests:
    python3 scrape_followed_playwright.py --test

Optional Tor proxy:
    python3 scrape_followed_playwright.py --proxy socks5://127.0.0.1:9050
"""

from __future__ import annotations

import argparse
import html
import sys
import time
import unittest
from dataclasses import dataclass
from http.cookiejar import MozillaCookieJar
from pathlib import Path
from typing import Dict, Iterable, List, Optional

from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
from playwright.sync_api import sync_playwright


FOLLOWED_BASE = "https://chaturbate.com/followed-cams/"
PAGES = [1, 2]
COOKIES_TXT = "cookies.txt"
OUT_HTML = "followed_playwright.html"
OUT_TXT = "live_model.txt"
WAIT_TIMEOUT_MS = 30_000
LAUNCH_TIMEOUT_MS = 60_000
LAUNCH_RETRIES = 3
LAUNCH_RETRY_DELAY_S = 3.0


@dataclass
class ModelEntry:
    name: str
    private: bool = False


def load_cookies_netscape(path: str) -> List[Dict]:
    """Load a Netscape-format cookies.txt and return Playwright cookie dicts."""
    cj = MozillaCookieJar()
    cj.load(path, ignore_discard=True, ignore_expires=True)

    cookies: List[Dict] = []
    for c in cj:
        cookie: Dict[str, object] = {
            "name": c.name,
            "value": c.value,
            "domain": c.domain,
            "path": c.path or "/",
            "httpOnly": False,
            "secure": bool(c.secure),
        }
        if c.expires:
            try:
                cookie["expires"] = int(c.expires)
            except (TypeError, ValueError):
                pass
        cookies.append(cookie)
    return cookies


EXTRACT_JS = r"""
(() => {
  const seen = new Set();
  const out = [];

  for (const a of document.querySelectorAll('a[data-room][data-testid="room-card-username"]')) {
    const name = (a.getAttribute('data-room') || '').trim();
    if (!name || seen.has(name)) continue;
    seen.add(name);

    const details = a.closest('.RoomCardDetails');
    const root = details ? details.parentElement : a.parentElement;
    const privateLabel = root ? root.querySelector('.thumbnail_label_c_private_show,[data-testid="thumbnail-label"]') : null;
    const isPrivate = !!privateLabel && /private/i.test((privateLabel.textContent || '').trim());

    out.push({ name, private: isPrivate });
  }

  return out;
})();
"""


def format_model_list(models: Iterable[ModelEntry]) -> str:
    """Return count plus numbered list, highlighting private entries."""
    models = list(models)
    if not models:
        return "Extracted 0 model names."

    lines = [f"Extracted {len(models)} model names:"]
    for i, model in enumerate(models, 1):
        suffix = " [PRIVATE]" if model.private else ""
        lines.append(f"{i}. {model.name}{suffix}")
    return "\n".join(lines)


def render_html_report(models: Iterable[ModelEntry]) -> str:
    """Generate a standalone HTML report with private rows highlighted."""
    models = list(models)
    total = len(models)
    private_count = sum(1 for m in models if m.private)

    rows = []
    for i, model in enumerate(models, 1):
        row_class = "model private" if model.private else "model"
        badge = '<span class="badge">PRIVATE</span>' if model.private else ""
        safe_name = html.escape(model.name)
        rows.append(
            f"""
            <tr class="{row_class}">
              <td class="idx">{i}</td>
              <td class="name">{safe_name}</td>
              <td class="state">{badge}</td>
            </tr>
            """.strip()
        )

    rows_html = "\n".join(rows) if rows else '<tr><td colspan="3">No models found.</td></tr>'

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Followed Models Report</title>
  <style>
    :root {{
      color-scheme: dark;
      --bg: #0b0f14;
      --panel: #111823;
      --text: #e6edf3;
      --muted: #9aa7b2;
      --line: #263241;
      --private-bg: #2a1114;
      --private-border: #8b1e2d;
      --private-text: #ffb4be;
      --badge-bg: #5a1220;
      --badge-text: #ffd7de;
    }}

    body {{
      margin: 0;
      padding: 24px;
      background: var(--bg);
      color: var(--text);
      font-family: system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
    }}

    .wrap {{
      max-width: 980px;
      margin: 0 auto;
    }}

    h1 {{
      margin: 0 0 8px;
      font-size: 28px;
    }}

    .meta {{
      margin: 0 0 18px;
      color: var(--muted);
    }}

    table {{
      width: 100%;
      border-collapse: collapse;
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 14px;
      overflow: hidden;
    }}

    th, td {{
      padding: 12px 14px;
      border-bottom: 1px solid var(--line);
      text-align: left;
      vertical-align: middle;
    }}

    th {{
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }}

    tr:last-child td {{
      border-bottom: 0;
    }}

    .idx {{
      width: 72px;
      color: var(--muted);
    }}

    .state {{
      width: 140px;
    }}

    .private {{
      background: var(--private-bg);
    }}

    .private .name {{
      color: var(--private-text);
      font-weight: 700;
    }}

    .badge {{
      display: inline-block;
      padding: 4px 10px;
      border-radius: 999px;
      background: var(--badge-bg);
      color: var(--badge-text);
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.04em;
    }}
  </style>
</head>
<body>
  <div class="wrap">
    <h1>Followed Models</h1>
    <p class="meta">{total} total · {private_count} private</p>
    <table>
      <thead>
        <tr>
          <th>#</th>
          <th>Model</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
        {rows_html}
      </tbody>
    </table>
  </div>
</body>
</html>
"""


def merge_unique_preserve_order(
    lists: Iterable[Iterable[ModelEntry]],
) -> List[ModelEntry]:
    """Merge iterables into first-seen order with duplicates removed.

    If a model appears multiple times and any occurrence is private,
    the merged entry is marked private.
    """
    out: List[ModelEntry] = []
    index_by_name: Dict[str, int] = {}

    for lst in lists:
        for item in lst:
            name = item.name.strip()
            if not name:
                continue

            if name in index_by_name:
                out[index_by_name[name]].private = out[index_by_name[name]].private or item.private
                continue

            index_by_name[name] = len(out)
            out.append(ModelEntry(name=name, private=bool(item.private)))

    return out


def normalize_extracted_items(result) -> List[ModelEntry]:
    """Convert JS extraction result into ModelEntry objects."""
    out: List[ModelEntry] = []
    if not isinstance(result, list):
        return out

    for item in result:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name", "")).strip()
        if not name:
            continue
        private = bool(item.get("private", False))
        out.append(ModelEntry(name=name, private=private))
    return out


def fetch_models_from_page(page, url: str) -> List[ModelEntry]:
    """Navigate to a page and extract unique model entries."""
    try:
        page.goto(url, wait_until="networkidle", timeout=20_000)
    except Exception:
        try:
            page.goto(url, wait_until="domcontentloaded", timeout=60_000)
        except Exception:
            return []

    try:
        page.wait_for_selector('a[data-room][data-testid="room-card-username"]', timeout=WAIT_TIMEOUT_MS)
    except PlaywrightTimeoutError:
        pass

    try:
        page.evaluate("window.scrollTo(0, document.body.scrollHeight);")
        time.sleep(0.6)
    except Exception:
        pass

    try:
        result = page.evaluate(EXTRACT_JS)
        return normalize_extracted_items(result)
    except Exception:
        return []


def launch_browser_with_retries(p, proxy_server: Optional[str], launch_timeout_ms: int):
    """Launch Chromium with retry and optional SOCKS/HTTP proxy."""
    launch_kwargs: Dict[str, object] = {
        "headless": True,
        "timeout": launch_timeout_ms,
        "args": ["--no-sandbox"],
    }
    if proxy_server:
        launch_kwargs["proxy"] = {"server": proxy_server}

    last_exc: Optional[BaseException] = None
    for attempt in range(1, LAUNCH_RETRIES + 1):
        try:
            return p.chromium.launch(**launch_kwargs)
        except Exception as exc:
            last_exc = exc
            if attempt < LAUNCH_RETRIES:
                print(f"browser launch failed (attempt {attempt}/{LAUNCH_RETRIES}): {exc}")
                time.sleep(LAUNCH_RETRY_DELAY_S)

    raise RuntimeError(f"failed to launch browser after {LAUNCH_RETRIES} attempts") from last_exc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--proxy",
        default=None,
        help='Optional browser proxy, e.g. "socks5://127.0.0.1:9050"',
    )
    parser.add_argument(
        "--launch-timeout-ms",
        type=int,
        default=LAUNCH_TIMEOUT_MS,
        help="Chromium launch timeout in milliseconds",
    )
    parser.add_argument(
        "--test",
        action="store_true",
        help="Run unit tests and exit",
    )
    args = parser.parse_args()

    if args.test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(TestHelpers)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1

    cookie_path = Path(COOKIES_TXT)
    if not cookie_path.exists():
        print("cookies.txt not found. Export cookies for chaturbate.com and save as cookies.txt")
        return 1

    cookies = load_cookies_netscape(str(cookie_path))
    print(f"loaded {len(cookies)} cookies from {COOKIES_TXT}")

    with sync_playwright() as p:
        browser = launch_browser_with_retries(p, args.proxy, args.launch_timeout_ms)
        context = browser.new_context()

        try:
            context.add_cookies(cookies)
        except Exception:
            for cookie in cookies:
                try:
                    context.add_cookies([cookie])
                except Exception:
                    pass

        page = context.new_page()

        all_page_names: List[List[ModelEntry]] = []
        for pg in PAGES:
            url = f"{FOLLOWED_BASE}?page={pg}"
            print(f"navigating to {url}")
            models = fetch_models_from_page(page, url)
            print(f"  found {len(models)} items on page {pg}")
            all_page_names.append(models)

        browser.close()

    merged = merge_unique_preserve_order(all_page_names)
    print(format_model_list(merged))

    try:
        Path(OUT_TXT).write_text(
            "\n".join(m.name for m in merged) + ("\n" if merged else ""),
            encoding="utf8",
        )
        print(f"saved {len(merged)} unique names to {OUT_TXT}")
    except Exception as exc:
        print(f"failed to write output file: {exc}")

    try:
        Path(OUT_HTML).write_text(render_html_report(merged), encoding="utf8")
        print(f"saved highlighted HTML report to {OUT_HTML}")
    except Exception as exc:
        print(f"failed to write HTML report: {exc}")

    return 0


class TestHelpers(unittest.TestCase):
    def test_format_empty(self):
        self.assertEqual(format_model_list([]), "Extracted 0 model names.")

    def test_format_multiple(self):
        models = [ModelEntry("a"), ModelEntry("b", True)]
        expected = "Extracted 2 model names:\n1. a\n2. b [PRIVATE]"
        self.assertEqual(format_model_list(models), expected)

    def test_merge_order(self):
        a = [ModelEntry("x"), ModelEntry("y"), ModelEntry("z")]
        b = [ModelEntry("y", True), ModelEntry("q"), ModelEntry("x")]
        merged = merge_unique_preserve_order([a, b])
        self.assertEqual([m.name for m in merged], ["x", "y", "z", "q"])
        self.assertTrue(merged[1].private)

    def test_merge_ignores_empty(self):
        merged = merge_unique_preserve_order(
            [
                [ModelEntry("")],
                [ModelEntry("a"), ModelEntry("")],
                [],
                [ModelEntry("a", True), ModelEntry("b")],
            ]
        )
        self.assertEqual([m.name for m in merged], ["a", "b"])
        self.assertTrue(merged[0].private)

    def test_render_html_private_flag(self):
        html_out = render_html_report([ModelEntry("dianaa_lee", True)])
        self.assertIn("PRIVATE", html_out)
        self.assertIn("class=\"model private\"", html_out)
        self.assertIn("dianaa_lee", html_out)


if __name__ == "__main__":
    raise SystemExit(main())