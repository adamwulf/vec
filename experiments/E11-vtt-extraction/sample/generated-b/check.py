#!/usr/bin/env python3
"""Self-check for the generated-b SYNTHETIC caption set.

For each ``*.vtt`` it reports the cue count and a faithful-enough normalized
prose rendering (header / NOTE / STYLE / REGION stripped, inline tags removed,
the supported entities decoded, cues joined) so cue counts and readability can
be verified without building the Swift normalizer. It is a sanity tool, not a
bit-exact port of ``VTTTextNormalizer``: paragraph/overlap rules are omitted
because they do not affect cue counts or word tallies.

Usage::

    python3 check.py            # summary table
    python3 check.py --preview  # add a prose preview per file
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

TIMING = re.compile(
    r"^\s*((?:\d{2,}:)?\d{2}:\d{2}\.\d{3})\s+-->\s+((?:\d{2,}:)?\d{2}:\d{2}\.\d{3})"
)
TAG = re.compile(r"<[^<>\r\n]*>")
ENTITY = re.compile(r"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
NAMED = {"amp": "&", "lt": "<", "gt": ">", "nbsp": " ", "lrm": "‎",
         "rlm": "‏", "quot": '"', "apos": "'"}


def decode(text):
    def repl(match):
        key = match.group(1)
        if key in NAMED:
            return NAMED[key]
        if key.startswith("#"):
            hexed = key.startswith("#x")
            try:
                value = int(key[2:], 16) if hexed else int(key[1:])
            except ValueError:
                return match.group(0)
            if value != 0:
                try:
                    return chr(value)
                except ValueError:
                    return match.group(0)
        return match.group(0)
    return ENTITY.sub(repl, text)


def normalize(source):
    lines = source.replace("\r\n", "\n").replace("\r", "\n").lstrip("﻿").split("\n")
    cues = 0
    payloads = []
    i = 0
    while i < len(lines):
        if not lines[i].strip():
            i += 1
            continue
        start = i
        while i < len(lines) and lines[i].strip():
            i += 1
        block = lines[start:i]
        head = block[0].strip()
        if head == "WEBVTT" or head.startswith("WEBVTT ") or head == "NOTE" \
                or head.startswith("NOTE ") or head == "STYLE" or head == "REGION":
            continue
        idx = 0 if TIMING.match(block[0]) else 1
        while idx < len(block):
            if not TIMING.match(block[idx]):
                break
            nxt = idx + 1
            while nxt < len(block) and not TIMING.match(block[nxt]):
                nxt += 1
            payload = "\n".join(block[idx + 1:nxt])
            # The Swift normalizer removes inline tags with no separator (only
            # <br> becomes a space), then decodes entities. Mirror that so the
            # preview matches; nbsp decoding still yields word spacing.
            text = decode(TAG.sub("", payload.replace("<br>", " ")))
            text = " ".join(text.split())
            if text:
                cues += 1
                payloads.append(text)
            idx = nxt
    return cues, " ".join(payloads)


def source_words(name):
    path = os.path.join(HERE, "source", name)
    if not os.path.exists(path):
        return 0
    with open(path, encoding="utf-8") as handle:
        body = [ln for ln in handle.read().splitlines() if not ln.startswith("#")]
    return len(" ".join(body).split())


SOURCES = {
    "bike-brake-clinic.vtt": "bike-brake-clinic.txt",
    "wetland-ecology-lecture.vtt": "wetland-ecology-lecture.txt",
    "telescope-polar-alignment.vtt": "telescope-polar-alignment.txt",
    "ceramic-glaze-studio.vtt": "ceramic-glaze-studio.txt",
    "field-recording-basics.vtt": "field-recording-basics.txt",
    "tram-scheduling-interview.vtt": "tram-scheduling-interview.txt",
    "textile-conservation-talk.vtt": "textile-conservation-talk.txt",
}

LONG = {"bike-brake-clinic.vtt", "wetland-ecology-lecture.vtt"}


def main():
    preview = "--preview" in sys.argv
    vtts = sorted(f for f in os.listdir(HERE) if f.endswith(".vtt"))
    print(f"{'file':34s} {'cues':>5s} {'srcW':>6s} {'proseW':>7s}  bounds")
    for name in vtts:
        with open(os.path.join(HERE, name), encoding="utf-8") as handle:
            cues, prose = normalize(handle.read())
        sw = source_words(SOURCES.get(name, ""))
        pw = len(prose.split())
        if name in LONG:
            ok = "OK" if cues >= 200 and sw >= 1000 else "FAIL"
            bound = f"long >=200 cues,>=1000 srcW [{ok}]"
        else:
            ok = "OK" if 15 <= cues <= 60 else "FAIL"
            bound = f"short 15-60 cues [{ok}]"
        print(f"{name:34s} {cues:5d} {sw:6d} {pw:7d}  {bound}")
        if preview:
            print("   ", prose[:240], "...\n")


if __name__ == "__main__":
    main()
