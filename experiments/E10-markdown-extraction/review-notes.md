# E10 review notes

## Parser and integration

Two independent reviewers approved `4ec81e8..80a95ab` before the parser was merged:

- `agent-c7a7b35f`: parsing, Unicode byte offsets, nested/reference links, code preservation, frontmatter isolation, and source locations. The 53 Markdown tests and 12 temporary edge-case probes passed.
- `agent-98add89a`: persisted extraction modes, legacy config decoding, update/insert/reset behavior, CLI options, and dependency compatibility. The E10-related suites passed.

Manager post-merge validation: `swift test --disable-sandbox -j 4 --filter 'Markdown|TextExtractionModeTests|ProfileMismatchTests'` passed all 70 selected tests (50 normalizer/extraction, 11 profile mismatch, 6 extraction mode, and 3 existing Markdown extractor tests).

The integration reviewer also ran the full suite: 351 tests executed, 2 skipped, with 6 assertion failures in 2 test cases. The following findings are recorded rather than changing unrelated behavior during the extraction comparison:

- `IndexingProfileTests.testFactoryDefaultAliasIsKnown` still expects `bge-base`, although the default changed to `e5-base` before E10. This stale assertion needs a separate maintenance fix.
- `TrademarkTranscriptFixtureTests.testBatchedEmbedMatchesSingleEmbedForAllBuiltIns` reported five parity failures across GTE, E5, and MXBAI on this host. These inference paths are unchanged by E10. The reviewer attributes them to the existing macOS ANE precision issue; that attribution is not independently established by this experiment. Results measure extraction under the existing runtime, with this limitation.
- E5's single-document path caps the prefixed string at 2,000 characters, while its batch helper caps content before adding the prefix. The benchmark audit follows the batch helper used for indexing. Changing inference would add another variable, so the discrepancy is deferred.
- Lone-CR source line numbering is a pre-existing limitation of the extractor/splitter. E10 fixes CRLF numbering and preserves all line terminators; it does not extend line-number interpretation to classic Mac line endings.
- Conservative frontmatter detection can treat a leading thematic-break section as frontmatter and leave its link syntax untouched. This intentional under-normalization preserves source content.
- Redundant extension lowercasing is harmless for scanner-created input and defensive for other callers. Extraction mismatch taking precedence over an embedder mismatch gives a valid actionable error. The simple `info` display line does not justify a separate output-format test.
- The internal local-model loader is exercised by the forthcoming benchmark. Its addition does not change the default model-loading path.

## Harness

Both reviewers independently approved final harness tip `dc5ea4d`, merged into the manager branch at `7709365`. All reported scorer issues were fixed: score-derived ranks, rejection of inconsistent ordering and nonfinite scores, query filenames independent of the `q` prefix, and accurate pre-tokenizer wording. The manifest labels planned settings as reference values; each frozen run records actual settings. Keeping the audit prefix aligned with the private E5 prefix is documented without expanding the production API.

Post-merge release validation passed 72 tests, with the heavy benchmark separately skipped as intended, using `swift test --disable-sandbox --disable-swift-testing -c release -j 4 --filter 'Markdown|TextExtractionModeTests|ProfileMismatchTests'`. All 12 Python scorer regressions passed. The XCTest-only flag avoids an existing release Swift Testing launcher error after XCTest completes.

Review approval does not imply a retrieval improvement. The first real run is recorded separately as incomplete because even a minimal CoreML operation fails in the manager execution environment.
