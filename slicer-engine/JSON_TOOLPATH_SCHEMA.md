# JSON Toolpath Export Structure

This document describes the current JSON emitted by `--export-json` in this fork.

Use this together with:

- `README.md` for execution examples.
- `PARAMETERS_REFERENCE.md` for full parameter meaning.

Source of truth in code:

- `slicer-engine/lib/Slic3r/Print.pm:206` (`toolpaths_as_json_data`)
- `slicer-engine/lib/Slic3r/Print.pm:342` (`_build_layer_events_with_travels`)
- `slicer-engine/lib/Slic3r/Print.pm:478` (`_serialize_entity`)
- `slicer-engine/lib/Slic3r/Print.pm:530` (`_feature_type`)

## Top-level structure

The JSON object currently has these top-level keys:

- `schema_version` (string)
- `generator` (object)
- `summary` (object)
- `print_config` (object)
- `print_level_toolpaths` (object)
- `objects` (array)
- `layers` (array)

Minimal example shape:

```json
{
  "schema_version": "1.0.0",
  "generator": {"name": "Slic3r", "version": "..."},
  "summary": {"object_count": 1, "region_count": 1},
  "print_config": {"layer_height": "0.3", "fill_density": "50%"},
  "print_level_toolpaths": {"skirt": [], "brim": []},
  "objects": [],
  "layers": []
}
```

## Top-level fields

### `schema_version`

- Current value: `"1.0.0"`.

### `generator`

- `name`: slicer name (currently `"Slic3r"`).
- `version`: slicer version (`$Slic3r::VERSION`).

### `summary`

- `object_count`: number of objects in the print.
- `region_count`: number of print regions.
- `total_layer_count`: total layer count from print object.
- `has_support`: boolean.
- `used_filament_mm`: estimated filament length in mm.
- `used_volume_mm3`: estimated extruded volume in mm^3.

### `print_config`

- Full serialized print-level config (`$self->config`), as key/value strings via `serialize()`.
- This object contains the effective runtime values after applying defaults, `--load` profiles,
  and direct CLI overrides for that job.
- See `PARAMETERS_REFERENCE.md` for config/CLI precedence and parameter mapping.

Practical meaning:

- This is the exact config snapshot used to generate the current JSON output.
- Values are serialized strings, even when conceptually numeric/boolean.
- Consumers should parse units/types where needed (`%`, vectors, comma-separated lists, etc.).

### `print_level_toolpaths`

- `skirt`: array of toolpath entities.
- `brim`: array of toolpath entities.

These are print-level (not per-object/per-layer) paths.

### `objects[]`

Per object metadata:

- `object_index`: object ordinal index.
- `object_id`: internal id/pointer fallback.
- `copies`: list of XY copy offsets (`[[x, y], ...]`) in mm.
- `config`: full serialized object-level config.
- `raft_layers`: configured raft layer count for object.

### `layers[]`

Each entry corresponds to one raw layer node emitted from sorted:

- object model layers (`$object->layers`)
- support layers (`$object->support_layers`)

Important: this means `layers[]` can contain support-only entries and multiple adjacent entries near similar heights.

Per-layer fields:

- `layer_seq_id`: monotonically increasing sequence id in export order.
- `object_index`: owner object index.
- `layer_id`: slicer layer id.
- `print_z`: print Z for that raw layer.
- `slice_z`: slice Z (or `null`/missing when unavailable).
- `height`: local layer height.
- `is_support_layer`: boolean.
- `is_raft_layer`: boolean.
- `process`: selected per-layer process settings (see below).
- `regions`: per-region path containers.
- `support`: support path containers.
- `events`: flattened ordered path stream plus synthetic travel links.

## `process` fields (currently included)

Current per-layer `process` block includes:

- `layer_height`
- `print_speed_perimeter`
- `print_speed_infill`
- `print_speed_solid`
- `print_speed_top_solid`
- `support_speed`
- `support_interface_speed`

Values come from object config at export time.

## Region and support containers

### `regions[]`

Each region entry includes:

- `region_id`
- `config`: full serialized region-level config.
- `perimeters`: array of toolpath entities.
- `infill_groups`: array of arrays (grouped infill toolpath entities).

### `support`

- `interface_paths`: array of toolpath entities.
- `support_paths`: array of toolpath entities.

## `events` stream

`events` is a flattened stream intended for easy playback/rendering order.

- Contains all extrusion paths from regions + support.
- Adds synthetic travel records between consecutive extrusion events when endpoints differ.

Ordering note:

- `events` is intended for playback and visualization order at layer scope.
- `regions`/`support` keep structural grouping; `events` keeps execution-like sequence.

Travel event shape:

- `type: "travel"`
- `feature_type: "travel"`
- `points: [[x1,y1,z1],[x2,y2,z2]]`
- plus metadata fields with zero extrusion values.

## Toolpath entity shapes

Entities can be nested or leaf nodes.

### `extrusion_path` (leaf)

- `source`
- `region_id`
- `layer_print_z`
- `type: "extrusion_path"`
- `role_id`
- `role_name`
- `feature_type`
- `is_bridge`
- `is_solid_infill`
- `width`
- `height`
- `mm3_per_mm`
- `point_count`
- `points` (`[[x,y], ...]` in most cases; viewer may inject/use Z fallback)

### `extrusion_loop` (container)

- `type: "extrusion_loop"`
- `feature_type`
- `role_id`
- `role_name: "loop"`
- `path_count`
- `paths` (children entities)

### `path_group` (container)

- `type: "path_group"`
- `feature_type`
- `path_count`
- `paths` (children entities)

## `feature_type` mapping currently used

Derived from path source, role, bridge state, and raft context.

Possible values currently emitted:

- `skirt`
- `brim`
- `support_interface`
- `support`
- `raft_support`
- `bridge`
- `perimeter_external`
- `perimeter_overhang`
- `perimeter_internal`
- `infill_top_solid`
- `infill_solid`
- `infill`
- `gap_fill`
- `raft`
- `travel` (events only)
- `unknown`

## Coordinate and units notes

- Exported XY points are in mm (`unscale()` applied).
- Some path points contain only XY; Z is carried by `layer_print_z` and/or layer metadata.
- Viewer can resolve final Z using per-event `layer_print_z` or layer `print_z`.

## Parameter relationship to JSON output

- Most profile/CLI parameters are reflected under `print_config`.
- Object-level and region-level effective configs are repeated in:
  - `objects[].config`
  - `layers[].regions[].config`
- Process-relevant speed fields are exposed directly per layer in `layers[].process`.

For complete parameter semantics, see `PARAMETERS_REFERENCE.md`.

## Schema evolution guidance

- Current schema tag is `1.0.0`.
- If adding/removing fields, bump schema version and document migration notes.
- Consumers should ignore unknown fields for forward compatibility.

## Practical interpretation notes

- A displayed index is not always a "model layer". Raw `layers[]` includes support layers too.
- It is expected to find entries with only support/travel at certain heights.
- For visualization, grouping by exact or tolerance-based Z is often useful.
