# Fork Changes from Original Slic3r

This document describes the relevant changes made in this fork to turn original Slic3r CLI into
an integration-focused engine package with JSON toolpath export.

## Scope

This file focuses on changes under `slicer-engine/` that affect:

- CLI behavior.
- JSON export behavior.
- Runtime packaging and invocation.
- Documentation and integration contract.

## High-level change summary

1. Packaged Slic3r runtime into relocatable `slicer-engine/` folder.
2. Added Windows launcher `run-slicer.bat` for deterministic invocation.
3. Added `--export-json` CLI option path.
4. Added JSON serialization and output write path in `Slic3r::Print`.
5. Added synthetic travel events and feature classification in JSON stream.
6. Added docs for config precedence, parameters, and JSON schema.

## Modified/new files and what each one does

## `slicer-engine/slic3r.pl`

Key changes:

- Registers CLI flag `--export-json` in options parsing.
- Keeps `--export-svg` and G-code export as separate branches.
- In command-line slicing flow, routes execution to:
  - `export_svg` when `--export-svg`
  - `export_toolpaths_json` when `--export-json`
  - `export_gcode` otherwise
- Maintains config merge strategy (defaults + `--load` + CLI options).

Relevant behavior:

- `--export-json` still runs the normal slicing process; output mode changes from G-code to JSON.
- Runtime stats are printed after JSON export as with normal slicing.

Code snippet (actual fork code):

Reference: `slicer-engine/slic3r.pl:43`, `slicer-engine/slic3r.pl:282`.

```perl
# option registration
'export-json'           => $opt{export_json},

# export branch
if ($opt{export_svg}) {
    $sprint->export_svg;
} elsif ($opt{export_json}) {
    $sprint->export_toolpaths_json;
} else {
    $sprint->export_gcode;
}
```

## `slicer-engine/lib/Slic3r/Print.pm`

Main implementation changes for JSON export:

### 1) Added JSON support dependency

- `use JSON::PP;`

### 2) Added `export_toolpaths_json`

Responsibilities:

- Triggers full print processing (`$self->process`).
- Resolves output file path and forces `.json` extension replacement from `.gcode` when needed.
- Builds JSON payload via `toolpaths_as_json_data`.
- Encodes JSON using canonical UTF-8 output (pretty mode enabled by default).
- Writes using temporary file + rename retry pattern (same reliability pattern as G-code export).

Code snippet (actual fork code):

Reference: `slicer-engine/lib/Slic3r/Print.pm:166`.

```perl
sub export_toolpaths_json {
    my $self = shift;
    my %params = @_;

    $self->process;

    my $output_file = $self->output_filepath($params{output_file} // '');
    $output_file =~ s/\.gcode$/.json/i;
    $self->status_cb->(90, "Exporting toolpaths JSON" . ($output_file ? " to $output_file" : ""));

    my $estimated_stats = $self->_estimate_material_usage_via_gcode();

    my $encoder = JSON::PP->new->canonical->utf8;
    $encoder = $encoder->pretty if $params{pretty} // 1;
    my $json = $encoder->encode($self->toolpaths_as_json_data(estimated_stats => $estimated_stats));

    # temp write + rename retry (same pattern as export_gcode)
    ...
}
```

### 3) Added `toolpaths_as_json_data`

Builds top-level JSON object with:

- `schema_version`
- `generator`
- `summary`
- `print_config`
- `print_level_toolpaths`
- `objects`
- `layers`

Design choices:

- Uses slicer internal entities directly instead of parsing emitted G-code.
- Includes support layers in layer stream.
- Includes object and region serialized configs for reproducibility.

Code snippet (top-level object shape):

Reference: `slicer-engine/lib/Slic3r/Print.pm:310`.

```perl
return {
    schema_version => '1.0.0',
    generator => {
        name    => 'Slic3r',
        version => $Slic3r::VERSION,
    },
    summary => {
        object_count      => scalar(@{$self->objects}),
        region_count      => $self->region_count,
        total_layer_count => $self->total_layer_count,
    },
    print_config => _config_to_hash($self->config),
    print_level_toolpaths => { skirt => ..., brim => ... },
    objects => \@objects_data,
    layers  => \@layers_data,
};
```

### 4) Added event stream with synthetic travels

Functions involved:

- `_build_layer_events_with_travels`
- `_flatten_paths`
- `_path_start_point`
- `_path_end_point`

Behavior:

- Flattens extrusion paths from perimeters, infill, and support into ordered event stream.
- Injects synthetic `travel` event when endpoint/startpoint are discontinuous.
- Travel events carry explicit 3D points and zero extrusion metrics.

Code snippet (travel injection):

Reference: `slicer-engine/lib/Slic3r/Print.pm:365`.

```perl
if (defined $x1 && defined $x2 && ($x1 != $x2 || $y1 != $y2 || $z1 != $z2)) {
    push @with_travel, {
        type            => 'travel',
        feature_type    => 'travel',
        source          => 'travel',
        layer_print_z   => $z1,
        mm3_per_mm      => 0,
        point_count     => 2,
        points          => [ [ $x1, $y1, $z1 ], [ $x2, $y2, $z2 ] ],
    };
}
```

### 5) Added entity serialization helpers

Functions involved:

- `_collect_entities`
- `_serialize_entity`
- `_feature_type`
- `_role_name`
- `_bool`
- `_safe_call`, `_safe_num`, `_safe_config_num`
- `_config_to_hash`

Behavior:

- Supports nested entity shapes: `extrusion_path`, `extrusion_loop`, `path_group`.
- Emits geometric points in millimeters (`unscale`).
- Classifies toolpaths into domain-facing feature classes (`perimeter_external`, `support`, `bridge`, etc.).

### 6) Added usage estimation helper for JSON summary

- `_estimate_material_usage_via_gcode`

Behavior:

- Exports to in-memory G-code stream to ensure usage totals are finalized.
- Fails safely with warning and fallback values.

## `slicer-engine/run-slicer.bat`

Launcher purpose:

- Defines runtime environment variables for Perl and Boost.
- Adds Strawberry paths to `PATH`.
- Invokes `slic3r.pl` with all forwarded args (`%*`).

Operational note:

- Current script uses machine-specific absolute paths and must be edited on new machines.

## Documentation files added/updated

- `README.md`: project purpose and operational usage.
- `PARAMETERS_REFERENCE.md`: config precedence, parameter-level meaning, and CLI usage.
- `JSON_TOOLPATH_SCHEMA.md`: output contract and event semantics.

## Behavioral differences vs standard Slic3r CLI usage

- New first-class output mode: `--export-json`.
- Structured path-level output including classified features and synthetic travel segments.
- Runtime snapshot of resolved config in `print_config` block.

## Compatibility and non-goals

- G-code generation path remains available and is still default when `--export-json` is absent.
- JSON schema is fork-specific and should be versioned by consumer.
- This package is not yet fully portable/no-install by default.

## Verification checklist for this fork behavior

1. `run-slicer.bat --help` contains `--export-json`.
2. `--export-json` run creates `.json` output file.
3. JSON includes top-level keys documented in `JSON_TOOLPATH_SCHEMA.md`.
4. JSON `print_config` contains merged effective values.
5. `events` list includes `travel` entries where path discontinuities exist.

## Notes for future maintenance

- If new path entities are introduced upstream, update `_collect_entities` and `_serialize_entity`.
- If config option names evolve, keep `PARAMETERS_REFERENCE.md` synced via `--save defaults.ini`.
- If schema changes, bump `schema_version` and document migration notes.
