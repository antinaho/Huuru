package huuru

import "base:runtime"
import stbi "vendor:stb/image"

SHAPES_PER_FRAME :: #config(SHAPES_PER_FRAME, 100_000)
MAX_SHAPE_TEXTURES :: #config(MAX_SHAPE_TEXTURES, 128)

shape_batch: ^Shape_Batch

Shape_Batch :: struct {
    instances:       [SHAPES_PER_FRAME]Shape_Instance,

    vertex_buffer:   Buffer_ID,
    index_buffer:    Buffer_ID,
    instance_buffer: Buffer_ID,
    
    instance_offset: uint,
    instance_count:  uint,

    // Texture registry for bindless rendering
    textures:         [MAX_SHAPE_TEXTURES]Texture_ID,
    texture_count:    u16,
    argument_buffer:  Argument_Buffer_ID,
    textures_dirty:   bool,  // true when textures need to be re-encoded

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
    Textured_Rect   = 6,  // Uses custom UVs and texture_index for texture sampling
}

Shape_Instance :: struct #align(16) {
    position:      Vec2,       // offset 0
    scale:         Vec2,       // offset 8

    params:        Vec4,       // offset 16

    uv_min:        Vec2,       // offset 32 - bottom-left UV for texture sampling
    uv_max:        Vec2,       // offset 40 - top-right UV for texture sampling

    rotation:      f32,        // offset 48
    kind:          Shape_Kind, // offset 52
    texture_index: u16,        // offset 56 - index into bindless texture array
    color:         Color,      // offset 58
    _pad:          u16,        // offset 62 (total 64)
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

shape_batch_begin_frame :: proc() {
    shape_batch.instance_offset = 0
    shape_batch.instance_count = 0
}

shape_batcher_init :: proc(renderer_id: Renderer_ID, allocator: runtime.Allocator) {
    shape_batch = new(Shape_Batch, allocator)
    
    quad_verts := QUAD_VERTICES
    quad_indices := QUAD_INDICES

    // Create the argument buffer for bindless textures
    // Buffer index 3 matches [[buffer(3)]] in the fragment shader
    arg_buffer := metal_create_argument_buffer(renderer_id, "shape_fragment", 3, MAX_SHAPE_TEXTURES)

    shape_batch^ = {
        rid              = renderer_id,
        vertex_buffer    = create_buffer(renderer_id, raw_data(quad_verts[:]), size_of(QUAD_VERTICES), .Vertex, .Static),
        index_buffer     = create_buffer(renderer_id, raw_data(quad_indices[:]), size_of(QUAD_INDICES), .Index, .Static),
        instance_buffer  = create_buffer_zeros(renderer_id, SHAPES_PER_FRAME * size_of(Shape_Instance), .Vertex, .Dynamic),
        argument_buffer  = arg_buffer,
        textures_dirty   = true,
    }

    // Register the default 1x1 white texture at index 0
    // This is used by SDF shapes and as a fallback for solid colors
    tex_data, tex_width, tex_height := load_tex(get_path_to("assets/White_1x1.png"))
    white_texture := create_texture(renderer_id, Texture_Desc {
        data   = tex_data,
        width  = tex_width,
        height = tex_height,
        format = .RGBA8,
    })
    stbi.image_free(cast([^]byte)tex_data)
    
    // Register white texture at index 0 (guaranteed to be index 0 since registry is empty)
    register_shape_texture(white_texture)
}

// Register a texture for use with shape drawing.
// Returns the texture index to use with draw_textured_rect or draw_shape.
// Index 0 is reserved for the default 1x1 white texture.
register_shape_texture :: proc(texture: Texture_ID) -> u16 {
    assert(shape_batch.texture_count < MAX_SHAPE_TEXTURES, "Shape texture registry full")
    
    index := shape_batch.texture_count
    shape_batch.textures[index] = texture
    shape_batch.texture_count += 1
    shape_batch.textures_dirty = true  // Mark for re-encoding into argument buffer
    
    return index
}

// Encodes all registered textures into the argument buffer.
// Called automatically before rendering if textures_dirty is true.
update_shape_textures :: proc() {
    if !shape_batch.textures_dirty || shape_batch.texture_count == 0 {
        return
    }
    
    metal_encode_textures(
        shape_batch.rid,
        shape_batch.argument_buffer,
        shape_batch.textures[:shape_batch.texture_count],
    )
    
    shape_batch.textures_dirty = false
}

// Generic shape drawing
draw_shape :: proc(position: Vec2, rotation: f32, scale: Vec2, color: Color, kind: Shape_Kind, params: Vec4 = {}, uv_min: Vec2 = {0, 0}, uv_max: Vec2 = {1, 1}, texture_index: u16 = 0) {
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

// Convenience wrappers
draw_rect :: proc(position: Vec2, rotation: f32, size: Vec2, color: Color) {
    draw_shape(position, rotation, size, color, .Rect)
}

draw_circle :: proc(position: Vec2, radius: f32, color: Color) {
    draw_shape(position, 0, {radius * 2, radius * 2}, color, .Circle)
}

// inner_radius_ratio: 0-1, ratio of inner hole to outer radius (e.g., 0.5 = hole is half the size)
draw_donut :: proc(position: Vec2, radius: f32, inner_radius_ratio: f32, color: Color) {
    draw_shape(position, 0, {radius * 2, radius * 2}, color, .Donut, {inner_radius_ratio, 0, 0, 0})
}

draw_triangle :: proc(position: Vec2, rotation: f32, size: f32, color: Color) {
    draw_shape(position, rotation, {size, size}, color, .Triangle)
}

// thickness: 0-1, border thickness relative to size (e.g., 0.1 = 10% of size)
draw_hollow_rect :: proc(position: Vec2, rotation: f32, size: Vec2, thickness: f32, color: Color) {
    draw_shape(position, rotation, size, color, .Hollow_Rect, {thickness, 0, 0, 0})
}

// thickness: 0-1, border thickness relative to size
draw_hollow_triangle :: proc(position: Vec2, rotation: f32, size: f32, thickness: f32, color: Color) {
    draw_shape(position, rotation, {size, size}, color, .Hollow_Triangle, {thickness, 0, 0, 0})
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
    texture_index: u16,
    uv_rect: UV_Rect,
    color: Color = WHITE,
) {
    draw_shape(
        position, 
        rotation, 
        size, 
        color, 
        .Textured_Rect, 
        {}, // no params needed
        uv_rect.min,
        uv_rect.max,
        texture_index,
    )
}

// Draw an entire texture (convenience wrapper for draw_textured_rect with full UV rect)
// texture_index: index returned by register_shape_texture()
// color: tint color (use WHITE for no tint)
draw_texture :: proc(
    position: Vec2,
    rotation: f32,
    size: Vec2,
    texture_index: u16,
    color: Color = WHITE,
) {
    draw_textured_rect(
        position,
        rotation,
        size,
        texture_index,
        UV_Rect{min = {0, 0}, max = {1, 1}},
        color,
    )
}

// Draw a sprite from an atlas/spritesheet
// texture_index: index returned by register_shape_texture()
// sprite_pos: top-left corner of sprite in pixels
// sprite_size: size of sprite in pixels
// texture_size: total size of the texture/atlas in pixels
// color: tint color (use WHITE for no tint)
draw_sprite :: proc(
    position: Vec2,
    rotation: f32,
    size: Vec2,
    texture_index: u16,
    sprite_pos: Vec2,
    sprite_size: Vec2,
    texture_size: Vec2,
    color: Color = WHITE,
) {
    // Convert pixel coordinates to UV coordinates
    uv_min := sprite_pos / texture_size
    uv_max := (sprite_pos + sprite_size) / texture_size
    
    draw_textured_rect(
        position,
        rotation,
        size,
        texture_index,
        UV_Rect{min = uv_min, max = uv_max},
        color,
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
    
    // Bind the argument buffer containing all registered textures (fragment buffer slot 3)
    cmd_bind_argument_buffer({
        id                 = shape_batch.rid,
        argument_buffer_id = shape_batch.argument_buffer,
        slot               = 3,  // matches [[buffer(3)]] in fragment shader
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
