# E11 caption sample

This sample contains **one real file and fifteen synthetic files**. Adam
authorized generating the additional files because `/tmp/LinksDatabase`
contained only one `.vtt`. Synthetic dialogue, people, demonstrations and
product measurements are authored fixtures, not recordings or factual
claims about real people or products. This is a preprocessing/retrieval
fixture study, not a representative sample of the full caption corpus.

- `real/anna-rudolf-minecraft.vtt` is an unchanged copy of
  `/tmp/LinksDatabase/YouTube/__4ZMGgQqKE.localized/__4ZMGgQqKE.en.vtt`.
  It is the caption track accompanying the Anna Rudolf Minecraft item in
  E10's sample. It was read before query labels were written.
- `generated-a/` contains eight synthetic topics, including four long
  recordings and two rolling-caption exports.
- `generated-b/` contains seven further synthetic topics, including two
  long recordings and named multi-speaker captions.

Only `.vtt` files are indexed. README files, generation code and source
prose are provenance/supporting material. Each generated directory
describes its own construction. The files are committed before ranking;
`manifest.json` freezes their byte counts, SHA-256 hashes, cue counts,
voice annotations and rolling-overlap inventory. To verify that frozen
sample, run `python3 experiments/E11-vtt-extraction/scripts/freeze-sample.py --check`.
