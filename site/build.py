#!/usr/bin/env python3
"""Build the static, multi-language Hopp website into site/dist.

Set SITE_URL to the address the site is served from (no trailing slash needed):

    SITE_URL=https://hopp.example.com python3 site/build.py
"""
import html
import json
import os
import re
import shutil
from pathlib import Path

SITE = Path(__file__).resolve().parent
REPO = SITE.parent
DIST = SITE / "dist"

SITE_URL = os.environ.get("SITE_URL", "https://hopp.lightly.dev").rstrip("/")
GITHUB = "https://github.com/lightly-dev/hopp"
RELEASES = f"{GITHUB}/releases/latest"
OG_LOCALES = {"en": "en_US", "zh": "zh_CN", "ja": "ja_JP", "es": "es_ES", "fr": "fr_FR"}

# Crawlers behind AI answers and search. Missing rules already mean "allowed";
# naming them keeps the intent explicit and easy to change per vendor.
AI_CRAWLERS = [
    # OpenAI / ChatGPT
    "GPTBot", "OAI-SearchBot", "ChatGPT-User",
    # Anthropic / Claude
    "ClaudeBot", "Claude-SearchBot", "Claude-User",
    # Google / Gemini
    "Googlebot", "Google-Extended",
    # Perplexity
    "PerplexityBot", "Perplexity-User",
    # Microsoft Copilot
    "Bingbot",
    # Apple Intelligence
    "Applebot", "Applebot-Extended",
    # Others
    "DuckAssistBot", "Meta-ExternalAgent", "Amazonbot", "MistralAI-User",
]

CHEVRON = (
    '<svg class="faq-chev" width="14" height="14" viewBox="0 0 256 256" fill="currentColor" aria-hidden="true">'
    '<path d="M213.66,101.66l-80,80a8,8,0,0,1-11.32,0l-80-80A8,8,0,0,1,53.66,90.34L128,164.69l74.34-74.35a8,8,0,0,1,11.32,11.32Z"></path></svg>'
)

# Runs before first paint: applies the saved theme, and on the root page only
# sends first-time visitors to the page for their browser language.
HEAD_SCRIPT = """(function(){var s=function(k){try{return localStorage.getItem(k)}catch(e){return null}};var t=s('hopp-theme');if(t==='light'||t==='dark')document.documentElement.dataset.theme=t;__REDIRECT__})();"""
ROOT_REDIRECT = (
    "if(!s('hopp-lang')){var c=__CODES__;var w=navigator.languages||[navigator.language||''];"
    "for(var i=0;i<w.length;i++){var l=String(w[i]).toLowerCase().split('-')[0];"
    "if(l==='en')break;if(c.indexOf(l)>=0){location.replace(l+'/'+location.hash);break}}}"
)


def lang_url(code):
    return f"{SITE_URL}/" if code == "en" else f"{SITE_URL}/{code}/"


def json_ld(code, tag, t, version):
    data = {
        "@context": "https://schema.org",
        "@graph": [
            {
                "@type": "SoftwareApplication",
                "name": "Hopp",
                "url": lang_url(code),
                "description": t["metaDesc"],
                "inLanguage": tag,
                "applicationCategory": "UtilitiesApplication",
                "operatingSystem": "macOS 13 or later",
                "softwareVersion": version,
                "downloadUrl": RELEASES,
                "image": f"{SITE_URL}/assets/og.png",
                "license": "https://www.apache.org/licenses/LICENSE-2.0",
                "isAccessibleForFree": True,
                "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
                "sameAs": [GITHUB],
            },
            {
                "@type": "FAQPage",
                "inLanguage": tag,
                "mainEntity": [
                    {
                        "@type": "Question",
                        "name": item["q"],
                        "acceptedAnswer": {"@type": "Answer", "text": item["a"]},
                    }
                    for item in t["faqs"]
                ],
            },
        ],
    }
    return json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")


def render_page(template, languages, code, strings, version):
    t = strings[code]
    tag = next(l["tag"] for l in languages if l["code"] == code)
    name = next(l["label"] for l in languages if l["code"] == code)
    base = "" if code == "en" else "../"

    alternates = [
        f'<link rel="alternate" hreflang="{l["tag"]}" href="{lang_url(l["code"])}">' for l in languages
    ]
    alternates.append(f'<link rel="alternate" hreflang="x-default" href="{lang_url("en")}">')
    og_alternates = [
        f'<meta property="og:locale:alternate" content="{OG_LOCALES[l["code"]]}">'
        for l in languages
        if l["code"] != code
    ]
    links = []
    for l in languages:
        href = base if l["code"] == "en" else f'{base}{l["code"]}/'
        href = href or "./"
        current = ' aria-current="page"' if l["code"] == code else ""
        links.append(
            f'      <li><a href="{href}" hreflang="{l["tag"]}" lang="{l["tag"]}" '
            f'data-lang="{l["code"]}"{current}>{html.escape(l["label"])}</a></li>'
        )
    faq_items = "\n".join(
        f'      <details><summary><h3>{html.escape(item["q"])}</h3>{CHEVRON}</summary>'
        f'<p>{html.escape(item["a"])}</p></details>'
        for item in t["faqs"]
    )

    redirect = ""
    if code == "en":
        codes = json.dumps([l["code"] for l in languages if l["code"] != "en"])
        redirect = ROOT_REDIRECT.replace("__CODES__", codes)

    raw = {
        "alternates": "\n".join(alternates),
        "ogAlternates": "\n".join(og_alternates),
        "langLinks": "\n".join(links),
        "faqItems": faq_items,
        "headScript": HEAD_SCRIPT.replace("__REDIRECT__", redirect),
        "jsonLd": json_ld(code, tag, t, version),
    }
    values = {k: html.escape(v) for k, v in t.items() if isinstance(v, str)}
    values.update(
        tag=tag,
        base=base,
        langName=html.escape(name),
        canonical=lang_url(code),
        ogImage=f"{SITE_URL}/assets/og.png",
        ogImageAlt=html.escape(t["metaTitle"]),
        ogLocale=OG_LOCALES[code],
    )
    values.update(raw)

    def substitute(match):
        key = match.group(1)
        if key not in values:
            raise KeyError(f"template hole with no value: {key}")
        return values[key]

    return re.sub(r"\{\{\s*(\w+)\s*\}\}", substitute, template)


def robots_txt():
    groups = "\n".join(f"User-agent: {name}" for name in AI_CRAWLERS)
    return f"""# Hopp welcomes search engines and AI assistants.
{groups}
Allow: /

User-agent: *
Allow: /

Sitemap: {SITE_URL}/sitemap.xml
"""


def sitemap_xml(languages):
    alternates = "".join(
        f'\n    <xhtml:link rel="alternate" hreflang="{l["tag"]}" href="{lang_url(l["code"])}"/>'
        for l in languages
    ) + f'\n    <xhtml:link rel="alternate" hreflang="x-default" href="{lang_url("en")}"/>'
    urls = "\n".join(
        f'  <url>\n    <loc>{lang_url(l["code"])}</loc>{alternates}\n  </url>' for l in languages
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
        'xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
        f"{urls}\n</urlset>\n"
    )


def llms_txt(languages, strings, version):
    t = strings["en"]
    faq = "\n\n".join(f"### {item['q']}\n\n{item['a']}" for item in t["faqs"])
    pages = "\n".join(f"- [{l['label']}]({lang_url(l['code'])})" for l in languages)
    return f"""# Hopp

> {t['metaDesc']}

Hopp is a keyboard-first window switcher and app launcher for macOS, built with Swift and AppKit. Unlike the built-in ⌘Tab, which lists apps, Hopp lists individual windows. It is under 4 MB, runs in the menu bar, and has no Electron, bundled browser, or background service.

- Current version: {version}
- Platform: macOS 13 or later, on Apple silicon and Intel
- Price and license: free and open source under Apache-2.0
- Interface languages: English, Chinese, Japanese, Spanish, French

## Default keyboard shortcuts

All shortcuts are customizable.

| Shortcut | Action |
| --- | --- |
| ⌘Tab | Switch between windows across all apps |
| ⌘` | Switch windows within the current app |
| ⌘Space | Open the app launcher |
| Type | Search by app name or window title, including pinyin |
| Shift, ↑ or ↓ | Navigate |
| ↩ or release the modifier | Select the window |
| Esc | Dismiss |

## FAQ

{faq}

## Links

- [Download the latest release]({RELEASES})
- [Source code]({GITHUB})
- [README]({GITHUB}#readme)

## Website languages

{pages}
"""


def main():
    data = json.loads((SITE / "i18n.json").read_text(encoding="utf-8"))
    languages, strings = data["languages"], data["strings"]
    template = (SITE / "template.html").read_text(encoding="utf-8")
    version = (REPO / "VERSION").read_text(encoding="utf-8").strip()

    if DIST.exists():
        shutil.rmtree(DIST)
    shutil.copytree(SITE / "static", DIST)
    shutil.copy2(REPO / "assets" / "AppIcon.png", DIST / "assets" / "AppIcon.png")

    for lang in languages:
        code = lang["code"]
        out = DIST / "index.html" if code == "en" else DIST / code / "index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(render_page(template, languages, code, strings, version), encoding="utf-8")

    (DIST / "robots.txt").write_text(robots_txt(), encoding="utf-8")
    (DIST / "sitemap.xml").write_text(sitemap_xml(languages), encoding="utf-8")
    (DIST / "llms.txt").write_text(llms_txt(languages, strings, version), encoding="utf-8")
    print(f"Built {len(languages)} languages into {DIST} for {SITE_URL}")


if __name__ == "__main__":
    main()
