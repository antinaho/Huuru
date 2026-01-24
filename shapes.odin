package huuru

import "base:runtime"
import "core:math/linalg"
import stbi "vendor:stb/image"

SHAPES_PER_FRAME :: #config(SHAPES_PER_FRAME, 100_000)
MAX_SHAPE_TEXTURES :: #config(MAX_SHAPE_TEXTURES, 128)

shape_batch: ^Shape_Batch

Shape_Batch :: struct {
    instances:       [SHAPES_PER_FRAME]Shape_Instance,

    vertex_buffer:   Buffer_ID,
    index_buffer:    Buffer_ID,
    instance_buffer: Buffer_ID,
    uniform_buffer:  Buffer_ID,
    
    instance_offset: uint,
    instance_count:  uint,

    // Texture registry for bindless rendering
    textures:         [MAX_SHAPE_TEXTURES]Texture_ID,
    texture_count:    u32,
    argument_buffer:  Argument_Buffer_ID,
    textures_dirty:   bool,
    
    // Pixel art mode: world units per "pixel" (0 = smooth/no pixelation)
    pixel_size:       f32,
    
    // Cached uniforms for this frame
    view_projection:     matrix[4,4]f32,
    inv_view_projection: matrix[4,4]f32,
    screen_size:         Vec2,
    
    rid:             Renderer_ID,
}

Shape_Vertex :: struct {
    position: Vec2,
    uv:       Vec2,
}

Shape_Kind :: enum u32 {
    Rect            = 0,
    Circle          = 1,
    Donut           = 2,
    Triangle        = 3,
    Hollow_Rect     = 4,
    Hollow_Triangle = 5,
    Textured_Rect   = 6,
    Line            = 7,
}

Shape_Instance :: struct #align(16) {
    position:      Vec2,       // offset 0 total 8 
    scale:         Vec2,       // offset 8 total 16

    params:        Vec4,       // offset 16 total 32

    uv_min:        Vec2,       // offset 32 total 40
    uv_max:        Vec2,       // offset 40 total 48

    color:         Color,      // offset 48 total 52
    rotation:      f32,        // offset 52 total 56
    kind:          Shape_Kind, // offset 56 total 60
    texture_index: u32,        // offset 60 total 64
}

#assert(size_of(Shape_Instance) == 64)
#assert(size_of(Shape_Instance) % 16 == 0)

shape_pipeline :: proc(renderer_id: Renderer_ID) -> Pipeline_ID {

    pipeline := create_pipeline(
        renderer_id,
        Pipeline_Desc {
            layouts = {
                {stride = size_of(Shape_Vertex), step_rate = .PerVertex},  // buffer 0
            },
            attributes = {
                // Vertex attributes (buffer 0)
                {format = .Float2, offset = offset_of(Shape_Vertex, position), binding = 0},  // attr 0
                {format = .Float2, offset = offset_of(Shape_Vertex, uv),       binding = 0},  // attr 1
            },
            type = Pipeline_Desc_Metal{
                vertex_entry   = "shape_vertex",
                fragment_entry = "shape_fragment",
            },
            blend = AlphaBlend
        }
    )

    return pipeline
}

shape_sampler :: proc(renderer_id: Renderer_ID) -> Sampler_ID {
    sampler := create_sampler(renderer_id, Sampler_Desc {
        mag_filter = .Linear,
        min_filter = .Linear,
        wrap_s = .ClampToEdge,
        wrap_t = .ClampToEdge,
    })

    return sampler
}

// Unit quad data
QUAD_VERTICES :: [4]Shape_Vertex {
    {position = {-0.5, -0.5}, uv = {0, 0}},  // bottom-left
    {position = { 0.5, -0.5}, uv = {1, 0}},  // bottom-right
    {position = { 0.5,  0.5}, uv = {1, 1}},  // top-right
    {position = {-0.5,  0.5}, uv = {0, 1}},  // top-left
}

QUAD_INDICES :: [6]u32 {0, 1, 2, 2, 3, 0}

shape_batch_free_all :: proc() {
    shape_batch.instance_offset = 0
    shape_batch.instance_count = 0
}

// Set the pixel size for pixel art rendering.
// pixel_size: world units per "pixel" (e.g., 4.0 means each pixel art pixel is 4x4 world units)
// Set to 0 for smooth rendering (default, no pixelation).
set_pixel_size :: proc(pixel_size: f32) {
    shape_batch.pixel_size = pixel_size
}

// Get the current pixel size setting
get_pixel_size :: proc() -> f32 {
    return shape_batch.pixel_size
}

// Set the view projection matrix for shape rendering.
// This should be called once per frame before drawing shapes.
set_shape_view_projection :: proc(view_proj: matrix[4,4]f32, screen_size: Vec2) {
    shape_batch.view_projection = view_proj
    shape_batch.inv_view_projection = linalg.inverse(view_proj)
    shape_batch.screen_size = screen_size
}

shape_batcher_init :: proc(renderer_id: Renderer_ID, allocator: runtime.Allocator) {
    shape_batch = new(Shape_Batch, allocator)
    
    quad_verts := QUAD_VERTICES
    quad_indices := QUAD_INDICES

    // Create argument buffer for bindless texture access (buffer index 3 in shader)
    arg_buffer := create_argument_buffer(renderer_id, Argument_Buffer_Desc {
        function_name = "shape_fragment",
        buffer_index  = 3,
        max_textures  = MAX_SHAPE_TEXTURES,
    })

    shape_batch^ = {
        rid              = renderer_id,
        vertex_buffer    = create_buffer(renderer_id, raw_data(quad_verts[:]), size_of(QUAD_VERTICES), .Vertex, .Static),
        index_buffer     = create_buffer(renderer_id, raw_data(quad_indices[:]), size_of(QUAD_INDICES), .Index, .Static),
        instance_buffer  = create_buffer_zeros(renderer_id, SHAPES_PER_FRAME * size_of(Shape_Instance), .Vertex, .Dynamic),
        uniform_buffer   = create_buffer_zeros(renderer_id, size_of(Shape_Uniforms), .Vertex, .Dynamic),
        argument_buffer  = arg_buffer,
        textures_dirty   = true,
        pixel_size       = 0,  // Default: smooth rendering (no pixelation)
    }

    // Default 1x1 white texture at index 0
    tex_data, tex_width, tex_height := load_tex(get_path_to("assets/White_1x1.png"))
    white_texture := create_texture(renderer_id, Texture_Desc {
        data   = tex_data,
        width  = tex_width,
        height = tex_height,
        format = .RGBA8,
    })
    defer stbi.image_free(cast([^]byte)tex_data)
    register_shape_texture(white_texture)
}

// Register a texture for use with shape drawing.
// Returns the texture index to use with draw_textured_rect or draw_shape.
// Index 0 is reserved for the default 1x1 white texture.
register_shape_texture :: proc(texture: Texture_ID) -> u32 {
    assert(shape_batch.texture_count < MAX_SHAPE_TEXTURES, "Shape texture registry full")
    
    index := shape_batch.texture_count
    shape_batch.textures[index] = texture
    shape_batch.texture_count += 1
    shape_batch.textures_dirty = true
    
    return index
}

// Encodes all registered textures into the argument buffer.
// Called automatically before rendering if textures_dirty is true.
update_shape_textures :: proc() {
    if !shape_batch.textures_dirty || shape_batch.texture_count == 0 {
        return
    }
    
    encode_argument_buffer_textures(
        shape_batch.rid,
        shape_batch.argument_buffer,
        shape_batch.textures[:shape_batch.texture_count],
    )
    
    shape_batch.textures_dirty = false
}

// Generic shape drawing
draw_shape :: proc(position: Vec2, rotation: f32, scale: Vec2, color: Color, kind: Shape_Kind, params: Vec4 = {}, uv_min: Vec2 = {0, 0}, uv_max: Vec2 = {1, 1}, texture_index: u32 = 0) {
    if shape_batch.instance_count >= SHAPES_PER_FRAME {
        flush_shapes_batch()
    }
    
    shape_batch.instances[shape_batch.instance_count] = Shape_Instance {
        position      = position,
        scale         = scale,
        rotation      = rotation,
        kind          = kind,
        color         = color,
        params        = params,
        uv_min        = uv_min,
        uv_max        = uv_max,
        texture_index = texture_index,
    }
    shape_batch.instance_count += 1
}

draw_rect :: proc(position: Vec2, rotation: f32, size: Vec2, color: Color) {
    draw_shape(position, rotation, size, color, .Rect)
}

draw_circle :: proc(position: Vec2, radius: f32, color: Color) {
    draw_shape(position, 0, {radius * 2, radius * 2}, color, .Circle)
}

draw_donut :: proc(position: Vec2, radius: f32, inner_radius_ratio: f32, color: Color) {
    draw_shape(position, 0, {radius * 2, radius * 2}, color, .Donut, {inner_radius_ratio, 0, 0, 0})
}

draw_triangle :: proc(position: Vec2, rotation: f32, size: f32, color: Color) {
    draw_shape(position, rotation, {size, size}, color, .Triangle)
}

draw_hollow_rect :: proc(position: Vec2, rotation: f32, size: Vec2, thickness: f32, color: Color) {
    draw_shape(position, rotation, size, color, .Hollow_Rect, {thickness, 0, 0, 0})
}

draw_hollow_triangle :: proc(position: Vec2, rotation: f32, size: f32, thickness: f32, color: Color) {
    draw_shape(position, rotation, {size, size}, color, .Hollow_Triangle, {thickness, 0, 0, 0})
}

import "core:math"

// Internal helper to draw a single line segment using SDF
// Uses an axis-aligned bounding box and passes normalized endpoints to shader
@(private="file")
draw_line_segment :: proc(start_pos: Vec2, end_pos: Vec2, thickness: f32, color: Color) {
    // Calculate axis-aligned bounding box with padding for thickness
    half_thickness := thickness * 0.5
    
    min_x := min(start_pos.x, end_pos.x) - half_thickness
    max_x := max(start_pos.x, end_pos.x) + half_thickness
    min_y := min(start_pos.y, end_pos.y) - half_thickness
    max_y := max(start_pos.y, end_pos.y) + half_thickness
    
    // Box dimensions and center
    box_size := Vec2{max_x - min_x, max_y - min_y}
    box_center := Vec2{(min_x + max_x) * 0.5, (min_y + max_y) * 0.5}
    
    // Skip degenerate boxes
    if box_size.x < 0.001 && box_size.y < 0.001 {
        return
    }
    
    // Normalize line endpoints relative to box center, scaled to [-0.5, 0.5] range
    // This maps the endpoints into the UV space of the quad
    start_normalized := (start_pos - box_center) / box_size
    end_normalized := (end_pos - box_center) / box_size
    
    // Pack normalized endpoints and thickness ratio into params
    // params.xy = start point in normalized coords
    // params.zw = end point in normalized coords
    params := Vec4{start_normalized.x, start_normalized.y, end_normalized.x, end_normalized.y}
    
    // Pass half_thickness / box_height as the radius in normalized space
    // The shader scales x by aspect ratio, so we normalize against box_height
    // to keep consistent units after the aspect ratio scaling
    thickness_normalized := half_thickness / box_size.y
    
    // Store thickness ratio in uv_min.x (repurposing UV for non-textured shape)
    draw_shape(box_center, 0, box_size, color, .Line, params, uv_min = {thickness_normalized, box_size.x / box_size.y})
}

// Draw a straight line from start to end
draw_line :: proc(start_pos: Vec2, end_pos: Vec2, thickness: f32, color: Color) {
    draw_line_segment(start_pos, end_pos, thickness, color)
}

// Evaluate quadratic Bézier curve at parameter t
// P(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
@(private="file")
bezier_quadratic :: proc(p0, p1, p2: Vec2, t: f32) -> Vec2 {
    u := 1.0 - t
    return u * u * p0 + 2.0 * u * t * p1 + t * t * p2
}

// Evaluate cubic Bézier curve at parameter t
// P(t) = (1-t)³·P0 + 3(1-t)²t·P1 + 3(1-t)t²·P2 + t³·P3
@(private="file")
bezier_cubic :: proc(p0, p1, p2, p3: Vec2, t: f32) -> Vec2 {
    u := 1.0 - t
    u2 := u * u
    t2 := t * t
    return u2 * u * p0 + 3.0 * u2 * t * p1 + 3.0 * u * t2 * p2 + t2 * t * p3
}

// Default number of segments for Bézier curve tessellation
BEZIER_DEFAULT_SEGMENTS :: 16

// Draw a quadratic Bézier curve (1 control point)
// start_pos: starting point (P0)
// control: control point (P1)
// end_pos: ending point (P2)
draw_bezier_quadratic :: proc(start_pos: Vec2, control: Vec2, end_pos: Vec2, thickness: f32, color: Color, segments: int = BEZIER_DEFAULT_SEGMENTS) {
    prev := start_pos
    
    for i in 1..=segments {
        t := f32(i) / f32(segments)
        curr := bezier_quadratic(start_pos, control, end_pos, t)
        draw_line_segment(prev, curr, thickness, color)
        prev = curr
    }
}

// Draw a cubic Bézier curve (2 control points)
// start_pos: starting point (P0)
// control1: first control point (P1)
// control2: second control point (P2)
// end_pos: ending point (P3)
draw_bezier_cubic :: proc(start_pos: Vec2, control1: Vec2, control2: Vec2, end_pos: Vec2, thickness: f32, color: Color, segments: int = BEZIER_DEFAULT_SEGMENTS) {
    prev := start_pos
    
    for i in 1..=segments {
        t := f32(i) / f32(segments)
        curr := bezier_cubic(start_pos, control1, control2, end_pos, t)
        draw_line_segment(prev, curr, thickness, color)
        prev = curr
    }
}

// *** Textured drawing ***

// Draw a textured rectangle with custom UV coordinates.
// texture_index: index returned by register_shape_texture()
// uv_rect: UV coordinates for texture sampling (min = bottom-left, max = top-right)
// color: tint color (use WHITE for no tint)
draw_textured_rect :: proc(
    position: Vec2,
    rotation: f32,
    size: Vec2,
    texture_index: u32,
    uv_rect: UV_Rect,
    color: Color = WHITE,
) {
    draw_shape(
        position, 
        rotation, 
        size, 
        color, 
        .Textured_Rect, 
        {}, 
        uv_rect.min,
        uv_rect.max,
        texture_index,
    )
}

flush_shapes_batch :: proc() {
    if shape_batch.instance_count == 0 {
        return
    }

    // Encode any newly registered textures into the argument buffer
    update_shape_textures()

    byte_offset := shape_batch.instance_offset * size_of(Shape_Instance)

    push_buffer(
        shape_batch.rid, 
        shape_batch.instance_buffer, 
        raw_data(shape_batch.instances[:]), 
        byte_offset, 
        size_of(Shape_Instance) * int(shape_batch.instance_count), 
        .Dynamic
    )
    
    // Push uniforms (view projection, pixel size, etc.)
    uniforms := Shape_Uniforms {
        view_projection     = shape_batch.view_projection,
        inv_view_projection = shape_batch.inv_view_projection,
        screen_size         = shape_batch.screen_size,
        pixel_size          = shape_batch.pixel_size,
    }
    push_buffer(
        shape_batch.rid,
        shape_batch.uniform_buffer,
        &uniforms,
        0,
        size_of(Shape_Uniforms),
        .Dynamic,
    )
    
    // Bind the argument buffer containing all registered textures (fragment buffer slot 3)
    cmd_bind_argument_buffer({
        id                 = shape_batch.rid,
        argument_buffer_id = shape_batch.argument_buffer,
        slot               = 3,  // [[buffer(3)]] in fragment shader
    })
    
    cmd_bind_vertex_buffer({
        id        = shape_batch.rid,
        buffer_id = shape_batch.vertex_buffer,
        index     = 0,  // buffer 0 for vertices
        offset    = 0,
    })
    cmd_bind_vertex_buffer({
        id        = shape_batch.rid,
        buffer_id = shape_batch.instance_buffer,
        index     = 1,  // buffer 1 for instances
        offset    = byte_offset,
    })
    cmd_bind_vertex_buffer({
        id        = shape_batch.rid,
        buffer_id = shape_batch.uniform_buffer,
        index     = 2,  // buffer 2 for uniforms (vertex shader)
        offset    = 0,
    })
    cmd_bind_fragment_buffer({
        id        = shape_batch.rid,
        buffer_id = shape_batch.uniform_buffer,
        index     = 2,  // buffer 2 for uniforms (fragment shader)
        offset    = 0,
    })
    
    cmd_draw_indexed_instances({
        rid                 = shape_batch.rid,
        index_buffer        = shape_batch.index_buffer,
        index_buffer_offset = 0,
        index_count         = 6,
        index_type          = .UInt32,
        primitive           = .Triangle,
        instance_count      = shape_batch.instance_count,
    })

    shape_batch.instance_offset += shape_batch.instance_count
    shape_batch.instance_count = 0
}


import "core:path/filepath"

get_path_to :: proc(rel_path: string, allocator := context.allocator, loc := #caller_location) -> string {
    caller_dir := filepath.dir(loc.file_path, context.temp_allocator)
    return filepath.join({caller_dir, rel_path}, allocator)
}
