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
    texture_count:    u32,
    argument_buffer:  Argument_Buffer_ID,
    textures_dirty:   bool,
    
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

shape_batch_begin_frame :: proc() {
    shape_batch.instance_offset = 0
    shape_batch.instance_count = 0
}

shape_batcher_init :: proc(renderer_id: Renderer_ID, allocator: runtime.Allocator) {
    shape_batch = new(Shape_Batch, allocator)
    
    quad_verts := QUAD_VERTICES
    quad_indices := QUAD_INDICES

    // Buffer index 3
    // TODO abstract so not calling metal directly
    arg_buffer := metal_create_argument_buffer(renderer_id, "shape_fragment", 3, MAX_SHAPE_TEXTURES)

    shape_batch^ = {
        rid              = renderer_id,
        vertex_buffer    = create_buffer(renderer_id, raw_data(quad_verts[:]), size_of(QUAD_VERTICES), .Vertex, .Static),
        index_buffer     = create_buffer(renderer_id, raw_data(quad_indices[:]), size_of(QUAD_INDICES), .Index, .Static),
        instance_buffer  = create_buffer_zeros(renderer_id, SHAPES_PER_FRAME * size_of(Shape_Instance), .Vertex, .Dynamic),
        argument_buffer  = arg_buffer,
        textures_dirty   = true,
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
    
    // TODO move to non metal
    metal_encode_textures(
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
    
    // Bind the argument buffer containing all registered textures (fragment buffer slot 3)
    // TODO move argument buffer to render agnostic proc
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
