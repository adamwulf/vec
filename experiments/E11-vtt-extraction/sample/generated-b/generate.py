#!/usr/bin/env python3
"""Deterministic generator for the SYNTHETIC WebVTT sample set `generated-b`
of the E11 retrieval experiment.

It reads the clean prose in ``source/*.txt`` and emits one ``*.vtt`` file per
topic. All WebVTT scaffolding is added here, never in the source prose, so the
sources stay readable for review:

  * a ``WEBVTT`` header (some with ``Kind``/``Language`` lines or a suffix),
  * a ``NOTE`` block marking the file SYNTHETIC, plus occasional mid-file
    ``NOTE`` blocks,
  * varied ``STYLE`` and ``REGION`` blocks,
  * cue identifiers (numeric, named, or none) and varied cue settings,
  * inline ``<c>``/``<i>``/``<b>``/``<u>``/``<lang>`` markup and, for the
    auto-caption topics, per-word ``<hh:mm:ss.fff>`` inline timestamps,
  * ``<v Name>`` voices for the dialogue topics, and
  * HTML/WebVTT entities (``&amp;`` ``&lt;`` ``&nbsp;`` ``&quot;`` ``&apos;``
    and decimal/hex numeric references).

The output is fully deterministic: no randomness and no wall-clock input, so
re-running reproduces byte-identical ``.vtt`` files. Only the ``.vtt`` files
are indexed by the experiment; this script and the sources are provenance.

Usage::

    python3 generate.py

Writes the seven ``.vtt`` files next to this script and prints a cue tally.
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "source")

# Private-use sentinels wrap a placeholder index so the entity/markup escape
# pass cannot touch injected markup. Source prose never contains these.
PH_OPEN, PH_CLOSE = "", ""

AUTO_PATTERN = [3, 4, 5, 4, 6, 3, 5, 4]  # words per auto-caption fragment
HUMAN_MIN, HUMAN_MAX = 4, 10             # soft/hard word bounds for human style
BLOCK_GAP = 5.0                          # >=5 s silence -> clean paragraph break


def read_source(name):
    """Return blank-line-separated blocks from a source file, dropping the
    leading ``#`` comment lines and collapsing intra-block newlines."""
    with open(os.path.join(SRC, name), encoding="utf-8") as handle:
        raw = handle.read()
    kept = [line for line in raw.splitlines() if not line.startswith("#")]
    text = "\n".join(kept).strip()
    blocks = []
    for chunk in re.split(r"\n\s*\n", text):
        collapsed = " ".join(chunk.split())
        if collapsed:
            blocks.append(collapsed)
    return blocks


def split_speaker(block, dialogue):
    """Split a dialogue block ``Name: text`` into (speaker, text)."""
    if dialogue and ": " in block:
        speaker, text = block.split(": ", 1)
        return speaker.strip(), text.strip()
    return None, block


def apply_replacements(text, replacements):
    """Replace configured phrases with placeholders, remembering their literal
    (already-escaped, markup-carrying) expansions for restoration later."""
    mapping = {}
    for index, (phrase, literal) in enumerate(
        sorted(replacements, key=lambda pair: len(pair[0]), reverse=True)
    ):
        token = PH_OPEN + str(index) + PH_CLOSE
        pattern = r"(?<!\w)" + re.escape(phrase) + r"(?!\w)"
        new_text, count = re.subn(pattern, token, text)
        if count:
            text = new_text
            mapping[token] = literal
    return text, mapping


def escape(text, char_entities):
    """Escape ``& < >`` then apply per-file quote/apostrophe entities."""
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    for char, entity in char_entities.items():
        text = text.replace(char, entity)
    return text


def restore(text, mapping):
    for token, literal in mapping.items():
        text = text.replace(token, literal)
    return text


def to_payload_text(text, cfg):
    """Turn one clean utterance into a cue-payload string with markup/entities
    injected, ready to be split on whitespace into cues."""
    staged, mapping = apply_replacements(text, cfg["replacements"])
    staged = escape(staged, cfg["char_entities"])
    return restore(staged, mapping)


_STRIP = re.compile(r"<[^>]*>|&[^;\s]+;")


def ends_sentence(token):
    bare = _STRIP.sub("", token).rstrip()
    return bool(bare) and bare[-1] in ".?!,;:"


def fragment(tokens, style, counter, pattern):
    """Yield lists of whitespace tokens per cue. ``counter`` is a one-element
    list used as a running index so the auto pattern varies across the file."""
    fragments = []
    current = []
    for token in tokens:
        current.append(token)
        if style == "auto":
            size = pattern[counter[0] % len(pattern)]
            if len(current) >= size:
                fragments.append(current)
                current = []
                counter[0] += 1
        else:  # human
            if len(current) >= HUMAN_MAX or (
                len(current) >= HUMAN_MIN and ends_sentence(token)
            ):
                fragments.append(current)
                current = []
    if current:
        fragments.append(current)
    return fragments


def fmt_ts(seconds, hours):
    if hours:
        h = int(seconds // 3600)
        m = int((seconds % 3600) // 60)
        s = seconds - h * 3600 - m * 60
        return f"{h:02d}:{m:02d}:{s:06.3f}"
    m = int(seconds // 60)
    s = seconds - m * 60
    return f"{m:02d}:{s:06.3f}"


def cue_payload(tokens, speaker, first_dialogue, cfg, start, duration):
    """Assemble the visible payload line for one cue."""
    if cfg.get("word_timestamps"):
        hours = cfg["ts_hours"]
        parts = [tokens[0]]
        span = max(len(tokens) - 1, 1)
        for i, token in enumerate(tokens[1:], start=1):
            word_time = start + duration * i / span
            parts.append(f"<{fmt_ts(word_time, hours)}>{token}")
        body = " ".join(parts)
    else:
        body = " ".join(tokens)
    if speaker is not None:
        voice = f"<v.{cfg['voice_class']} {speaker}>" if first_dialogue else f"<v {speaker}>"
        return voice + body
    return body


def render(cfg):
    """Build the full .vtt text for one file and return (text, cue_count)."""
    dialogue = cfg["voice_mode"] == "dialogue"
    blocks = read_source(cfg["source"])

    lines = [cfg["header"], ""]
    lines += cfg["note"] + [""]
    for extra in cfg.get("blocks", []):
        lines += extra + [""]

    clock = 0.5
    counter = [0]
    cue_number = 0
    first_dialogue = dialogue
    step_pattern = cfg["durations"]
    auto_pattern = cfg.get("auto_pattern", AUTO_PATTERN)

    for block_index, block in enumerate(blocks):
        speaker, text = split_speaker(block, dialogue)
        if block_index > 0:
            clock += BLOCK_GAP
        payload = to_payload_text(text, cfg)
        tokens = payload.split()
        if not tokens:
            continue
        for frag in fragment(tokens, cfg["style"], counter, auto_pattern):
            duration = step_pattern[cue_number % len(step_pattern)]
            start, end = clock, clock + duration
            clock = end

            if cfg["id_style"] == "numeric":
                lines.append(str(cue_number + 1))
            elif cfg["id_style"] == "named":
                lines.append(f"{cfg['id_prefix']}-{cue_number + 1:03d}")

            timing = f"{fmt_ts(start, cfg['ts_hours'])} --> {fmt_ts(end, cfg['ts_hours'])}"
            setting_pool = cfg.get("settings", [])
            if setting_pool and cue_number % cfg["settings_every"] == 0:
                timing += " " + setting_pool[
                    (cue_number // cfg["settings_every"]) % len(setting_pool)
                ]
            lines.append(timing)

            lines.append(cue_payload(frag, speaker, first_dialogue, cfg, start, duration))
            lines.append("")
            first_dialogue = False
            cue_number += 1

            note = cfg.get("mid_notes", {}).get(cue_number)
            if note:
                lines += note + [""]

    return "\n".join(lines).rstrip("\n") + "\n", cue_number


SYNTHETIC_NOTE = [
    "NOTE",
    "SYNTHETIC demonstration captions generated for the E11 retrieval",
    "experiment. Fictional content only: no real event, person, place, or",
    "product. Human-readable source prose lives in source/{src}.",
]


def note_block(src):
    return [line.format(src=src) for line in SYNTHETIC_NOTE]


CONFIGS = [
    {
        "name": "bike-brake-clinic.vtt",
        "source": "bike-brake-clinic.txt",
        "header": "WEBVTT - Ridgeline Co-op brake clinic\nKind: captions\nLanguage: en",
        "voice_mode": "dialogue",
        "voice_class": "host",
        "style": "auto",
        "ts_hours": True,
        "id_style": "numeric",
        "durations": [1.0, 1.25, 1.5, 1.25, 1.75, 1.0],
        "settings": ["align:start position:12%", "line:-2", "align:middle size:80%",
                     "align:end", "position:50%,line-left"],
        "settings_every": 6,
        "char_entities": {"'": "&apos;"},
        "note": note_block("bike-brake-clinic.txt"),
        "blocks": [[
            "STYLE",
            "::cue { font-family: sans-serif; }",
            "::cue(.tool) { color: yellow; }",
            "::cue(.spec) { color: lime; }",
            "::cue(.warn) { color: red; font-weight: bold; }",
        ]],
        "mid_notes": {132: ["NOTE", "Camera cuts to the bleed-kit close-up; timing continues."]},
        "replacements": [
            ("bite point", "<i>bite&nbsp;point</i>"),
            ("Larson twist", "<b>Larson&nbsp;twist</b>"),
            ("bleed block", "<c.tool>bleed&nbsp;block</c>"),
            ("bleed nipple", "<c.tool>bleed&nbsp;nipple</c>"),
            ("6 Nm", "<b>6&nbsp;Nm</b>"),
            ("2.3 mm", "<c.spec>2.3&nbsp;mm</c>"),
            ("1.5 mm", "<c.spec>1.5&nbsp;mm</c>"),
            ("1.8 mm", "<c.spec>1.8&nbsp;mm</c>"),
            ("160 mm", "<c.spec>160&nbsp;mm</c>"),
            ("DOT 5.1", "<c.warn>DOT&nbsp;5.1</c>"),
        ],
    },
    {
        "name": "wetland-ecology-lecture.vtt",
        "source": "wetland-ecology-lecture.txt",
        "header": "WEBVTT\nKind: captions\nLanguage: en-CA",
        "voice_mode": "mono",
        "style": "human",
        "ts_hours": True,
        "id_style": "named",
        "id_prefix": "wet",
        "durations": [2.4, 2.8, 3.2, 2.8, 3.6, 2.4, 3.0],
        "settings": ["region:lecture align:start", "line:0 position:10%",
                     "align:middle", "region:lecture"],
        "settings_every": 5,
        "char_entities": {"'": "&#39;"},
        "note": note_block("wetland-ecology-lecture.txt"),
        "blocks": [[
            "REGION",
            "id:lecture",
            "width:60%",
            "lines:3",
            "regionanchor:0%,100%",
            "viewportanchor:20%,90%",
            "scroll:up",
        ]],
        "mid_notes": {118: ["NOTE SYNTHETIC - speaker pauses for a slide change."]},
        "replacements": [
            ("Lyngbye's sedge", "<lang la>Lyngbye&#39;s&nbsp;sedge</lang>"),
            ("broadleaf cattail", "<i>broadleaf&nbsp;cattail</i>"),
            ("Phragmites australis", "<i>Phragmites&nbsp;australis</i>"),
            ("carbon sink", "<b>carbon&nbsp;sink</b>"),
            ("blue carbon", "<b>blue&nbsp;carbon</b>"),
            ("under half a part per thousand", "&lt;&nbsp;0.5&nbsp;ppt"),
            ("three millimeters every year", "3&nbsp;mm every year"),
            ("three millimeters a year", "3&nbsp;mm a year"),
            ("1.2 tonnes of carbon per hectare", "1.2&nbsp;tonnes of carbon per hectare"),
            ("nearly two meters deep", "nearly 2&nbsp;m deep"),
        ],
    },
    {
        "name": "telescope-polar-alignment.vtt",
        "source": "telescope-polar-alignment.txt",
        "header": "WEBVTT Meridian GEM-28 alignment",
        "voice_mode": "mono",
        "style": "auto",
        "ts_hours": False,
        "word_timestamps": True,
        "auto_pattern": [5, 6, 7, 5, 6, 4, 6, 5],
        "id_style": "none",
        "durations": [1.1, 1.4, 1.2, 1.6, 1.3],
        "settings": ["align:start", "line:90% align:center", "position:20%"],
        "settings_every": 4,
        "char_entities": {},
        "note": note_block("telescope-polar-alignment.txt"),
        "blocks": [[
            "STYLE",
            "::cue(.reticle) { color: aqua; }",
            "::cue(.tool) { color: orange; }",
        ]],
        "replacements": [
            ("41.5 degrees", "41.5&#xB0;"),
            ("Polaris", "<c.reticle>Polaris</c>"),
            ("drift alignment", "<i>drift&nbsp;alignment</i>"),
            ("under 0.6 arcseconds", "&lt;&nbsp;0.6&nbsp;arcsec"),
            ("within a few arcminutes", "within a few&nbsp;arcmin"),
            ("Cheshire", "<c.tool>Cheshire</c>"),
            ("doughnut", "<i>doughnut</i>"),
        ],
    },
    {
        "name": "ceramic-glaze-studio.vtt",
        "source": "ceramic-glaze-studio.txt",
        "header": "WEBVTT",
        "voice_mode": "mono",
        "style": "human",
        "ts_hours": False,
        "id_style": "numeric",
        "durations": [2.6, 3.0, 3.4, 2.8, 3.2],
        "settings": ["align:start", "align:end size:70%"],
        "settings_every": 4,
        "char_entities": {},
        "note": note_block("ceramic-glaze-studio.txt"),
        "blocks": [],
        "replacements": [
            ("1222 degrees Celsius", "1222&#176;C"),
            ("cone 04", "<b>cone&nbsp;04</b>"),
            ("cone 6", "<b>cone&nbsp;6</b>"),
            ("shino", "<i>shino</i>"),
            ("tenmoku", "<i>tenmoku</i>"),
            ("nuka", "<i>nuka</i>"),
            ("crawling", "<u>crawling</u>"),
            ("credit card", "<i>credit&nbsp;card</i>"),
        ],
    },
    {
        "name": "field-recording-basics.vtt",
        "source": "field-recording-basics.txt",
        "header": "WEBVTT - Larkfield LR-6 field guide",
        "voice_mode": "mono",
        "style": "auto",
        "ts_hours": False,
        "word_timestamps": True,
        "auto_pattern": [5, 6, 7, 5, 6, 4, 6, 5],
        "id_style": "named",
        "id_prefix": "fld",
        "durations": [1.2, 1.5, 1.3, 1.7, 1.1],
        "settings": ["region:notes align:start", "line:0", "align:center"],
        "settings_every": 5,
        "char_entities": {"'": "&#39;"},
        "note": note_block("field-recording-basics.txt"),
        "blocks": [
            ["STYLE", "::cue(.level) { color: #ff5555; }"],
            ["REGION", "id:notes", "width:40%", "lines:2", "scroll:up"],
        ],
        "replacements": [
            ("minus 12 dBFS", "<c.level>-12&nbsp;dBFS</c>"),
            ("48 kHz", "48&nbsp;kHz"),
            ("24 bit", "24&nbsp;bit"),
            ("80 Hz", "80&nbsp;Hz"),
            ("48 volt", "48&nbsp;V"),
            ("dead cat", "<i>dead&nbsp;cat</i>"),
            ("30 seconds", "30&nbsp;seconds"),
            ("ORTF", "<b>ORTF</b>"),
            ("XY", "<b>XY</b>"),
        ],
    },
    {
        "name": "tram-scheduling-interview.vtt",
        "source": "tram-scheduling-interview.txt",
        "header": "WEBVTT\nLanguage: en",
        "voice_mode": "dialogue",
        "voice_class": "host",
        "style": "human",
        "ts_hours": False,
        "id_style": "numeric",
        "durations": [2.6, 3.1, 2.9, 3.4, 2.7],
        "settings": ["region:planner align:start", "align:end", "line:-1"],
        "settings_every": 4,
        "char_entities": {"'": "&apos;"},
        "note": note_block("tram-scheduling-interview.txt"),
        "blocks": [[
            "REGION",
            "id:planner",
            "width:45%",
            "lines:3",
            "regionanchor:100%,100%",
            "viewportanchor:95%,90%",
            "scroll:up",
        ]],
        "replacements": [
            ("CityRunner 400", "<b>CityRunner&nbsp;400</b>"),
            ("Bjornsson curve", "<i>Bjornsson&nbsp;curve</i>"),
            ("signal priority", "<i>signal&nbsp;priority</i>"),
            ("interlining", "<i>interlining</i>"),
            ("18,000 boardings", "18,000&nbsp;boardings"),
            ("Line 4", "<b>Line&nbsp;4</b>"),
            ("12 minutes", "12&nbsp;minutes"),
            ("6 minutes", "<b>6&nbsp;minutes</b>"),
            ("92 percent", "92&#37;"),
            ("07:42", "<i>07:42</i>"),
        ],
    },
    {
        "name": "textile-conservation-talk.vtt",
        "source": "textile-conservation-talk.txt",
        "header": "WEBVTT - Ashfield Museum gallery talk",
        "voice_mode": "dialogue",
        "voice_class": "curator",
        "style": "human",
        "ts_hours": False,
        "id_style": "none",
        "durations": [2.8, 3.2, 3.0, 3.5, 2.6],
        "settings": ["align:start position:10%", "align:middle", "line:85%"],
        "settings_every": 4,
        "char_entities": {},
        "note": note_block("textile-conservation-talk.txt"),
        "blocks": [[
            "STYLE",
            "::cue { background: rgba(0,0,0,0.6); }",
            "::cue(lang) { font-style: italic; }",
        ]],
        "replacements": [
            ("50 percent relative humidity", "50&#37; relative humidity"),
            ("Spitalfields silk", "<i>Spitalfields&nbsp;silk</i>"),
            ("court mantua", "<i>court&nbsp;mantua</i>"),
            ("couching stitches", "<i>couching&nbsp;stitches</i>"),
            ("nitrogen gas", "<b>nitrogen&nbsp;gas</b>"),
            ("acid free", "<i>acid&nbsp;free</i>"),
            ("crepeline", "<lang fr>cr&#xEA;peline</lang>"),
            ("50 lux", "<b>50&nbsp;lux</b>"),
        ],
    },
]


def main():
    for cfg in CONFIGS:
        text, count = render(cfg)
        with open(os.path.join(HERE, cfg["name"]), "w", encoding="utf-8") as handle:
            handle.write(text)
        print(f"{cfg['name']:34s} {count:4d} cues")


if __name__ == "__main__":
    main()
