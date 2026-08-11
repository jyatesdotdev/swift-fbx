# FBX Scene Dump Format (v1)

Contract between the reference C harness (`tools/ufbx_dump.c`, built against real ufbx)
and the Swift `fbx-dump` executable. Both load an FBX file with **default options** and
emit a JSON document describing the loaded scene. The test suite parses both JSONs and
compares them structurally with numeric tolerance — text formatting does not need to
match, but structure, array ordering, and values do.

## General rules

- Valid JSON, UTF-8. Key order within objects is irrelevant (comparison is structural).
- Array ordering IS significant and must match ufbx's deterministic scene ordering
  (elements appear in `scene.nodes`, `scene.meshes`, … order; SwiftFBX must reproduce
  ufbx's ordering guarantees).
- Numbers: emit with `%.17g` precision for doubles (or Swift's shortest round-trip).
  Non-finite values are emitted as the strings `"nan"`, `"inf"`, `"-inf"`.
- The comparer uses tolerance `|a-b| <= 1e-6 + 1e-6 * max(|a|,|b|)` for all floats.
- Strings are dumped raw (FBX `\x00\x01` name separators never appear in ufbx-level
  names; use the final element name).
- Cross-references between arrays use zero-based indices into the *dump's* arrays
  (e.g. `"mesh": 2` in a node = `meshes[2]`). Missing/none = `-1` or omitted key
  (comparer treats absent key and `-1`/`null` as equal).
- Vectors: `[x, y, z]` arrays. Quaternions: `[x, y, z, w]`. Matrices: ufbx `ufbx_matrix`
  3x4 layout dumped as 12 numbers `[m00,m10,m20, m01,m11,m21, m02,m12,m22, m03,m13,m23]`
  (i.e. columns `cols[0..3]`, each column's xyz).
- Enums are dumped as lower_snake strings mirroring ufbx enum names without the prefix,
  e.g. `UFBX_ROTATION_ORDER_XYZ` → `"xyz"`, `UFBX_INHERIT_MODE_IGNORE_PARENT_SCALE` →
  `"ignore_parent_scale"`, `UFBX_INTERPOLATION_CUBIC` → `"cubic"`.

## Top-level object

```jsonc
{
  "metadata": {
    "version": 7500,            // metadata.version
    "ascii": false,             // metadata.ascii
    "creator": "...",           // metadata.creator
    "big_endian": false,        // metadata.big_endian
    "filename": "maya_cube_7500_binary.fbx"  // basename only
  },
  "settings": {
    "up_axis": "positive_y",    // settings.axes.up (ufbx_coordinate_axis → string)
    "front_axis": "positive_z",
    "right_axis": "positive_x",
    "unit_meters": 0.01,
    "frames_per_second": 24.0,
    "original_unit_meters": 0.01,
    "time_mode": "24_fps",      // ufbx_time_mode → trimmed lower_snake ("UFBX_TIME_MODE_" removed)
    "default_camera": ""
  },
  "nodes": [...], "meshes": [...], "materials": [...], "textures": [...],
  "lights": [...], "cameras": [...], "bones": [...],
  "skin_deformers": [...], "blend_deformers": [...],
  "anim_stacks": [...],
  "evaluate": {...}
}
```

## nodes (scene.nodes order — index 0 is the root node)

```jsonc
{
  "name": "pCube1",
  "parent": -1,                 // index into nodes, -1 for root
  "visible": true,
  "rotation_order": "xyz",
  "inherit_mode": "normal",
  "local_transform": { "translation": [..], "rotation": [x,y,z,w], "scale": [..] },
  "geometry_transform": { "translation": [..], "rotation": [x,y,z,w], "scale": [..] },
  "node_to_world": [12 numbers],
  "node_to_parent": [12 numbers],
  "mesh": 0, "light": -1, "camera": -1, "bone": -1,   // attached elements
  "is_root": true|false
}
```

## meshes (scene.meshes order)

```jsonc
{
  "name": "pCubeShape1",        // element name
  "num_vertices": 8, "num_indices": 24, "num_faces": 6, "num_triangles": 12,
  "num_edges": 12,
  "faces": [[0,4],[4,4],...],   // [index_begin, num_indices] per face
  "vertex_position": { "values": [x,y,z,...], "indices": [i,...] },  // values: num_values*3 reals; indices: num_indices
  "vertex_normal":   { "values": [...], "indices": [...] },          // omit if !exists
  "uv_sets": [ { "name": "map1",
                 "vertex_uv": { "values": [u,v,...], "indices": [...] },
                 "vertex_tangent": {...},      // omit if !exists
                 "vertex_bitangent": {...} } ],
  "color_sets": [ { "name": "colorSet1", "vertex_color": { "values": [r,g,b,a,...], "indices": [...] } } ],
  "vertex_crease": {...}, "edge_crease": [..], "edge_smoothing": [bool...], "face_smoothing": [bool...],
                                // each omitted when absent; edge arrays sized num_edges
  "edges": [[a,b],...],         // edge index pairs (indices into the index stream)
  "face_material": [0,0,...],   // per-face material index (into mesh.materials), omit if empty
  "materials": [0,1],           // indices into top-level materials, mesh.materials order
  "skin_deformers": [0], "blend_deformers": [],
  "instances": [1,4]            // node indices that reference this mesh
}
```

`values` lists are the raw attribute value arrays (`vertex_attrib.values.data`,
length `values.count * N`), `indices` is `vertex_attrib.indices.data` (length
`num_indices`; `UFBX_NO_INDEX` = 0xFFFFFFFF is dumped as `-1`).

## materials (scene.materials order)

```jsonc
{
  "name": "lambert1",
  "shading_model_name": "lambert",
  "fbx": {                      // only maps with has_value or texture; key = ufbx map name
    "diffuse_color":  { "value": [r,g,b,a], "texture": 0 },   // texture: index into textures or -1
    "diffuse_factor": { "value": [f] },
    ...                         // ambient_color, specular_color, specular_exponent, emission_color, ...
  }
}
```

Map keys mirror `ufbx_material_fbx_maps` field names: `diffuse_color, diffuse_factor,
specular_color, specular_factor, specular_exponent, reflection_color, reflection_factor,
transparency_color, transparency_factor, emission_color, emission_factor, ambient_color,
ambient_factor, normal_map, bump, bump_factor, displacement, displacement_factor,
vector_displacement, vector_displacement_factor`. `value` is `value_vec4` truncated to
the map's `value_components` (1, 3 or 4 numbers; 0 components → omit `value`).

## textures (scene.textures order)

```jsonc
{ "name": "file1", "type": "file", "filename": "textures/checker.png",  // relative_filename raw as stored
  "absolute_filename": "", "uv_set": "map1",
  "wrap_u": "repeat", "wrap_v": "repeat", "has_content": false }
```
`absolute_filename` is dumped but NOT compared (machine-specific paths).

## lights / cameras / bones (scene order)

```jsonc
// light
{ "name": "pointLight1", "type": "point", "color": [..], "intensity": 1.0,
  "local_direction": [..], "decay": "quadratic", "area_shape": "rectangle",
  "inner_angle": 40, "outer_angle": 45, "cast_light": true, "cast_shadows": false }
// camera
{ "name": "persp", "projection_mode": "perspective", "resolution_is_pixels": true,
  "resolution": [w,h], "field_of_view_deg": [h,v], "focal_length_mm": 35,
  "aspect_mode": "window_size", "near_plane": 0.1, "far_plane": 10000,
  "orthographic_size": [w,h] }
// bone
{ "name": "joint1", "radius": 0.5, "relative_length": 1.0, "is_root": false }
```

## skin_deformers (scene.skin_deformers order)

```jsonc
{ "name": "skinCluster1", "skinning_method": "linear",
  "clusters": [ { "name": "...", "bone_node": 3,      // node index
                  "num_weights": 24, "vertices": [..], "weights": [..],
                  "geometry_to_bone": [12 numbers], "bind_to_world": [12 numbers] } ],
  "vertices": [ { "weight_begin": 0, "num_weights": 2 }, ... ],   // skin.vertices, per mesh vertex
  "weights":  [ { "cluster": 0, "weight": 0.7 }, ... ] }          // skin.weights
```

## blend_deformers (scene.blend_deformers order)

```jsonc
{ "name": "blendShape1",
  "channels": [ { "name": "target", "weight": 0.0,
                  "keyframes": [ { "target_weight": 1.0, "effective_weight": 0.0, "shape": {
                      "name": "targetShape", "num_offsets": 4,
                      "offset_vertices": [..], "position_offsets": [x,y,z,...] } } ] } ] }
```

## anim_stacks (scene.anim_stacks order)

```jsonc
{ "name": "Take 001", "time_begin": 0.0, "time_end": 1.0,
  "layers": [ {
    "name": "BaseLayer", "weight": 1.0, "additive": false, "compose_rotation": true, "compose_scale": true,
    "anim_props": [ {                       // layer.anim_props order
      "element_name": "pCube1", "element_type": "node",   // ufbx_element_type → string
      "prop_name": "Lcl Translation",
      "default_value": [x,y,z],
      "curves": [                          // up to 3; null for missing component
        { "num_keys": 2, "keys": [
            { "time": 0.0, "value": 1.0, "interpolation": "cubic",
              "left": {"dx": .., "dy": ..}, "right": {"dx": .., "dy": ..} } ] },
        null, null ] } ] } ] }
```

## evaluate

Samples animation evaluation through the full stack: for each anim stack, sample
`ufbx_evaluate_transform(stack.anim, node, t)` for every node at 8 times
`t_i = time_begin + i * (time_end - time_begin) / 7` (i = 0..7; if
`time_end <= time_begin`, use the single time `time_begin`).

```jsonc
{ "stacks": [ { "name": "Take 001", "times": [t0..t7],
    "nodes": [ { "node": 1,
      "translation": [[x,y,z] per time], "rotation": [[x,y,z,w] per time], "scale": [[x,y,z] per time] } ] } ] }
```

Nodes are listed in scene order, skipping the root node.

## Comparer semantics (Tests)

- Structural comparison of parsed JSON; object key order irrelevant.
- Absent key == `null` == `-1` for reference indices; absent == `false` for booleans;
  absent list == empty list.
- Floats: `|a-b| <= 1e-6 + 1e-6*max(|a|,|b|)`; `"nan" == "nan"`.
- `absolute_filename` fields are ignored.
- Everything else must match exactly (ints, strings, enums, array lengths, ordering).
