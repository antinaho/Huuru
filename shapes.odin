package huuru

import "base:runtime"
import stbi "vendor:stb/image"

SHAPES_PER_FRAME :: #config(SHAPES_PER_FRAME, 100_000)

shape_batch: ^Shape_Batch

Shape_Batch :: struct {
    instances:       [SHAPES_PER_FRAME]Shape_Instance,

    vertex_buffer:   Buffer_ID,
    index_buffer:    Buffer_ID,
    instance_buffer: Buffer_ID,
    
    instance_offset: uint,
    instance_count:  uint,
    texture:         Texture_ID,
    texture_slot:    uint,
    rid:             Renderer_ID,
}

Shape_Vertex :: struct {
    position: Vec2,
    uv:       Vec2,
}

Shape_Kind :: enum u32 {
    Rect   = 0,
    Circle = 1,
}

Shape_Instance :: struct {
    position: Vec2,
    scale:    Vec2,
    rotation: f32,
    kind:     Shape_Kind,
    color:    Color,
    params:   Vec4,
}

shape_pipeline :: proc(renderer_id: Renderer_ID) -> Pipeline_ID {

    pipeline := create_pipeline(
        renderer_id,
        Pipeline_Desc {
            layouts = {
                {stride = size_of(Shape_Vertex),   step_rate = .PerVertex},
                {stride = size_of(Shape_Instance), step_rate = .PerInstance},
            },
            attributes = {
                // Vertex attributes (binding 0)
                {format = .Float2, offset = offset_of(Shape_Vertex, position), binding = 0},
                {format = .Float2, offset = offset_of(Shape_Vertex, uv),       binding = 0},
                
                // Instance attributes (binding 1)
                {format = .Float2, offset = offset_of(Shape_Instance, position), binding = 1},
                {format = .Float2, offset = offset_of(Shape_Instance, scale),    binding = 1},
                {format = .Float,  offset = offset_of(Shape_Instance, rotation), binding = 1},
                {format = .UInt32, offset = offset_of(Shape_Instance, kind),     binding = 1},
                {format = .UByte4, offset = offset_of(Shape_Instance, color),    binding = 1},
                {format = .Float4, offset = offset_of(Shape_Instance, params),   binding = 1},
            },
            type = Pipeline_Desc_Metal{
                vertex_entry   = "shape_vertex",
                fragment_entry = "shape_fragment",
            },
            blend = AlphaPremultipliedBlend
        }
    )

    return pipeline
}

// Unit quad data
QUAD_VERTICES :: [4]Shape_Vertex {
    {position = {-0.5, -0.5}, uv = {0, 0}},  // bottom-left
    {position = { 0.5, -0.5}, uv = {1, 0}},  // bottom-right
    {position = { 0.5,  0.5}, uv = {1, 1}},  // top-right
    {position = {-0.5,  0.5}, uv = {0, 1}},  // top-left
}

QUAD_INDICES :: [6]u32 {0, 1, 2, 2, 3, 0}

shape_batcher_init :: proc(renderer_id: Renderer_ID, allocator: runtime.Allocator) {
    shape_batch = new(Shape_Batch, allocator)
    
    quad_verts := QUAD_VERTICES
    quad_indices := QUAD_INDICES

    tex_data, tex_width, tex_height := load_tex(get_path_to("assets/White_1x1.png"))
    shape_batch^ = {
        rid             = renderer_id,
        texture         = create_texture(renderer_id, Texture_Desc {
            data   = tex_data,
            width  = tex_width,
            height = tex_height,
            format = .RGBA8
        }),
        texture_slot    = 0,
        vertex_buffer   = create_buffer(renderer_id, raw_data(quad_verts[:]), size_of(QUAD_VERTICES), .Vertex, .Dynamic), // Move to static soon
        index_buffer    = create_buffer(renderer_id, raw_data(quad_indices[:]), size_of(QUAD_INDICES), .Index, .Dynamic), // Move to static soon
        instance_buffer = create_buffer_zeros(renderer_id, SHAPES_PER_FRAME * size_of(Shape_Instance), .Vertex, .Dynamic),
    }

    stbi.image_free(cast([^]byte)tex_data)
}

// Generic shape drawing
draw_shape :: proc(position: Vec2, rotation: f32, scale: Vec2, color: Color, kind: Shape_Kind, params: Vec4 = {}) {
    if shape_batch.instance_count >= SHAPES_PER_FRAME {
        flush_shapes_batch()
    }
    
    shape_batch.instances[shape_batch.instance_count] = Shape_Instance {
        position = position,
        scale    = scale,
        rotation = rotation,
        kind     = kind,
        color    = color,
        params   = params,
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

flush_shapes_batch :: proc() {
    if shape_batch.instance_count == 0 {
        return
    }

    byte_offset := shape_batch.instance_offset * size_of(Shape_Instance)

    push_buffer(
        shape_batch.rid, 
        shape_batch.instance_buffer, 
        raw_data(shape_batch.instances[:]), 
        byte_offset, 
        size_of(Shape_Instance) * int(shape_batch.instance_count), 
        .Dynamic
    )
    
    cmd_bind_texture({id = shape_batch.rid, texture_id = shape_batch.texture, slot = shape_batch.texture_slot})
    cmd_bind_vertex_buffer({
        id        = shape_batch.rid,
        buffer_id = shape_batch.vertex_buffer,
        index     = 0,
        offset    = 0,
    })
    cmd_bind_vertex_buffer({
        id        = shape_batch.rid,
        buffer_id = shape_batch.instance_buffer,
        index     = 1,
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
