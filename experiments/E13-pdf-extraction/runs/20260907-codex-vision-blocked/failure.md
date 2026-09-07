# Codex-session Vision runtime failure

This is a retained environment failure, not an OCR accuracy result and not a
ranked E13 run.

Commands:

```text
swift test --disable-sandbox --filter PDFOCRReaderTests
swift test --disable-sandbox --filter ImageOCRTests/testRenderedPNGBaselineRecognizesWords
```

Both the new PDF tests and the unchanged E12 positive control failed at the
first Vision request with the same native framework error:

```text
sysctlbyname for kern.hv_vmm_present failed with status -1
Error Domain=NSOSStatusErrorDomain Code=-6662
Failed to create CVPixelBuffer Width = 800, Height = 200, Format = '420f'
```

The PDF page dimensions in the equivalent error were 1224x1584 (ordinary
letter page) and 600x1000 (the asserted 90-degree rotated 500x300 crop box at
144 dpi). The pre-Vision crop and rotation assertions passed. The unchanged
E12 PNG test failing identically establishes that this Codex session cannot be
used to judge the PDF renderer or OCR result. Tests remain assert-or-fail; no
availability skip or fallback masks the failure. The manager arranged a native
runtime execution.
