#!/usr/bin/env python3
"""Deterministic generator for the E11 WebVTT retrieval sample (generated-a).

SYNTHETIC fixture. Reads the coherent spoken prose in ``sources/*.txt`` and
fragments it into valid WebVTT caption files that deliberately exercise the
``vtt-v1`` normalizer: rolling/paint-on overlap, named <v> voices, inline
c/i/b markup, inline timestamps, NOTE/STYLE/REGION blocks, cue identifiers,
positioning settings, and amp/lt/gt/nbsp plus numeric character references.

The generator is pure and deterministic: no randomness, no clock, no network.
Re-running it reproduces byte-identical ``.vtt`` files. The committed ``.vtt``
files are the indexed sample; the ``sources/*.txt`` are the human-readable
prose the same files were fragmented from. Run:  python3 generate.py

Every person, brand, product, and business name below is a fictional
demonstration and every claim is illustrative, not advice.
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "sources")
PUNCT = ".,!?;:—\"'()[]"


# --------------------------------------------------------------------------
# Per-file configuration
# --------------------------------------------------------------------------

FILES = [
    {
        "src": "01-cooking-sourdough-flatbread.txt",
        "out": "cooking-sourdough-flatbread.vtt",
        "title": "Cooking — sourdough flatbread demo",
        "mode": "rolling",
        "clock": "hms",
        "window": 8, "step": 4, "cue_dur": 2.6, "cue_step": 1.4,
        "ids": "numeric",
        "emphasis_tag": ("c", "term"),
        "emphasis_words": {"hydration", "autolyse", "blistered",
                           "fermentation", "starter"},
        "nbsp_phrases": {("cast", "iron"), ("sea", "salt")},
        "apos": "&#39;",
        "inline_ts": True,
        "settings_cycle": ["align:start position:12%", "align:center",
                           "align:end position:88% size:40%", "",
                           "line:90% align:center"],
        "styles": ["::cue { background: rgba(0,0,0,0.7); }",
                   "::cue(.term) { color: #ffcf6b; font-style: italic; }"],
        "regions": None,
        "notes_at": {40: "chapter marker: the autolyse rest",
                     150: "host holds the dough up to the camera"},
    },
    {
        "src": "02-woodworking-floating-shelf.txt",
        "out": "woodworking-floating-shelf.vtt",
        "title": "Woodworking — hidden-bracket floating shelf",
        "mode": "dialogue",
        "clock": "hms",
        "max_words": 5,
        "sec_per_word": 0.42, "min_dur": 1.2, "gap": 0.2, "turn_gap": 0.5,
        "ids": "named:shelf",
        "emphasis_tag": ("b", None),
        "emphasis_words": {"studs", "torsion", "cleat", "level", "bracket"},
        "nbsp_phrases": set(),
        "apos": None,
        "voice_closed": True,
        "settings_cycle": ["region:room align:start", "align:start", "",
                           "position:15%,line-left align:start"],
        "styles": None,
        "regions": [{"id": "room",
                     "lines": ["id:room", "width:60%", "lines:2",
                               "regionanchor:0%,100%",
                               "viewportanchor:10%,90%", "scroll:up"]}],
        "notes_at": {36: "camera cuts to a close-up of the steel bracket"},
    },
    {
        "src": "03-startup-support-interview.txt",
        "out": "startup-support-interview.vtt",
        "title": "Startup — founder customer-support interview",
        "mode": "dialogue",
        "clock": "hms",
        "max_words": 5,
        "sec_per_word": 0.42, "min_dur": 1.2, "gap": 0.2, "turn_gap": 0.5,
        "ids": "mixed",
        "emphasis_tag": ("c", "kw"),
        "emphasis_words": {"deflection", "macros", "csat", "churn"},
        "nbsp_phrases": set(),
        "apos": "&#x27;",
        "voice_closed": False,
        "settings_cycle": ["align:start", "", "position:80% align:end",
                           "line:15% align:start"],
        "styles": ["::cue { font-family: sans-serif; }",
                   "::cue(.kw) { color: #7cd6ff; font-weight: bold; }"],
        "regions": None,
        "notes_at": {60: "sponsor read omitted from this transcript"},
    },
    {
        "src": "04-physics-pendulum-lecture.txt",
        "out": "physics-pendulum-lecture.vtt",
        "title": "Physics — simple pendulum lecture",
        "mode": "rolling",
        "clock": "hms",
        "window": 8, "step": 4, "cue_dur": 2.7, "cue_step": 1.5,
        "ids": "none",
        "emphasis_tag": ("i", None),
        "emphasis_words": {"isochronism", "damping", "foucault", "harmonic"},
        "nbsp_phrases": {("small", "angle")},
        "apos": None,
        "degree": True,
        "inline_ts": True,
        "settings_cycle": ["region:board align:start", "align:center line:85%",
                           "", "position:20% align:start",
                           "size:60% align:center"],
        "styles": None,
        "regions": [{"id": "board",
                     "lines": ["id:board", "width:55%", "lines:3",
                               "regionanchor:0%,100%",
                               "viewportanchor:12%,88%", "scroll:up"]}],
        "notes_at": {70: "lecturer taps the swinging brass bob",
                     190: "a student question is inaudible here"},
    },
    {
        "src": "05-history-lighthouse-podcast.txt",
        "out": "history-lighthouse-podcast.vtt",
        "title": "History — Gannet Rock lighthouse podcast",
        "mode": "plain",
        "clock": "ms",
        "max_words": 9,
        "sec_per_word": 0.45, "min_dur": 1.4, "gap": 0.25, "para_gap": 5.5,
        "ids": "named:gr",
        "emphasis_tag": ("i", None),
        "emphasis_words": {"fresnel", "keeper", "horn", "automation"},
        "nbsp_phrases": {("gannet", "rock")},
        "apos": None,
        "settings_cycle": ["align:center", "region:beam align:start", "",
                           "line:88% align:center"],
        "styles": None,
        "regions": [{"id": "beam",
                     "lines": ["id:beam", "width:50%", "lines:2",
                               "regionanchor:100%,100%",
                               "viewportanchor:85%,90%"]}],
        "notes_at": {6: "a low musical sting plays under the narration"},
    },
    {
        "src": "06-battery-product-review.txt",
        "out": "battery-product-review.vtt",
        "title": "Review — Nimbus PowerCell X9 battery pack",
        "mode": "plain",
        "clock": "ms",
        "max_words": 9,
        "sec_per_word": 0.45, "min_dur": 1.4, "gap": 0.25, "para_gap": 5.5,
        "ids": "numeric",
        "emphasis_tag": ("b", None),
        "emphasis_words": {"capacity", "output", "watts", "milliamp"},
        "nbsp_phrases": {("carry", "on")},
        "apos": None,
        "settings_cycle": ["align:start", "align:center position:50%", "",
                           "size:70% align:center"],
        "styles": None,
        "regions": None,
        "notes_at": {10: "b-roll pans across the three charging ports"},
    },
    {
        "src": "07-balcony-tomato-gardening.txt",
        "out": "balcony-tomato-gardening.vtt",
        "title": "Gardening — balcony tomatoes in containers",
        "mode": "plain",
        "clock": "ms",
        "max_words": 9,
        "sec_per_word": 0.45, "min_dur": 1.4, "gap": 0.25, "para_gap": 5.5,
        "ids": "none",
        "emphasis_tag": ("i", None),
        "emphasis_words": {"sungold", "indeterminate", "suckers", "calcium"},
        "nbsp_phrases": set(),
        "apos": None,
        "settings_cycle": ["align:center", "", "align:start position:10%"],
        "styles": None,
        "regions": None,
        "notes_at": {4: "cutaway to a five-gallon fabric grow bag"},
    },
    {
        "src": "08-photography-window-light.txt",
        "out": "photography-window-light.vtt",
        "title": "Photography — window-light portraits",
        "mode": "plain",
        "clock": "ms",
        "max_words": 9,
        "sec_per_word": 0.45, "min_dur": 1.4, "gap": 0.25, "para_gap": 5.5,
        "ids": "mixed",
        "emphasis_tag": ("c", "warm"),
        "emphasis_words": {"catchlights", "rembrandt", "softbox", "aperture"},
        "nbsp_phrases": set(),
        "apos": None,
        "settings_cycle": ["align:center", "position:50%,center align:center",
                           "", "vertical:rl align:start"],
        "styles": ["::cue { color: #efefef; }",
                   "::cue(.warm) { color: #f6a13c; }"],
        "regions": None,
        "notes_at": {8: "presenter angles a white foam-board reflector"},
    },
]


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

def fmt_ts(seconds, clock):
    """Format seconds as WebVTT HH:MM:SS.mmm or MM:SS.mmm."""
    ms = int(round(seconds * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    if clock == "hms" or h > 0 or m >= 60:
        return "%02d:%02d:%02d.%03d" % (h, m, s, ms)
    return "%02d:%02d.%03d" % (m, s, ms)


def encode_token(word, cfg):
    """HTML-escape a word and apply the file's numeric-reference encodings."""
    w = word.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    if cfg.get("apos"):
        w = w.replace("'", cfg["apos"])
    if cfg.get("degree"):
        w = w.replace("°", "&#176;")
    return w


def make_tokens(text, cfg):
    """Split prose into [(original, encoded)] tokens."""
    return [(w, encode_token(w, cfg)) for w in text.split()]


def build_units(tokens, cfg):
    """Return display units: emphasis-wrapped words, with nbsp phrase joins."""
    tag, cls = cfg["emphasis_tag"]
    open_tag = "<%s.%s>" % (tag, cls) if cls else "<%s>" % tag
    close_tag = "</%s>" % tag
    marked = []
    for orig, enc in tokens:
        key = orig.strip(PUNCT).lower()
        disp = open_tag + enc + close_tag if key in cfg["emphasis_words"] else enc
        marked.append((key, disp))
    units = []
    i = 0
    while i < len(marked):
        if (i + 1 < len(marked)
                and (marked[i][0], marked[i + 1][0]) in cfg["nbsp_phrases"]):
            units.append(marked[i][1] + "&nbsp;" + marked[i + 1][1])
            i += 2
        else:
            units.append(marked[i][1])
            i += 1
    return units


def cue_id(cfg, index):
    """Return an identifier line for cue ``index`` (0-based) or None."""
    ids = cfg["ids"]
    if ids == "none":
        return None
    if ids == "numeric":
        return str(index + 1)
    if ids.startswith("named:"):
        return "%s-%03d" % (ids.split(":", 1)[1], index + 1)
    if ids == "mixed":
        r = index % 3
        if r == 0:
            return str(index + 1)
        if r == 1:
            return None
        return "cue-%03d" % (index + 1)
    return None


def settings_for(cfg, index):
    cycle = cfg["settings_cycle"]
    return cycle[index % len(cycle)]


# --------------------------------------------------------------------------
# Cue assembly per mode
# --------------------------------------------------------------------------

def rolling_cues(text, cfg):
    """Sliding windows that repeat the tail of the previous window, with
    overlapping timings, exactly like paint-on / rolling auto captions."""
    tokens = make_tokens(text, cfg)
    W, S = cfg["window"], cfg["step"]
    cues = []
    idx = 0
    start_idx = 0
    while start_idx < len(tokens):
        win = tokens[start_idx:start_idx + W]
        if not win:
            break
        units = build_units(win, cfg)
        start = idx * cfg["cue_step"]
        end = start + cfg["cue_dur"]
        if cfg.get("inline_ts"):
            mid = (start + end) / 2.0
            units = units[:len(units) // 2] + ["<%s>" % fmt_ts(mid, cfg["clock"])] \
                + units[len(units) // 2:]
        cues.append({"start": start, "end": end, "text": " ".join(units)})
        idx += 1
        start_idx += S
    return cues


def dialogue_cues(paragraphs, cfg):
    """One turn per source paragraph (``Name: text``), fragmented into short
    voice cues. Sequential, non-overlapping timings so nothing is treated as
    rolling overlap; speaker changes drive the normalizer's paragraph breaks."""
    cues = []
    clock_t = 0.0
    prev_speaker = None
    for para in paragraphs:
        speaker, _, body = para.partition(":")
        speaker = speaker.strip()
        tokens = make_tokens(body.strip(), cfg)
        if not tokens:
            continue
        if prev_speaker is not None:
            clock_t += cfg["turn_gap"] if speaker != prev_speaker else cfg["gap"]
        chunks = [tokens[i:i + cfg["max_words"]]
                  for i in range(0, len(tokens), cfg["max_words"])]
        for j, chunk in enumerate(chunks):
            if j > 0:
                clock_t += cfg["gap"]
            units = build_units(chunk, cfg)
            dur = max(cfg["min_dur"], cfg["sec_per_word"] * len(chunk))
            body_text = " ".join(units)
            if cfg.get("voice_closed"):
                text = "<v %s>%s</v>" % (speaker, body_text)
            else:
                text = "<v %s>%s" % (speaker, body_text)
            cues.append({"start": clock_t, "end": clock_t + dur, "text": text})
            clock_t += dur
        prev_speaker = speaker
    return cues


def plain_cues(paragraphs, cfg):
    """Single-narrator prose, chunked; a >=5 s silence gap between source
    paragraphs so the normalizer reproduces the paragraph structure."""
    cues = []
    clock_t = 0.0
    first_para = True
    for para in paragraphs:
        tokens = make_tokens(para.strip(), cfg)
        if not tokens:
            continue
        if not first_para:
            clock_t += cfg["para_gap"]
        first_para = False
        chunks = [tokens[i:i + cfg["max_words"]]
                  for i in range(0, len(tokens), cfg["max_words"])]
        for j, chunk in enumerate(chunks):
            if j > 0:
                clock_t += cfg["gap"]
            units = build_units(chunk, cfg)
            dur = max(cfg["min_dur"], cfg["sec_per_word"] * len(chunk))
            cues.append({"start": clock_t, "end": clock_t + dur,
                         "text": " ".join(units)})
            clock_t += dur
    return cues


# --------------------------------------------------------------------------
# File emission
# --------------------------------------------------------------------------

def render(cfg):
    with open(os.path.join(SRC, cfg["src"]), encoding="utf-8") as fh:
        raw = fh.read().strip()
    paragraphs = [p.strip() for p in raw.split("\n\n") if p.strip()]

    if cfg["mode"] == "rolling":
        cues = rolling_cues(" ".join(paragraphs), cfg)
    elif cfg["mode"] == "dialogue":
        cues = dialogue_cues(paragraphs, cfg)
    else:
        cues = plain_cues(paragraphs, cfg)

    blocks = []
    blocks.append("WEBVTT - %s (SYNTHETIC)" % cfg["title"])
    blocks.append(
        "NOTE\n"
        "SYNTHETIC caption fixture for the E11 WebVTT extraction experiment.\n"
        "Generated deterministically from sources/%s by generate.py.\n"
        "Topic: %s. Not a real transcript; every name and claim is fictional."
        % (cfg["src"], cfg["title"]))
    if cfg.get("styles"):
        blocks.append("STYLE\n" + "\n".join(cfg["styles"]))
    for region in (cfg.get("regions") or []):
        blocks.append("REGION\n" + "\n".join(region["lines"]))

    notes_at = cfg.get("notes_at") or {}
    for i, cue in enumerate(cues):
        if i in notes_at:
            blocks.append("NOTE " + notes_at[i])
        header = "%s --> %s" % (fmt_ts(cue["start"], cfg["clock"]),
                                fmt_ts(cue["end"], cfg["clock"]))
        setting = settings_for(cfg, i)
        if setting:
            header += " " + setting
        ident = cue_id(cfg, i)
        lines = ([ident] if ident else []) + [header, cue["text"]]
        blocks.append("\n".join(lines))

    return "\n\n".join(blocks) + "\n", len(cues)


def main():
    print("file                                mode      cues")
    print("-" * 56)
    total = 0
    for cfg in FILES:
        content, count = render(cfg)
        with open(os.path.join(HERE, cfg["out"]), "w", encoding="utf-8") as fh:
            fh.write(content)
        total += count
        flag = ""
        if cfg["mode"] in ("rolling", "dialogue"):
            flag = "  LONG(>=200)" if count >= 200 else "  !! short"
        else:
            flag = "  short(15-60)" if 15 <= count <= 60 else "  !! range"
        print("%-35s %-9s %4d%s" % (cfg["out"], cfg["mode"], count, flag))
    print("-" * 56)
    print("total cues: %d" % total)


if __name__ == "__main__":
    main()
