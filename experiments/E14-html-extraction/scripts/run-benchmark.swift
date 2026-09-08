#!/usr/bin/env swift
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("[e14-runner] error: \(message)\n").utf8))
    exit(2)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: swift run-benchmark.swift <empty-output-directory>")
}

let repo = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = [
    "swift", "test", "-c", "release", "--disable-sandbox",
    "--disable-swift-testing", "-j", "4", "--filter",
    "VecKitTests.HTMLRetrievalExperimentTests/testSyntheticHTMLRetrievalBenchmark",
]
var environment = ProcessInfo.processInfo.environment
environment["VEC_E14_BENCHMARK"] = "1"
environment["VEC_E14_OUTPUT_DIRECTORY"] = CommandLine.arguments[1]
environment["VEC_E14_MODEL_DIRECTORY"] = environment["VEC_E14_MODEL_DIRECTORY"]
    ?? "/private/tmp/vec-e10-model/f52bf8ec8c7124536f0efb74aca902b2995e5bcd"
process.environment = environment
process.currentDirectoryURL = repo
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
