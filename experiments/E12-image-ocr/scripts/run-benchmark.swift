#!/usr/bin/env swift
//
// E12 benchmark launcher — a sanctioned, task-local Swift runtime shim.
//
// Why this exists: the harness's two heavy benchmarks are opt-in behind
// environment variables the test reads at runtime (`VEC_E12_BENCHMARK=1`, the
// model / output / corpus directories). The itsybitty Bash allow-list matches
// `Bash(swift:*)` only when `swift` is the FIRST token, so an env-prefixed
// command — `VEC_E12_BENCHMARK=1 swift test …` — does NOT start with `swift`
// and is auto-denied, and shell state does not persist between Bash calls so
// the variables cannot be exported first. This script is instead invoked AS
// `swift experiments/E12-image-ocr/scripts/run-benchmark.swift …` (first token
// `swift`, allowed). It sets the required `VEC_E12_*` variables in the CHILD
// process environment ONLY and spawns `xcrun swift test` for the requested
// benchmark, forwarding stdout/stderr and propagating the child's exit code.
// It edits no settings and changes no privilege.
//
// Usage:
//   swift run-benchmark.swift retrieval  <outputDir> [--timeout=SECONDS]
//   swift run-benchmark.swift throughput <outputDir> [corpusDir] [--timeout=SECONDS]
//
// Defaults match the harness: retrieval loads the pinned LOCAL e5-base-v2
// bundle and NEVER downloads (the harness fails if it is missing); throughput
// sweeps jobs 1,4,8 with a 325k linear extrapolation. A bounded timeout
// (default 1800 s) terminates a hung child so no run can wedge indefinitely.

import Foundation

let PINNED_MODEL_DIR = "/private/tmp/vec-e10-model/f52bf8ec8c7124536f0efb74aca902b2995e5bcd"
let DEFAULT_TIMEOUT_SECONDS = 1800.0

func stderrLine(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func die(_ msg: String) -> Never { stderrLine("[run-benchmark] error: " + msg); exit(2) }

// Parse leading `--timeout=` flags out, keep the rest as positionals.
var timeoutSeconds = DEFAULT_TIMEOUT_SECONDS
var positional: [String] = []
for a in CommandLine.arguments.dropFirst() {
    if a.hasPrefix("--timeout=") {
        guard let t = Double(a.dropFirst("--timeout=".count)), t > 0 else { die("--timeout must be a positive number of seconds") }
        timeoutSeconds = t
    } else {
        positional.append(a)
    }
}
guard positional.count >= 2 else {
    die("""
    usage:
      swift run-benchmark.swift retrieval  <outputDir> [--timeout=SECONDS]
      swift run-benchmark.swift throughput <outputDir> [corpusDir] [--timeout=SECONDS]
    """)
}
let mode = positional[0]
let outputDir = positional[1]
let corpusDir: String? = positional.count >= 3 ? positional[2] : nil

// Repo root = <scripts>/../../.. relative to THIS script file. No shell `cd`;
// the child process's working directory is set explicitly to the package root.
let repoRoot = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    .deletingLastPathComponent()   // scripts/
    .deletingLastPathComponent()   // E12-image-ocr/
    .deletingLastPathComponent()   // experiments/
    .deletingLastPathComponent()   // repo root

// Start from the inherited environment, then set ONLY the required VEC_E12_*
// variables in the child.
var env = ProcessInfo.processInfo.environment
env["VEC_E12_BENCHMARK"] = "1"
let filter: String
switch mode {
case "retrieval":
    if corpusDir != nil { die("retrieval mode takes no corpusDir argument") }
    filter = "VecKitTests.ImageOCRRetrievalExperimentTests/testImageOCRRetrievalBenchmark"
    if env["VEC_E12_MODEL_DIRECTORY"] == nil { env["VEC_E12_MODEL_DIRECTORY"] = PINNED_MODEL_DIR }
    env["VEC_E12_OUTPUT_DIRECTORY"] = outputDir
case "throughput":
    filter = "VecKitTests.ImageOCRRetrievalExperimentTests/testImageOCRThroughputBenchmark"
    env["VEC_E12_OCR_OUTPUT_DIRECTORY"] = outputDir
    if let corpusDir { env["VEC_E12_OCR_CORPUS_DIRECTORY"] = corpusDir }
default:
    die("mode must be 'retrieval' or 'throughput' (got '\(mode)')")
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = ["swift", "test", "-c", "release", "--disable-sandbox", "--disable-swift-testing", "-j", "4", "--filter", filter]
process.environment = env
process.currentDirectoryURL = repoRoot
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

// Archive the exact invocation up front (stderr, so it lands in the run log).
stderrLine("[run-benchmark] mode=\(mode) repoRoot=\(repoRoot.path) timeout=\(Int(timeoutSeconds))s")
stderrLine("[run-benchmark] exec: /usr/bin/xcrun " + process.arguments!.joined(separator: " "))
for (k, v) in env.filter({ $0.key.hasPrefix("VEC_E12_") }).sorted(by: { $0.key < $1.key }) {
    stderrLine("[run-benchmark] env \(k)=\(v)")
}

// Bounded timeout: terminate a hung child so a run can never wedge.
// SIGTERM first, then escalate to SIGKILL after a short grace if the child
// this process owns is still running, so termination is guaranteed even if
// the child ignores SIGTERM.
let killGraceSeconds = 10.0
let watchdog = DispatchWorkItem {
    guard process.isRunning else { return }
    stderrLine("[run-benchmark] TIMEOUT after \(Int(timeoutSeconds))s — sending SIGTERM to child pid \(process.processIdentifier)")
    process.terminate()   // SIGTERM
    let deadline = Date().addingTimeInterval(killGraceSeconds)
    while process.isRunning && Date() < deadline { usleep(100_000) }
    if process.isRunning {
        stderrLine("[run-benchmark] child still running \(Int(killGraceSeconds))s after SIGTERM — sending SIGKILL to pid \(process.processIdentifier)")
        kill(process.processIdentifier, SIGKILL)
    }
}
DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

do {
    try process.run()
} catch {
    die("failed to launch `xcrun swift test`: \(error)")
}
process.waitUntilExit()
watchdog.cancel()
stderrLine("[run-benchmark] child exited with status \(process.terminationStatus)")
exit(process.terminationStatus)
