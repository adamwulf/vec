# E11 WebVTT retrieval sample — `generated-a`

> **SYNTHETIC fixture.** Every caption file in this directory is machine
> generated for the E11 WebVTT-extraction retrieval experiment. Nothing here
> is a real transcript. All people, brands, products, and businesses
> (`Gus` the starter, `Volt & Bolt` / `Nimbus PowerCell X9`, `Larksail`,
> `Gannet Rock Light`, and the speakers `Mara` / `Devin` / `Theo` /
> `Priya` / `Sam`) are fictional demonstrations, and every number or claim
> is illustrative — not cooking, engineering, medical, legal, or investment
> advice.

## What this is

Eight `.vtt` caption files across eight distinct topics, built to stress the
opt-in `vtt-v1` normalizer (see the experiment [`plan.md`](../../plan.md) and
[`Sources/VecKit/VTTTextNormalizer.swift`](../../../../Sources/VecKit/VTTTextNormalizer.swift)).
The `.vtt` files are the **indexed sample**. The matching
[`sources/`](./sources) `.txt` files are the same spoken prose in plain,
human-readable form, provided so the text can be read quickly before labels
are frozen; they are the input the `.vtt` files were fragmented from, not a
second corpus.

Each topic carries **specific, memorable factual anchors distributed
throughout the narrative** (not front-loaded), so retrieval has real content
to find. See the anchor tables below.

## Provenance — deterministic generation

The `.vtt` files are produced by [`generate.py`](./generate.py), a pure,
deterministic generator (no randomness, no clock, no network). It reads
`sources/*.txt`, fragments the prose into cues, and adds realistic caption
scaffolding (headers, identifiers, timings, positioning, NOTE/STYLE/REGION
blocks, inline markup, and character references). Re-running it reproduces
byte-identical output:

```bash
python3 experiments/E11-vtt-extraction/sample/generated-a/generate.py
```

**Round-trip verified.** The generated captions reconstruct their source
prose exactly. For the two rolling files, applying the normalizer's
overlap-removal rule word-for-word rebuilds the original monologue
(cooking 1093/1093 words, physics 1125/1125). For the two dialogue files the
spoken bodies inside `<v>` tags match the source verbatim (woodworking
1213/1213, startup 1111/1111), and every plain file matches its source
exactly. Cue counts and structural WebVTT validity were self-checked (one
timing line per cue, at most one identifier line, strictly positive
durations, no stray `-->` in identifiers or payloads, LF line endings).

## Inventory and cue statistics

| File | Topic | Voice | Mode | Cues | Src words | Cue IDs |
| ---- | ----- | ----- | ---- | ---: | --------: | ------- |
| `cooking-sourdough-flatbread.vtt` | Sourdough flatbread demo | single narrator (no `<v>`) | **rolling** auto-caption | **274** | 1093 | numeric |
| `woodworking-floating-shelf.vtt` | Hidden-bracket floating shelf | 3 voices: Mara, Devin, Theo | dialogue | **252** | 1213 | named (`shelf-NNN`) |
| `startup-support-interview.vtt` | Founder customer-support interview | 2 voices: Priya, Sam | dialogue | **234** | 1111 | mixed |
| `physics-pendulum-lecture.vtt` | Simple-pendulum lecture | single narrator (no `<v>`) | **rolling** auto-caption | **282** | 1125 | none |
| `history-lighthouse-podcast.vtt` | Gannet Rock lighthouse podcast | single narrator (no `<v>`) | plain | 47 | 392 | named (`gr-NN`) |
| `battery-product-review.vtt` | Nimbus PowerCell X9 review | single narrator (no `<v>`) | plain | 40 | 336 | numeric |
| `balcony-tomato-gardening.vtt` | Balcony container tomatoes | single narrator (no `<v>`) | plain | 44 | 389 | none |
| `photography-window-light.vtt` | Window-light portraits | single narrator (no `<v>`) | plain | 48 | 398 | mixed |

Long files (cooking, woodworking, startup, physics) each have **≥ 200 cues**
and derive from **≥ 1000 words** of unique spoken prose. Short files each
have **15–60 cues**. Total: **1221 cues** across the eight files.

### Rolling / paint-on provenance (cooking + physics)

Cooking and physics are modeled on YouTube-style **rolling auto captions**.
The generator slides a fixed word window across the monologue and steps it
forward by fewer words than the window is wide, so **each cue repeats the
tail of the previous cue** and the cue timings **overlap**:

| File | Window | Step | Repeated tail | Cue length | Start advance |
| ---- | -----: | ---: | ------------: | ---------: | ------------: |
| cooking | 8 words | 4 words | 4 words | 2.6 s | 1.4 s |
| physics | 8 words | 4 words | 4 words | 2.7 s | 1.5 s |

Because each cue starts before the previous one ends, the overlap satisfies
the normalizer's rolling window (`cue.start` within
`[prev.start, prev.end + 0.1 s]`), and the repeated tail is what its
overlap-removal collapses back into continuous prose. Both files also carry
inline karaoke `<hh:mm:ss.fff>` timestamps mid-cue.

### Named-voice dialogue (woodworking + startup)

- **woodworking** — host **Mara**, builder **Devin**, apprentice **Theo**;
  uses **closed** `<v Name>…</v>` tags. Three-way conversation.
- **startup** — interviewer **Priya**, founder **Sam** (of the fictional
  `Larksail`); uses **open** `<v Name>…` tags. Two-way conversation.

Dialogue cues use sequential, non-overlapping timings so nothing is mistaken
for rolling overlap; speaker changes are what drive the normalizer's
paragraph breaks.

## WebVTT feature coverage

| File | STYLE | REGION | Inline tags | Entities |
| ---- | :---: | :----: | ----------- | -------- |
| cooking | ✓ | – | `<c.term>`, inline `<ts>` | `&nbsp;`, `&#39;` (decimal) |
| woodworking | – | ✓ | `<b>`, `<v>` | `&amp;` |
| startup | ✓ | – | `<c.kw>`, `<v>` | `&amp;`, `&#x27;` (hex) |
| physics | – | ✓ | `<i>`, inline `<ts>` | `&lt;`, `&gt;`, `&nbsp;`, `&#176;` (decimal) |
| history | – | ✓ | `<i>` | `&nbsp;` |
| battery | – | – | `<b>` | `&amp;`, `&gt;`, `&nbsp;` |
| balcony | – | – | `<i>` | – |
| photography | ✓ | – | `<c.warm>` | – |

All of `&amp;`, `&lt;`, `&gt;`, `&nbsp;` appear, plus decimal (`&#39;`,
`&#176;`) and hexadecimal (`&#x27;`) numeric references. Every file carries a
header line and a `NOTE` block both marked **SYNTHETIC**; several files add
mid-transcript `NOTE` blocks. Cue timing lines vary positioning settings
(`align`, `position`, `line`, `size`, `vertical`, `region:`), and the region
files reference their `REGION` ids from cue settings.

## Factual anchors → source cue ranges

Approximate cue numbers (1-based, in file order) where each memorable detail
lands, for orientation while reading. These are locators, **not** retrieval
queries — query authoring and label freezing are the manager's task.

**cooking** — 78% hydration → cue 29 · dough into a ~500 °F cast-iron pan →
cue 179 · finished with za'atar → cue 224.

**physics** — period ≈ 2.006 s for a 1 m pendulum → cue 84 · g ≈ 9.81 m/s² →
cue 75 · Foucault pendulum reveals Earth's rotation → cue 249.

**woodworking** — studs 16 in on center → cues 43–44 · bracket rated ~40 lb →
cue 69 · the French-cleat alternative → cues 182–183.

**startup** — median first response under 4 minutes → cue 64 · ~92% CSAT →
cues 120–121 · help center deflects ~30% of tickets → cues 108–109.

**history** — light built 1858 → cues 5–6 · beam visible ~20 nautical miles →
cues 12–13 · first-order Fresnel lens → cue 17.

**battery** — 25,000 mAh capacity → cue 6 · 100 W USB-C output → cue 13 ·
fictional $89 price → cues 37–38.

**balcony** — Sungold cherry variety → cue 7 · 5-gallon container → cues
14–15 · blossom-end rot from uneven watering → cue 29.

**photography** — north-facing window → cue 7 · wide aperture f/2.8 → cues
41–42 · catchlights in the eyes → cue 46.

## Regenerate and re-verify

```bash
# Regenerate all eight .vtt files in place (deterministic):
python3 experiments/E11-vtt-extraction/sample/generated-a/generate.py
```

The `.vtt` files are committed and are the source of truth for indexing; the
generator and `sources/*.txt` are committed alongside them for provenance and
easy reading.
