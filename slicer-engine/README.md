# Slicer Engine (CLI)

Standalone CLI slicing engine package based on [Slic3r](https://github.com/slic3r/Slic3r).

## What this project is

`slicer-engine/` is a packaged execution unit of Slic3r CLI (Perl frontend + XS/C++ slicing core),
adapted in this fork to be invoked consistently from command line and from external applications.

## Purpose

- Slice 3D models into G-code using Slic3r-compatible profiles.
- Expose a stable CLI integration path for another application.
- Export structured toolpath JSON (`--export-json`) directly from slicer internals.

## What it is based on

- Upstream Slic3r architecture and config model.
- CLI entrypoint: `slicer-engine/slic3r.pl`.
- Core processing object: `slicer-engine/lib/Slic3r/Print.pm`.

## What has been done in this fork

- Packaged runtime under `slicer-engine/` for easy relocation.
- Added Windows launcher `slicer-engine/run-slicer.bat`.
- Added CLI option path for JSON export (`--export-json`).
- Implemented JSON serialization pipeline for print/layer/path structures.
- Added explicit docs for config precedence, parameter mapping, and JSON contract.

## Changes versus original Slic3r (focus: `lib/` and `xs/`)

This section summarizes relevant engine changes from upstream Slic3r and intentionally ignores
`toolpath-viewer`.

### `lib/` changes (functional)

- `lib/Slic3r/Print.pm`
  - Added `export_toolpaths_json` to export slicing results directly as JSON.
  - Added `toolpaths_as_json_data` to build structured payload with:
    - `summary`
    - `print_config`
    - `print_level_toolpaths`
    - per-object and per-layer data
  - Added support serialization for perimeters, infill groups, support/interface paths.
  - Added `events` stream generation with synthetic `travel` segments between discontinuous paths.
  - Added feature classification (`_feature_type`) for consumer-side rendering/analytics.
  - Added safe helper methods for config/value extraction and serialization.

- `slic3r.pl` (entrypoint, not under `lib/` but part of engine flow)
  - Added `--export-json` CLI switch.
  - Added export branch to call `export_toolpaths_json` instead of G-code export.

### `xs/` status in this package

- No custom JSON feature logic was implemented in `xs/` source for this fork.
- JSON export behavior is implemented in Perl-layer orchestration (`slic3r.pl` + `lib/Slic3r/Print.pm`).
- `local-lib/` includes compiled `Slic3r::XS` runtime artifacts required by the engine, but this
  README does not claim new fork-specific `xs/` feature code for JSON export.

For implementation-level detail by function and behavior, see:

- `FORK_CHANGES_FROM_SLIC3R.md`

For full technical details of code changes vs original Slic3r, see
`slicer-engine/FORK_CHANGES_FROM_SLIC3R.md`.

## Folder contents

- `slic3r.pl`: CLI entrypoint.
- `run-slicer.bat`: Windows launcher.
- `lib/`: Slic3r Perl sources used by the engine.
- `local-lib/`: local Perl dependencies + compiled `Slic3r::XS` module.
- `PARAMETERS_REFERENCE.md`: config precedence, parameter dictionary, value formats, and CLI mapping.
- `JSON_TOOLPATH_SCHEMA.md`: JSON output structure and semantics.
- `FORK_CHANGES_FROM_SLIC3R.md`: detailed implementation changes in this fork.

## Requirements (current package)

This package is not fully self-contained yet. On a clean Windows machine, you need:

1. Strawberry Perl x64.
2. Compatible Boost include/lib paths for this build.
3. Recommended: Microsoft Visual C++ Redistributable 2015-2022 x64.

## Step-by-step setup on another machine

1) Copy full `slicer-engine/` directory (do not copy partial subfolders).

2) Install Strawberry Perl x64 and verify:

```bat
"C:\Strawberry\perl\bin\perl.exe" -v
```

3) Edit `slicer-engine/run-slicer.bat`:

- `PERL_EXE`
- `BOOST_INCLUDEDIR`
- `BOOST_LIBRARYPATH`

4) Smoke test from `cmd` in `slicer-engine/`:

```bat
run-slicer.bat --help
```

If help prints successfully, engine invocation is ready.

## How to use

### Generate G-code with profile

```bat
run-slicer.bat --load "C:\profiles\printer.ini" --output "C:\jobs\part.gcode" "C:\models\part.stl"
```

### Generate JSON toolpaths

```bat
run-slicer.bat --export-json --load "C:\profiles\printer.ini" --output "C:\jobs\part.json" "C:\models\part.stl"
```

### Override profile values from CLI

```bat
run-slicer.bat --load "C:\profiles\printer.ini" --layer-height 0.2 --fill-density 20% --output "C:\jobs\part.gcode" "C:\models\part.stl"
```

### Inspect supported flags from this exact binary

```bat
run-slicer.bat --help
run-slicer.bat --save defaults.ini
```

## Config behavior (important for integration)

Effective config precedence for a job:

1. Internal defaults
2. `--load` profiles (left to right)
3. Direct CLI flags (highest priority)

`print_config` in JSON reflects the final resolved values used in that run.

For detailed parameter usage and override examples, see `slicer-engine/PARAMETERS_REFERENCE.md`.

## Typical integration pattern in another app

1. Build or choose a base `.ini` profile.
2. For each job, execute `run-slicer.bat` with model path.
3. Pass per-job overrides as CLI flags when needed.
4. Read output file (`.gcode` or `.json`).
5. Parse process result by exit code and stdout/stderr.

## Known limitations

- Current package still relies on external Perl/Boost runtime paths.
- Not yet a true no-install portable bundle.

## Troubleshooting

- `perl.exe not found`: fix `PERL_EXE` in `run-slicer.bat`.
- Boost library errors: fix `BOOST_INCLUDEDIR` and `BOOST_LIBRARYPATH`.
- Missing runtime DLL errors: install VC++ redistributable and verify Strawberry Perl.
