# SQLite-Vector Extension Setup Guide

## Status: ✅ Solution Found

The `vec init` command requires the sqlite-vector extension dylib to be installed on the system. This guide explains how to get it set up.

## Quick Start

### Option 1: Install via npm (Easiest)

If you have Node.js/npm installed:

```bash
npm install @sqliteai/sqlite-vector
cp node_modules/@sqliteai/sqlite-vector-darwin-arm64/vector.dylib /usr/local/lib/
```

### Option 2: Download from GitHub Releases

1. Visit: https://github.com/sqliteai/sqlite-vector/releases/tag/0.9.95
2. Download the macOS ARM64 dylib (or the xcframework zip)
3. Extract and place the `.dylib` file at `/usr/local/lib/vector`

### Option 3: Install via Homebrew (if available)

```bash
brew install sqlite-vector
```

## Verification

After installation, the dylib should be at one of these paths:

```
/usr/local/lib/vector
/opt/homebrew/lib/vector
~/.local/lib/vector
```

Test that it loads:

```bash
sqlite3 << EOF
.load /usr/local/lib/vector
SELECT vector_init('test', 'embedding', 'dimension=512,type=FLOAT32');
EOF
```

## How It Works

The `VectorDatabase` class tries to load the extension from multiple locations:

1. `Bundle.main.bundlePath + "/vector"` - Bundled with the CLI binary
2. `/usr/local/lib/vector` - Standard system location
3. `/opt/homebrew/lib/vector` - Homebrew installation
4. Relative to executable directory
5. `./.vec/vector` - Project-local copy

Once any of these paths are used to place the dylib, `vec init` will successfully:

1. Load the sqlite-vector extension
2. Create the `.vec/index.db` database
3. Initialize the vector search schema
4. Begin indexing files

## About sqlite-vector

**Project**: [sqliteai/sqlite-vector](https://github.com/sqliteai/sqlite-vector)  
**Latest Version**: 0.9.95 (April 7, 2026)  
**License**: Varies by implementation  
**Language**: C (compiled for macOS ARM64)

The extension provides:
- Vector similarity search in SQLite
- Cosine distance metrics
- In-database vector storage
- No external dependencies

## Troubleshooting

### "Failed to load sqlite-vector extension"

This means the dylib couldn't be found at any of the standard paths. Try:

1. Verify the file exists: `ls -la /usr/local/lib/vector`
2. Check file permissions: `chmod +x /usr/local/lib/vector`
3. Try the npm installation method (most reliable)

### macOS Security Warning

If you download unsigned binaries, macOS may block them:

1. Right-click the .dylib → Open (or use `sudo xattr -d com.apple.quarantine`)
2. Or install via Homebrew/npm (pre-verified)

### SQLite version mismatch

Your system has SQLite from the CSQLiteVec system library target. The extension must be compatible with that version. Homebrew's sqlite3 and the system sqlite are usually compatible.

## For Swift Package Developers

If you want to bundle this extension with your package, you have a few options:

### Option A: Vendored XCFramework (Recommended for App Bundles)

```swift
// Package.swift
let package = Package(
    targets: [
        .binaryTarget(
            name: "VectorExtension",
            path: "Frameworks/vector-apple-xcframework.xcframework"
        )
    ]
)
```

However, this only works for app bundles, not CLI tools.

### Option B: Bundled Dylib (For CLI Tools)

Copy the dylib to your executable:

```swift
// In your target's resource bundle
.target(
    name: "vec",
    resources: [.copy("vector.dylib")]
)
```

Then modify `VectorDatabase.loadVectorExtension()` to load from `Bundle.main`.

### Option C: Build from Source

See the [sqlite-vec compilation guide](https://alexgarcia.xyz/sqlite-vec/compiling.html) to compile the extension directly.

## Sources

- [sqliteai/sqlite-vector GitHub](https://github.com/sqliteai/sqlite-vector)
- [sqliteai/sqlite-vector Releases](https://github.com/sqliteai/sqlite-vector/releases)
- [asg017/sqlite-vec (Alternative)](https://github.com/asg017/sqlite-vec)
- [SQLite Load Extension Documentation](https://sqlite.org/loadext.html)
- [npm @sqliteai/sqlite-vector](https://www.npmjs.com/package/@sqliteai/sqlite-vector)
- [PyPI sqliteai-vector](https://pypi.org/project/sqliteai-vector/)

## Next Steps

1. **Install the dylib** using one of the options above
2. **Test**: `swift build && .build/debug/vec init` in a temp directory
3. **Verify**: Check that `.vec/index.db` was created
4. **Index**: The command will begin scanning and indexing files

