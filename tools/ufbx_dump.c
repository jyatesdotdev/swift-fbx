// ufbx_dump — reference scene dumper used to generate golden JSON files for the
// SwiftFBX test suite. See docs/DUMP_FORMAT.md for the format contract.
//
// Build: cc -O2 -o ufbx_dump tools/ufbx_dump.c tools/ufbx/ufbx.c -lm
// Usage: ufbx_dump file.fbx > file.json

#include "ufbx/ufbx.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <locale.h>
#include <stddef.h>

// -- Minimal JSON writer with comma tracking

static int j_depth = 0;
static bool j_first[256];

static void j_comma(void) {
    if (j_depth > 0) {
        if (!j_first[j_depth]) fputc(',', stdout);
        j_first[j_depth] = false;
    }
}
static void j_push(char c) { j_comma(); fputc(c, stdout); j_depth++; j_first[j_depth] = true; }
static void j_pop(char c) { j_depth--; fputc(c, stdout); }
static void j_obj(void) { j_push('{'); }
static void j_end_obj(void) { j_pop('}'); }
static void j_arr(void) { j_push('['); }
static void j_end_arr(void) { j_pop(']'); }

static void j_raw_str(const char *s, size_t len) {
    fputc('"', stdout);
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '"': fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (c < 0x20) fprintf(stdout, "\\u%04x", c);
            else fputc(c, stdout);
        }
    }
    fputc('"', stdout);
}
static void j_key(const char *k) { j_comma(); j_raw_str(k, strlen(k)); fputc(':', stdout); j_first[j_depth] = false; // key consumed comma; value must not add one
    // Trick: after a key we want the value emitted without a comma. We temporarily
    // mark depth as "first" so the next emit doesn't add a comma.
    j_first[j_depth] = true;
}
static void j_str(ufbx_string s) { j_comma(); j_raw_str(s.data, s.length); }
static void j_cstr(const char *s) { j_comma(); j_raw_str(s, strlen(s)); }
static void j_num(double v) {
    j_comma();
    if (isnan(v)) fputs("\"nan\"", stdout);
    else if (isinf(v)) fputs(v > 0 ? "\"inf\"" : "\"-inf\"", stdout);
    else fprintf(stdout, "%.17g", v);
}
static void j_int(long long v) { j_comma(); fprintf(stdout, "%lld", v); }
static void j_bool(bool v) { j_comma(); fputs(v ? "true" : "false", stdout); }
static void j_null(void) { j_comma(); fputs("null", stdout); }

static void jk_str(const char *k, ufbx_string s) { j_key(k); j_str(s); }
static void jk_cstr(const char *k, const char *s) { j_key(k); j_cstr(s); }
static void jk_num(const char *k, double v) { j_key(k); j_num(v); }
static void jk_int(const char *k, long long v) { j_key(k); j_int(v); }
static void jk_bool(const char *k, bool v) { j_key(k); j_bool(v); }

static void j_vec3(ufbx_vec3 v) { j_arr(); j_num(v.x); j_num(v.y); j_num(v.z); j_end_arr(); }
static void j_vec2(ufbx_vec2 v) { j_arr(); j_num(v.x); j_num(v.y); j_end_arr(); }
static void j_quat(ufbx_quat q) { j_arr(); j_num(q.x); j_num(q.y); j_num(q.z); j_num(q.w); j_end_arr(); }
static void j_matrix(ufbx_matrix m) {
    j_arr();
    for (int c = 0; c < 4; c++) { j_num(m.cols[c].x); j_num(m.cols[c].y); j_num(m.cols[c].z); }
    j_end_arr();
}
static void j_transform(ufbx_transform t) {
    j_obj();
    j_key("translation"); j_vec3(t.translation);
    j_key("rotation"); j_quat(t.rotation);
    j_key("scale"); j_vec3(t.scale);
    j_end_obj();
}

// -- Enum names

static const char *axis_name(ufbx_coordinate_axis a) {
    switch (a) {
    case UFBX_COORDINATE_AXIS_POSITIVE_X: return "positive_x";
    case UFBX_COORDINATE_AXIS_NEGATIVE_X: return "negative_x";
    case UFBX_COORDINATE_AXIS_POSITIVE_Y: return "positive_y";
    case UFBX_COORDINATE_AXIS_NEGATIVE_Y: return "negative_y";
    case UFBX_COORDINATE_AXIS_POSITIVE_Z: return "positive_z";
    case UFBX_COORDINATE_AXIS_NEGATIVE_Z: return "negative_z";
    default: return "unknown";
    }
}
static const char *time_mode_name(ufbx_time_mode m) {
    switch (m) {
    case UFBX_TIME_MODE_DEFAULT: return "default";
    case UFBX_TIME_MODE_120_FPS: return "120_fps";
    case UFBX_TIME_MODE_100_FPS: return "100_fps";
    case UFBX_TIME_MODE_60_FPS: return "60_fps";
    case UFBX_TIME_MODE_50_FPS: return "50_fps";
    case UFBX_TIME_MODE_48_FPS: return "48_fps";
    case UFBX_TIME_MODE_30_FPS: return "30_fps";
    case UFBX_TIME_MODE_30_FPS_DROP: return "30_fps_drop";
    case UFBX_TIME_MODE_NTSC_DROP_FRAME: return "ntsc_drop_frame";
    case UFBX_TIME_MODE_NTSC_FULL_FRAME: return "ntsc_full_frame";
    case UFBX_TIME_MODE_PAL: return "pal";
    case UFBX_TIME_MODE_24_FPS: return "24_fps";
    case UFBX_TIME_MODE_1000_FPS: return "1000_fps";
    case UFBX_TIME_MODE_FILM_FULL_FRAME: return "film_full_frame";
    case UFBX_TIME_MODE_CUSTOM: return "custom";
    case UFBX_TIME_MODE_96_FPS: return "96_fps";
    case UFBX_TIME_MODE_72_FPS: return "72_fps";
    case UFBX_TIME_MODE_59_94_FPS: return "59_94_fps";
    default: return "unknown";
    }
}
static const char *rotation_order_name(ufbx_rotation_order o) {
    switch (o) {
    case UFBX_ROTATION_ORDER_XYZ: return "xyz";
    case UFBX_ROTATION_ORDER_XZY: return "xzy";
    case UFBX_ROTATION_ORDER_YZX: return "yzx";
    case UFBX_ROTATION_ORDER_YXZ: return "yxz";
    case UFBX_ROTATION_ORDER_ZXY: return "zxy";
    case UFBX_ROTATION_ORDER_ZYX: return "zyx";
    case UFBX_ROTATION_ORDER_SPHERIC: return "spheric";
    default: return "unknown";
    }
}
static const char *inherit_mode_name(ufbx_inherit_mode m) {
    switch (m) {
    case UFBX_INHERIT_MODE_NORMAL: return "normal";
    case UFBX_INHERIT_MODE_IGNORE_PARENT_SCALE: return "ignore_parent_scale";
    case UFBX_INHERIT_MODE_COMPONENTWISE_SCALE: return "componentwise_scale";
    default: return "unknown";
    }
}
static const char *light_type_name(ufbx_light_type t) {
    switch (t) {
    case UFBX_LIGHT_POINT: return "point";
    case UFBX_LIGHT_DIRECTIONAL: return "directional";
    case UFBX_LIGHT_SPOT: return "spot";
    case UFBX_LIGHT_AREA: return "area";
    case UFBX_LIGHT_VOLUME: return "volume";
    default: return "unknown";
    }
}
static const char *light_decay_name(ufbx_light_decay d) {
    switch (d) {
    case UFBX_LIGHT_DECAY_NONE: return "none";
    case UFBX_LIGHT_DECAY_LINEAR: return "linear";
    case UFBX_LIGHT_DECAY_QUADRATIC: return "quadratic";
    case UFBX_LIGHT_DECAY_CUBIC: return "cubic";
    default: return "unknown";
    }
}
static const char *area_shape_name(ufbx_light_area_shape s) {
    switch (s) {
    case UFBX_LIGHT_AREA_SHAPE_RECTANGLE: return "rectangle";
    case UFBX_LIGHT_AREA_SHAPE_SPHERE: return "sphere";
    default: return "unknown";
    }
}
static const char *projection_mode_name(ufbx_projection_mode m) {
    switch (m) {
    case UFBX_PROJECTION_MODE_PERSPECTIVE: return "perspective";
    case UFBX_PROJECTION_MODE_ORTHOGRAPHIC: return "orthographic";
    default: return "unknown";
    }
}
static const char *aspect_mode_name(ufbx_aspect_mode m) {
    switch (m) {
    case UFBX_ASPECT_MODE_WINDOW_SIZE: return "window_size";
    case UFBX_ASPECT_MODE_FIXED_RATIO: return "fixed_ratio";
    case UFBX_ASPECT_MODE_FIXED_RESOLUTION: return "fixed_resolution";
    case UFBX_ASPECT_MODE_FIXED_WIDTH: return "fixed_width";
    case UFBX_ASPECT_MODE_FIXED_HEIGHT: return "fixed_height";
    default: return "unknown";
    }
}
static const char *texture_type_name(ufbx_texture_type t) {
    switch (t) {
    case UFBX_TEXTURE_FILE: return "file";
    case UFBX_TEXTURE_LAYERED: return "layered";
    case UFBX_TEXTURE_PROCEDURAL: return "procedural";
    case UFBX_TEXTURE_SHADER: return "shader";
    default: return "unknown";
    }
}
static const char *wrap_mode_name(ufbx_wrap_mode m) {
    switch (m) {
    case UFBX_WRAP_REPEAT: return "repeat";
    case UFBX_WRAP_CLAMP: return "clamp";
    default: return "unknown";
    }
}
static const char *skinning_method_name(ufbx_skinning_method m) {
    switch (m) {
    case UFBX_SKINNING_METHOD_LINEAR: return "linear";
    case UFBX_SKINNING_METHOD_RIGID: return "rigid";
    case UFBX_SKINNING_METHOD_DUAL_QUATERNION: return "dual_quaternion";
    case UFBX_SKINNING_METHOD_BLENDED_DQ_LINEAR: return "blended_dq_linear";
    default: return "unknown";
    }
}
static const char *interpolation_name(ufbx_interpolation i) {
    switch (i) {
    case UFBX_INTERPOLATION_CONSTANT_PREV: return "constant_prev";
    case UFBX_INTERPOLATION_CONSTANT_NEXT: return "constant_next";
    case UFBX_INTERPOLATION_LINEAR: return "linear";
    case UFBX_INTERPOLATION_CUBIC: return "cubic";
    default: return "unknown";
    }
}
static const char *element_type_name(ufbx_element_type t) {
    switch (t) {
    case UFBX_ELEMENT_UNKNOWN: return "unknown";
    case UFBX_ELEMENT_NODE: return "node";
    case UFBX_ELEMENT_MESH: return "mesh";
    case UFBX_ELEMENT_LIGHT: return "light";
    case UFBX_ELEMENT_CAMERA: return "camera";
    case UFBX_ELEMENT_BONE: return "bone";
    case UFBX_ELEMENT_EMPTY: return "empty";
    case UFBX_ELEMENT_MATERIAL: return "material";
    case UFBX_ELEMENT_TEXTURE: return "texture";
    case UFBX_ELEMENT_ANIM_STACK: return "anim_stack";
    case UFBX_ELEMENT_ANIM_LAYER: return "anim_layer";
    case UFBX_ELEMENT_ANIM_VALUE: return "anim_value";
    case UFBX_ELEMENT_ANIM_CURVE: return "anim_curve";
    case UFBX_ELEMENT_SKIN_DEFORMER: return "skin_deformer";
    case UFBX_ELEMENT_SKIN_CLUSTER: return "skin_cluster";
    case UFBX_ELEMENT_BLEND_DEFORMER: return "blend_deformer";
    case UFBX_ELEMENT_BLEND_CHANNEL: return "blend_channel";
    case UFBX_ELEMENT_BLEND_SHAPE: return "blend_shape";
    default: {
        static char buf[32];
        snprintf(buf, sizeof buf, "element_%d", (int)t);
        return buf;
    }
    }
}

// -- Dump helpers

static void dump_vertex_attrib(const char *key, const ufbx_vertex_attrib *attrib) {
    if (!attrib->exists) return;
    j_key(key);
    j_obj();
    j_key("values");
    j_arr();
    const ufbx_real *reals = (const ufbx_real *)attrib->values.data;
    size_t num_reals = attrib->values.count * attrib->value_reals;
    for (size_t i = 0; i < num_reals; i++) j_num(reals[i]);
    j_end_arr();
    j_key("indices");
    j_arr();
    for (size_t i = 0; i < attrib->indices.count; i++) {
        uint32_t ix = attrib->indices.data[i];
        j_int(ix == UFBX_NO_INDEX ? -1 : (long long)ix);
    }
    j_end_arr();
    j_end_obj();
}

static void dump_material_map(const char *key, const ufbx_material_map *map) {
    if (!map->has_value && !map->texture) return;
    j_key(key);
    j_obj();
    if (map->has_value && map->value_components > 0) {
        j_key("value");
        j_arr();
        const ufbx_real *v = &map->value_vec4.x;
        for (size_t i = 0; i < map->value_components && i < 4; i++) j_num(v[i]);
        j_end_arr();
    }
    if (map->texture) jk_int("texture", (long long)map->texture->typed_id);
    j_end_obj();
}

int main(int argc, char **argv) {
    setlocale(LC_ALL, "C");
    if (argc != 2) { fprintf(stderr, "usage: ufbx_dump file.fbx\n"); return 2; }

    ufbx_load_opts opts = { 0 };
    ufbx_error error;
    ufbx_scene *scene = ufbx_load_file(argv[1], &opts, &error);
    if (!scene) {
        char buf[1024];
        ufbx_format_error(buf, sizeof buf, &error);
        fprintf(stderr, "load failed: %s\n", buf);
        return 1;
    }

    const char *base = strrchr(argv[1], '/');
    base = base ? base + 1 : argv[1];

    j_obj();

    // metadata
    j_key("metadata");
    j_obj();
    jk_int("version", scene->metadata.version);
    jk_bool("ascii", scene->metadata.ascii);
    jk_str("creator", scene->metadata.creator);
    jk_bool("big_endian", scene->metadata.big_endian);
    jk_cstr("filename", base);
    j_end_obj();

    // settings
    j_key("settings");
    j_obj();
    jk_cstr("up_axis", axis_name(scene->settings.axes.up));
    jk_cstr("front_axis", axis_name(scene->settings.axes.front));
    jk_cstr("right_axis", axis_name(scene->settings.axes.right));
    jk_num("unit_meters", scene->settings.unit_meters);
    jk_num("frames_per_second", scene->settings.frames_per_second);
    jk_num("original_unit_meters", scene->settings.original_unit_meters);
    jk_cstr("time_mode", time_mode_name(scene->settings.time_mode));
    jk_str("default_camera", scene->settings.default_camera);
    j_end_obj();

    // nodes
    j_key("nodes");
    j_arr();
    for (size_t i = 0; i < scene->nodes.count; i++) {
        ufbx_node *node = scene->nodes.data[i];
        j_obj();
        jk_str("name", node->name);
        jk_int("parent", node->parent ? (long long)node->parent->typed_id : -1);
        jk_bool("visible", node->visible);
        jk_cstr("rotation_order", rotation_order_name(node->rotation_order));
        jk_cstr("inherit_mode", inherit_mode_name(node->inherit_mode));
        j_key("local_transform"); j_transform(node->local_transform);
        j_key("geometry_transform"); j_transform(node->geometry_transform);
        j_key("node_to_world"); j_matrix(node->node_to_world);
        j_key("node_to_parent"); j_matrix(node->node_to_parent);
        jk_int("mesh", node->mesh ? (long long)node->mesh->typed_id : -1);
        jk_int("light", node->light ? (long long)node->light->typed_id : -1);
        jk_int("camera", node->camera ? (long long)node->camera->typed_id : -1);
        jk_int("bone", node->bone ? (long long)node->bone->typed_id : -1);
        jk_bool("is_root", node->is_root);
        j_end_obj();
    }
    j_end_arr();

    // meshes
    j_key("meshes");
    j_arr();
    for (size_t i = 0; i < scene->meshes.count; i++) {
        ufbx_mesh *mesh = scene->meshes.data[i];
        j_obj();
        jk_str("name", mesh->name);
        jk_int("num_vertices", (long long)mesh->num_vertices);
        jk_int("num_indices", (long long)mesh->num_indices);
        jk_int("num_faces", (long long)mesh->num_faces);
        jk_int("num_triangles", (long long)mesh->num_triangles);
        jk_int("num_edges", (long long)mesh->num_edges);
        j_key("faces");
        j_arr();
        for (size_t f = 0; f < mesh->faces.count; f++) {
            j_arr();
            j_int(mesh->faces.data[f].index_begin);
            j_int(mesh->faces.data[f].num_indices);
            j_end_arr();
        }
        j_end_arr();
        dump_vertex_attrib("vertex_position", (const ufbx_vertex_attrib *)&mesh->vertex_position);
        dump_vertex_attrib("vertex_normal", (const ufbx_vertex_attrib *)&mesh->vertex_normal);
        dump_vertex_attrib("vertex_crease", (const ufbx_vertex_attrib *)&mesh->vertex_crease);

        j_key("uv_sets");
        j_arr();
        for (size_t s = 0; s < mesh->uv_sets.count; s++) {
            ufbx_uv_set *set = &mesh->uv_sets.data[s];
            j_obj();
            jk_str("name", set->name);
            dump_vertex_attrib("vertex_uv", (const ufbx_vertex_attrib *)&set->vertex_uv);
            dump_vertex_attrib("vertex_tangent", (const ufbx_vertex_attrib *)&set->vertex_tangent);
            dump_vertex_attrib("vertex_bitangent", (const ufbx_vertex_attrib *)&set->vertex_bitangent);
            j_end_obj();
        }
        j_end_arr();

        j_key("color_sets");
        j_arr();
        for (size_t s = 0; s < mesh->color_sets.count; s++) {
            ufbx_color_set *set = &mesh->color_sets.data[s];
            j_obj();
            jk_str("name", set->name);
            dump_vertex_attrib("vertex_color", (const ufbx_vertex_attrib *)&set->vertex_color);
            j_end_obj();
        }
        j_end_arr();

        if (mesh->edges.count > 0) {
            j_key("edges");
            j_arr();
            for (size_t e = 0; e < mesh->edges.count; e++) {
                j_arr(); j_int(mesh->edges.data[e].a); j_int(mesh->edges.data[e].b); j_end_arr();
            }
            j_end_arr();
        }
        if (mesh->edge_smoothing.count > 0) {
            j_key("edge_smoothing");
            j_arr();
            for (size_t e = 0; e < mesh->edge_smoothing.count; e++) j_bool(mesh->edge_smoothing.data[e]);
            j_end_arr();
        }
        if (mesh->edge_crease.count > 0) {
            j_key("edge_crease");
            j_arr();
            for (size_t e = 0; e < mesh->edge_crease.count; e++) j_num(mesh->edge_crease.data[e]);
            j_end_arr();
        }
        if (mesh->face_smoothing.count > 0) {
            j_key("face_smoothing");
            j_arr();
            for (size_t f = 0; f < mesh->face_smoothing.count; f++) j_bool(mesh->face_smoothing.data[f]);
            j_end_arr();
        }
        if (mesh->face_material.count > 0) {
            j_key("face_material");
            j_arr();
            for (size_t f = 0; f < mesh->face_material.count; f++) j_int(mesh->face_material.data[f]);
            j_end_arr();
        }
        j_key("materials");
        j_arr();
        for (size_t m = 0; m < mesh->materials.count; m++) j_int(mesh->materials.data[m]->typed_id);
        j_end_arr();
        j_key("skin_deformers");
        j_arr();
        for (size_t d = 0; d < mesh->skin_deformers.count; d++) j_int(mesh->skin_deformers.data[d]->typed_id);
        j_end_arr();
        j_key("blend_deformers");
        j_arr();
        for (size_t d = 0; d < mesh->blend_deformers.count; d++) j_int(mesh->blend_deformers.data[d]->typed_id);
        j_end_arr();
        j_key("instances");
        j_arr();
        for (size_t n = 0; n < mesh->instances.count; n++) j_int(mesh->instances.data[n]->typed_id);
        j_end_arr();
        j_end_obj();
    }
    j_end_arr();

    // materials
    j_key("materials");
    j_arr();
    for (size_t i = 0; i < scene->materials.count; i++) {
        ufbx_material *mat = scene->materials.data[i];
        j_obj();
        jk_str("name", mat->name);
        jk_str("shading_model_name", mat->shading_model_name);
        j_key("fbx");
        j_obj();
        dump_material_map("diffuse_color", &mat->fbx.diffuse_color);
        dump_material_map("diffuse_factor", &mat->fbx.diffuse_factor);
        dump_material_map("specular_color", &mat->fbx.specular_color);
        dump_material_map("specular_factor", &mat->fbx.specular_factor);
        dump_material_map("specular_exponent", &mat->fbx.specular_exponent);
        dump_material_map("reflection_color", &mat->fbx.reflection_color);
        dump_material_map("reflection_factor", &mat->fbx.reflection_factor);
        dump_material_map("transparency_color", &mat->fbx.transparency_color);
        dump_material_map("transparency_factor", &mat->fbx.transparency_factor);
        dump_material_map("emission_color", &mat->fbx.emission_color);
        dump_material_map("emission_factor", &mat->fbx.emission_factor);
        dump_material_map("ambient_color", &mat->fbx.ambient_color);
        dump_material_map("ambient_factor", &mat->fbx.ambient_factor);
        dump_material_map("normal_map", &mat->fbx.normal_map);
        dump_material_map("bump", &mat->fbx.bump);
        dump_material_map("bump_factor", &mat->fbx.bump_factor);
        dump_material_map("displacement", &mat->fbx.displacement);
        dump_material_map("displacement_factor", &mat->fbx.displacement_factor);
        dump_material_map("vector_displacement", &mat->fbx.vector_displacement);
        dump_material_map("vector_displacement_factor", &mat->fbx.vector_displacement_factor);
        j_end_obj();
        j_end_obj();
    }
    j_end_arr();

    // textures
    j_key("textures");
    j_arr();
    for (size_t i = 0; i < scene->textures.count; i++) {
        ufbx_texture *tex = scene->textures.data[i];
        j_obj();
        jk_str("name", tex->name);
        jk_cstr("type", texture_type_name(tex->type));
        jk_str("filename", tex->relative_filename);
        jk_str("absolute_filename", tex->absolute_filename);
        jk_str("uv_set", tex->uv_set);
        jk_cstr("wrap_u", wrap_mode_name(tex->wrap_u));
        jk_cstr("wrap_v", wrap_mode_name(tex->wrap_v));
        jk_bool("has_content", tex->content.size > 0);
        j_end_obj();
    }
    j_end_arr();

    // lights
    j_key("lights");
    j_arr();
    for (size_t i = 0; i < scene->lights.count; i++) {
        ufbx_light *light = scene->lights.data[i];
        j_obj();
        jk_str("name", light->name);
        jk_cstr("type", light_type_name(light->type));
        j_key("color"); j_vec3(light->color);
        jk_num("intensity", light->intensity);
        j_key("local_direction"); j_vec3(light->local_direction);
        jk_cstr("decay", light_decay_name(light->decay));
        jk_cstr("area_shape", area_shape_name(light->area_shape));
        jk_num("inner_angle", light->inner_angle);
        jk_num("outer_angle", light->outer_angle);
        jk_bool("cast_light", light->cast_light);
        jk_bool("cast_shadows", light->cast_shadows);
        j_end_obj();
    }
    j_end_arr();

    // cameras
    j_key("cameras");
    j_arr();
    for (size_t i = 0; i < scene->cameras.count; i++) {
        ufbx_camera *cam = scene->cameras.data[i];
        j_obj();
        jk_str("name", cam->name);
        jk_cstr("projection_mode", projection_mode_name(cam->projection_mode));
        jk_bool("resolution_is_pixels", cam->resolution_is_pixels);
        j_key("resolution"); j_vec2(cam->resolution);
        j_key("field_of_view_deg"); j_vec2(cam->field_of_view_deg);
        jk_num("focal_length_mm", cam->focal_length_mm);
        jk_cstr("aspect_mode", aspect_mode_name(cam->aspect_mode));
        jk_num("near_plane", cam->near_plane);
        jk_num("far_plane", cam->far_plane);
        j_key("orthographic_size"); j_vec2(cam->orthographic_size);
        j_end_obj();
    }
    j_end_arr();

    // bones
    j_key("bones");
    j_arr();
    for (size_t i = 0; i < scene->bones.count; i++) {
        ufbx_bone *bone = scene->bones.data[i];
        j_obj();
        jk_str("name", bone->name);
        jk_num("radius", bone->radius);
        jk_num("relative_length", bone->relative_length);
        jk_bool("is_root", bone->is_root);
        j_end_obj();
    }
    j_end_arr();

    // skin deformers
    j_key("skin_deformers");
    j_arr();
    for (size_t i = 0; i < scene->skin_deformers.count; i++) {
        ufbx_skin_deformer *skin = scene->skin_deformers.data[i];
        j_obj();
        jk_str("name", skin->name);
        jk_cstr("skinning_method", skinning_method_name(skin->skinning_method));
        j_key("clusters");
        j_arr();
        for (size_t c = 0; c < skin->clusters.count; c++) {
            ufbx_skin_cluster *cluster = skin->clusters.data[c];
            j_obj();
            jk_str("name", cluster->name);
            jk_int("bone_node", cluster->bone_node ? (long long)cluster->bone_node->typed_id : -1);
            jk_int("num_weights", (long long)cluster->num_weights);
            j_key("vertices");
            j_arr();
            for (size_t w = 0; w < cluster->vertices.count; w++) j_int(cluster->vertices.data[w]);
            j_end_arr();
            j_key("weights");
            j_arr();
            for (size_t w = 0; w < cluster->weights.count; w++) j_num(cluster->weights.data[w]);
            j_end_arr();
            j_key("geometry_to_bone"); j_matrix(cluster->geometry_to_bone);
            j_key("bind_to_world"); j_matrix(cluster->bind_to_world);
            j_end_obj();
        }
        j_end_arr();
        j_key("vertices");
        j_arr();
        for (size_t v = 0; v < skin->vertices.count; v++) {
            j_obj();
            jk_int("weight_begin", skin->vertices.data[v].weight_begin);
            jk_int("num_weights", skin->vertices.data[v].num_weights);
            j_end_obj();
        }
        j_end_arr();
        j_key("weights");
        j_arr();
        for (size_t w = 0; w < skin->weights.count; w++) {
            j_obj();
            jk_int("cluster", skin->weights.data[w].cluster_index);
            jk_num("weight", skin->weights.data[w].weight);
            j_end_obj();
        }
        j_end_arr();
        j_end_obj();
    }
    j_end_arr();

    // blend deformers
    j_key("blend_deformers");
    j_arr();
    for (size_t i = 0; i < scene->blend_deformers.count; i++) {
        ufbx_blend_deformer *blend = scene->blend_deformers.data[i];
        j_obj();
        jk_str("name", blend->name);
        j_key("channels");
        j_arr();
        for (size_t c = 0; c < blend->channels.count; c++) {
            ufbx_blend_channel *channel = blend->channels.data[c];
            j_obj();
            jk_str("name", channel->name);
            jk_num("weight", channel->weight);
            j_key("keyframes");
            j_arr();
            for (size_t k = 0; k < channel->keyframes.count; k++) {
                ufbx_blend_keyframe *key = &channel->keyframes.data[k];
                j_obj();
                jk_num("target_weight", key->target_weight);
                jk_num("effective_weight", key->effective_weight);
                if (key->shape) {
                    j_key("shape");
                    j_obj();
                    jk_str("name", key->shape->name);
                    jk_int("num_offsets", (long long)key->shape->num_offsets);
                    j_key("offset_vertices");
                    j_arr();
                    for (size_t o = 0; o < key->shape->offset_vertices.count; o++)
                        j_int(key->shape->offset_vertices.data[o]);
                    j_end_arr();
                    j_key("position_offsets");
                    j_arr();
                    for (size_t o = 0; o < key->shape->position_offsets.count; o++) {
                        ufbx_vec3 v = key->shape->position_offsets.data[o];
                        j_num(v.x); j_num(v.y); j_num(v.z);
                    }
                    j_end_arr();
                    j_end_obj();
                }
                j_end_obj();
            }
            j_end_arr();
            j_end_obj();
        }
        j_end_arr();
        j_end_obj();
    }
    j_end_arr();

    // anim stacks
    j_key("anim_stacks");
    j_arr();
    for (size_t i = 0; i < scene->anim_stacks.count; i++) {
        ufbx_anim_stack *stack = scene->anim_stacks.data[i];
        j_obj();
        jk_str("name", stack->name);
        jk_num("time_begin", stack->time_begin);
        jk_num("time_end", stack->time_end);
        j_key("layers");
        j_arr();
        for (size_t l = 0; l < stack->layers.count; l++) {
            ufbx_anim_layer *layer = stack->layers.data[l];
            j_obj();
            jk_str("name", layer->name);
            jk_num("weight", layer->weight);
            jk_bool("additive", layer->additive);
            jk_bool("compose_rotation", layer->compose_rotation);
            jk_bool("compose_scale", layer->compose_scale);
            j_key("anim_props");
            j_arr();
            for (size_t p = 0; p < layer->anim_props.count; p++) {
                ufbx_anim_prop *aprop = &layer->anim_props.data[p];
                j_obj();
                jk_str("element_name", aprop->element->name);
                jk_cstr("element_type", element_type_name(aprop->element->type));
                jk_str("prop_name", aprop->prop_name);
                j_key("default_value"); j_vec3(aprop->anim_value->default_value);
                j_key("curves");
                j_arr();
                for (int c = 0; c < 3; c++) {
                    ufbx_anim_curve *curve = aprop->anim_value->curves[c];
                    if (!curve) { j_null(); continue; }
                    j_obj();
                    jk_int("num_keys", (long long)curve->keyframes.count);
                    j_key("keys");
                    j_arr();
                    for (size_t k = 0; k < curve->keyframes.count; k++) {
                        ufbx_keyframe *key = &curve->keyframes.data[k];
                        j_obj();
                        jk_num("time", key->time);
                        jk_num("value", key->value);
                        jk_cstr("interpolation", interpolation_name(key->interpolation));
                        j_key("left"); j_obj(); jk_num("dx", key->left.dx); jk_num("dy", key->left.dy); j_end_obj();
                        j_key("right"); j_obj(); jk_num("dx", key->right.dx); jk_num("dy", key->right.dy); j_end_obj();
                        j_end_obj();
                    }
                    j_end_arr();
                    j_end_obj();
                }
                j_end_arr();
                j_end_obj();
            }
            j_end_arr();
            j_end_obj();
        }
        j_end_arr();
        j_end_obj();
    }
    j_end_arr();

    // evaluate
    j_key("evaluate");
    j_obj();
    j_key("stacks");
    j_arr();
    for (size_t i = 0; i < scene->anim_stacks.count; i++) {
        ufbx_anim_stack *stack = scene->anim_stacks.data[i];
        double t0 = stack->time_begin, t1 = stack->time_end;
        size_t num_times = t1 > t0 ? 8 : 1;
        j_obj();
        jk_str("name", stack->name);
        j_key("times");
        j_arr();
        double times[8];
        for (size_t t = 0; t < num_times; t++) {
            times[t] = num_times == 1 ? t0 : t0 + (double)t * (t1 - t0) / 7.0;
            j_num(times[t]);
        }
        j_end_arr();
        j_key("nodes");
        j_arr();
        for (size_t n = 0; n < scene->nodes.count; n++) {
            ufbx_node *node = scene->nodes.data[n];
            if (node->is_root) continue;
            j_obj();
            jk_int("node", (long long)node->typed_id);
            j_key("translation");
            j_arr();
            for (size_t t = 0; t < num_times; t++)
                j_vec3(ufbx_evaluate_transform(stack->anim, node, times[t]).translation);
            j_end_arr();
            j_key("rotation");
            j_arr();
            for (size_t t = 0; t < num_times; t++)
                j_quat(ufbx_evaluate_transform(stack->anim, node, times[t]).rotation);
            j_end_arr();
            j_key("scale");
            j_arr();
            for (size_t t = 0; t < num_times; t++)
                j_vec3(ufbx_evaluate_transform(stack->anim, node, times[t]).scale);
            j_end_arr();
            j_end_obj();
        }
        j_end_arr();
        j_end_obj();
    }
    j_end_arr();
    j_end_obj();

    j_end_obj();
    fputc('\n', stdout);

    ufbx_free_scene(scene);
    return 0;
}
