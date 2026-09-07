# E11 sample captions — `generated-b`

## SYNTHETIC content notice

**Every caption file in this directory is SYNTHETIC.** The spoken content
is fictional demonstration prose written for the E11 WebVTT retrieval
experiment. No file is a transcript of a real event, lecture, interview,
or recording. All people, organizations, places, products, dates, model
numbers, and measurements are invented for the demonstration and are **not
factual claims** about the real world. Each `.vtt` file also carries a
`NOTE` block at the top that repeats this notice.

Only the seven `.vtt` files are meant to be indexed by the experiment. The
`source/` prose, `generate.py`, and `check.py` are provenance for human
review; do not index them.

## What is here

| File | Topic | Voice | Style | Cues | Source words |
| --- | --- | --- | --- | ---: | ---: |
| `bike-brake-clinic.vtt` | bicycle brake repair workshop | named dialogue (Priya Raman, Dave Okafor, Tomas) | auto-fragment | 286 | 1237 |
| `wetland-ecology-lecture.vtt` | wetland ecology lecture | unnamed monologue | human captions | 214 | 1718 |
| `telescope-polar-alignment.vtt` | astronomy telescope alignment | unnamed monologue | auto, per-word timestamps | 54 | 290 |
| `ceramic-glaze-studio.vtt` | ceramic glazing studio | unnamed monologue | human captions | 47 | 395 |
| `field-recording-basics.vtt` | audio field-recording tutorial | unnamed monologue | auto, per-word timestamps | 53 | 282 |
| `tram-scheduling-interview.vtt` | urban tram scheduling interview | named dialogue (Interviewer, Lena Fischer) | human captions | 51 | 422 |
| `textile-conservation-talk.vtt` | museum textile conservation | named monologue (Dr. Halvorsen) | human captions | 52 | 405 |

Totals: **7 files, 757 cues, ~4749 source words.**

Cue-count rules for this set:

- The two long files (bicycle, wetland) each have **≥ 200 cues** and their
  source prose is **≥ 1000 words**, fragmented from coherent speech.
- The five short files each have **15–60 cues**.

The counts above come from `check.py` (see below) and match a strict
timing/tag validator (all cue durations are positive; all inline `<i>`,
`<b>`, `<u>`, `<c>`, `<lang>` tags are balanced).

## Voice and style mix

- **Named multi-speaker dialogue** (`<v Name>` on every cue):
  `bike-brake-clinic` and `tram-scheduling-interview`.
- **Named single voice**: `textile-conservation-talk` (`<v Dr. Halvorsen>`).
- **Unnamed human captions**: `wetland-ecology-lecture`,
  `ceramic-glaze-studio`.
- **Auto-caption fragmenting**: `bike-brake-clinic` (short mid-sentence
  cues) and `telescope-polar-alignment` / `field-recording-basics` (short
  cues with per-word `<hh:mm:ss.fff>` inline timestamps).

The two long narratives spread their concrete, memorable details
**throughout** the file, not only at the start.

## WebVTT features exercised

The set varies the structure on purpose so the `vtt-v1` normalizer meets a
range of real-exporter shapes:

- **Headers**: plain `WEBVTT`; `WEBVTT` with a suffix; `WEBVTT` plus
  `Kind:`/`Language:` lines.
- **NOTE blocks**: a SYNTHETIC header note in every file, plus mid-file
  `NOTE` blocks (both the block form and the single-line `NOTE text` form)
  in the two long files.
- **STYLE blocks**: `bike`, `telescope`, `field-recording`, `textile`.
- **REGION blocks + `region:` cue settings**: `wetland` (`lecture`),
  `field-recording` (`notes`), `tram` (`planner`).
- **Cue identifiers**: numeric (`bike`, `ceramic`, `tram`), named
  (`wet-###`, `fld-###`), and none (`telescope`, `textile`).
- **Cue settings**: `align`, `position`, `line`, `size`, `region`, and
  combined settings.
- **Timestamp formats**: `hh:mm:ss.fff` (long files) and `mm:ss.fff`
  (short files); per-word inline timestamps in the two auto files.
- **Inline markup**: `<c.class>`, `<i>`, `<b>`, `<u>`, `<lang>`, and
  `<v Name>` / `<v.class Name>` voices.
- **Entities**: `&amp;`, `&lt;`, `&nbsp;`, `&apos;`, `&#39;`, `&#37;`,
  `&#176;` and `&#xB0;` (degree), `&#xEA;` (ê). All are entities the
  normalizer decodes, so the extracted prose stays clean.

## Notable fictional anchors per topic

These invented details are woven through each file so distinct topics stay
distinguishable. They are demonstration content, **not real facts**.

- **Bicycle**: Ridgeline Community Bike Co-op; Halcyon XT mineral-oil
  hydraulic brakes; mineral oil vs DOT 5.1; 160 mm rotor, 1.5 mm minimum
  thickness; 6 Nm caliper bolts; bleed bottom-to-top; the "Larson twist";
  the wandering bite point; 30-stop bed-in at 30 km/h.
- **Wetland**: the Marsh at Cormorant Bend on the Alder River;
  oligohaline (< 0.5 ppt); Lyngbye's sedge and broadleaf cattail; ~2 m
  peat building 3 mm/yr; ~1.2 tonnes carbon/ha/yr; denitrification vs
  methane; banded marsh chorus frog; the 2019 Alder Slough levee breach;
  feldspar marker-horizon monitoring; the 2021 storm-surge buffering.
- **Telescope**: Meridian GEM-28 mount; Corvus 8-inch Newtonian; latitude
  41.5° at Larkspur Ridge; Polaris on the polar-scope reticle; drift
  alignment to < 0.6 arcsec; Cheshire tube; the primary-mirror doughnut;
  three collimation screws.
- **Ceramic**: Kestrel Clay Studio; cone 6 stoneware (~1222 °C); bisque
  to cone 04; shino, tenmoku, and nuka glazes; the three-second dip; a
  credit-card glaze thickness; wax resist; the crawling defect.
- **Field recording**: Larkfield LR-6 recorder; XY vs ORTF; 48 kHz / 24
  bit; peaks near -12 dBFS; 80 Hz high-pass; the "dead cat" windshield;
  48 V phantom power; 30 seconds of room tone; the dawn chorus.
- **Tram**: city of Nordhavn; Line 4 to Kastellhoj; 6-minute peak headway;
  the 07:42 short-turn at Vestport depot; signal priority; CityRunner 400
  articulated trams; 92 % on-time; the Bjornsson curve; interlining;
  18,000 weekday boardings.
- **Textile**: Ashfield Museum; a 1740 Spitalfields-silk court mantua;
  50 % relative humidity; 50 lux light limit; anoxic nitrogen pest
  treatment; crêpeline support and couching stitches; acid-free storage;
  reversible treatments.

## How the files are made

`generate.py` is deterministic: it reads the clean prose in `source/*.txt`
and adds all WebVTT scaffolding (headers, NOTE/STYLE/REGION blocks, cue
identifiers, settings, inline markup, per-word timestamps, `<v>` voices,
and entities). It uses no randomness and no wall-clock input, so re-running
reproduces byte-identical `.vtt` files. The source prose stays free of
markup so it is easy to read.

Reproduce and self-check (run from anywhere):

```bash
python3 experiments/E11-vtt-extraction/sample/generated-b/generate.py
python3 experiments/E11-vtt-extraction/sample/generated-b/check.py --preview
```

`check.py` reports the cue count, source word count, and a normalized-prose
preview for each file, and flags any file that falls outside its cue/word
bounds. It is a sanity tool, not a bit-exact port of the Swift
`VTTTextNormalizer`: it decodes the supported entities and strips inline
tags, but it does not reproduce the paragraph/overlap rules, which do not
affect cue or word counts.
