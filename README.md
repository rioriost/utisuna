# utisuna

**utisuna [うちすな]** is a tiny macOS command-line tool that sets the default app for the **content type of a sample file**.

In plain English:

```bash
utisuna /path/to/Makefile /Applications/Zed.app
```

uses the content type of `Makefile` and asks macOS to make `Zed.app` the default app for that type.

That means the change applies to the **resolved content type**, not only to one path. For example, if the sample file resolves to `public.make-source`, other Makefiles of the same type will follow the same default app.

## Why this exists

`utisuna` is for the slightly different workflow:

- point at a real file
- point at an app
- let macOS resolve the content type for you
- set the default app for that type

It is intentionally small and boring.

## Requirements

- macOS 12 or later
- Xcode 15+ or a recent Swift toolchain with Swift Package Manager

## Build

```bash
swift build -c release
```

Binary path:

```bash
.build/release/utisuna
```

## Usage

```bash
utisuna [--dry-run] [--verbose] [--role all|editor|viewer|shell|none] <sample-file> <application.app>
```

### Examples

Set Makefiles to open with Zed:

```bash
utisuna /path/to/Makefile /Applications/Zed.app
```

Preview without making changes:

```bash
utisuna --dry-run ~/src/project/Makefile /Applications/Zed.app
```

Set Markdown files to open with BBEdit:

```bash
utisuna ./README.md /Applications/BBEdit.app
```

## Behavior notes

- `utisuna` uses the sample file only to resolve its content type.
- The update is performed through macOS APIs, not by editing Launch Services plist files directly.
- On recent macOS versions, the system may show a confirmation prompt when changing default handlers.
- The `--role` flag is accepted for future expansion and parity with the older Launch Services vocabulary. The current implementation uses the modern file-content-type API, which does not require you to manually resolve a UTI.

## Development

Run tests:

```bash
swift test
```

## Project layout

```text
utisuna/
├── Package.swift
├── README.md
├── Sources/
│   └── utisuna/
│       ├── CLI.swift
│       ├── DefaultAppSetter.swift
│       ├── Runner.swift
│       └── main.swift
└── Tests/
    └── utisunaTests/
        ├── CLITests.swift
        └── RunnerTests.swift
```

## License

Choose whatever license fits your release plans. MIT is a reasonable default for a utility this small.
