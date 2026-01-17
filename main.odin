package huuru

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"

RENDERER_CHOISE :: #config(RENDERER, "")

Vec2i :: [2]int

Vec2 ::  [2]f32
Vec3 ::  [3]f32
Vec4 ::  [4]f32

VECTOR3_RIGHT ::   Vec3 {1, 0,  0}
VECTOR3_UP ::      Vec3 {0, 1,  0}
VECTOR3_FORWARD :: Vec3 {0, 0, -1}

Color :: [4]u8

BACKGROUND_COLOR :: Color {185, 105, 80, 255}

when RENDERER_CHOISE == "" {
    when ODIN_OS == .Darwin {
	    DEFAULT_RENDERER_API :: METAL_RENDERER_API
    } else when ODIN_OS == .Windows {
	    DEFAULT_RENDERER_API :: nil
    }
} else {
    when RENDERER_CHOISE == "Metal" {
        DEFAULT_RENDERER_API :: METAL_RENDERER_API
    } else {
        DEFAULT_RENDERER_API :: nil
    }
}

RENDERER_API :: DEFAULT_RENDERER_API

Renderer_API :: struct {
    state_size:          proc() -> int,
    init:                proc(window: Window_Provider) -> Renderer_ID,
    create_pipeline:     proc(id: Renderer_ID, desc: Pipeline_Desc) -> Pipeline_ID,
    destroy_pipeline:    proc(id: Renderer_ID, pipeline: Pipeline_ID),
    create_buffer:       proc(id: Renderer_ID, data: rawptr, size: int, type: Buffer_Type, access: Buffer_Access) -> Buffer_ID,
    create_buffer_zeros: proc(id: Renderer_ID, length: int, type: Buffer_Type, access: Buffer_Access) -> Buffer_ID,
    destroy_buffer:      proc(id: Renderer_ID, buffer: Buffer_ID),
    create_texture:      proc(id: Renderer_ID, desc: Texture_Desc) -> Texture_ID,
    destroy_texture:     proc(id: Renderer_ID, texture: Texture_ID),
    create_sampler:      proc(id: Renderer_ID, desc: Sampler_Desc) -> Sampler_ID,
    destroy_sampler:     proc(id: Renderer_ID, sampler: Sampler_ID),
    // Per frame
    bind_sampler:        proc(id: Renderer_ID, sampler: Sampler_ID, slot: uint),
    begin_frame:         proc(id: Renderer_ID),
    end_frame:           proc(id: Renderer_ID),
    bind_pipeline:       proc(id: Renderer_ID, pipeline: Pipeline_ID),
    push_buffer:         proc(id: Renderer_ID, bid: Buffer_ID, data: rawptr, offset: uint, lenght: int, access: Buffer_Access),
    bind_texture:        proc(id: Renderer_ID, texture: Texture_ID, slot: uint),
    draw_simple:         proc(renderer_id: Renderer_ID, buffer_id: Buffer_ID, buffer_offset: uint, buffer_index: uint, type: Primitive_Type, vertex_start: uint, vertex_count: uint),
    draw_instanced:      proc(id: Renderer_ID, vertex_buffer: Buffer_ID, index_count, offset, instance_count: uint, index_type: Index_Type, primitive: Primitive_Type),
    present:             proc(),
}

Renderer :: struct {
    ctx: runtime.Context,

    renderer_states: []byte,
    state_size: int,
    max_renderers: int,

    frame_allocator: runtime.Allocator,
    render_commands: []Render_Command,
    render_command_c: int,

    arena: mem.Arena,
}

@(private="package")
renderer: Renderer

MAX_PIPELINES :: #config(MAX_PIPELINES, 8)

main :: proc() {
    // Example: Setting up the renderer and draw loop

    // Initialize the renderer system (call once at startup)
    init(renderers = 1)

    // You need to implement these callbacks for your windowing system
    window := Window_Provider {
        data = nil, // Your window handle
        get_size = proc(window_id: rawptr) -> [2]int {
            // Return window dimensions
            return {800, 600}
        },
        get_native_handle = proc(window_id: rawptr) -> rawptr {
            // Return native window handle (NSWindow* on macOS)
            return nil
        },
    }

    // Initialize a renderer for the window
    renderer_id := init_renderer(window)

    Vertex :: struct {
        position: [4]f32,
        color:    [4]f32,
    }

    // Create pipeline
    pipeline := create_pipeline(renderer_id, Pipeline_Desc{
        type = Pipeline_Desc_Metal{
            vertex_entry   = "hello_triangle_vertex",
            fragment_entry = "hello_triangle_fragment",
        },
        layouts = {
            Vertex_Layout{
                stride    = size_of(Vertex),
                step_rate = .PerVertex,
            },
        },
        attributes = {
            Vertex_Attribute{ format = .Float4, offset = offset_of(Vertex, position), binding = 0 },
            Vertex_Attribute{ format = .Float4, offset = offset_of(Vertex, color),    binding = 0 },
        },
    })

    // Load and create texture
    tex_data, tex_width, tex_height := load_tex("assets/texture.png")
    texture := create_texture(renderer_id, Texture_Desc{
        width      = tex_width,
        height     = tex_height,
        format     = .RGBA8,
        data       = tex_data,
    })
    stbi.image_free(cast([^]byte)tex_data)

    sprite_batch := sprite_batch_init(renderer_id, texture, 0)

    // Draw loop
    running := true
    frame: u32 = 0
    camera := Camera {
        aspect_ratio = 16.0 / 9.0,
        zoom = 600,
    }
    for running {
        renderer.render_command_c = 0

        cmd_begin_frame({renderer_id})
        cmd_bind_pipeline({renderer_id, pipeline})

        // Example: Draw some sprites using batching
        // Full texture UV rect
        full_uv := UV_Rect{ min = {0, 0}, max = {1, 1} }
        
        // Draw a grid of sprites
        for y in 0..<4 {
            for x in 0..<4 {
                draw_batched(sprite_batch, Draw_Batched{
                    texture  = texture,
                    position = {f32(x) * 100 + 50, f32(y) * 100 + 50, 0},
                    uv_rect = full_uv,
                    scale     = {64, 64, 1},
                    color    = {255, 255, 255, 255},
                })
            }
        }

        // Flush remaining sprites in batch
        flush(sprite_batch)

        cmd_end_frame({renderer_id})

        present()
        frame += 1
    }

    // Cleanup loaded resources
    destroy_texture(renderer_id, texture)
    destroy_pipeline(renderer_id, pipeline)
    // etc...

    destroy()
}


init :: proc(renderers: int = 1) {
    assert(renderers >= 1, "Need at least 1 renderer!")

    backing := make([]byte, 1 * mem.Megabyte)
    mem.arena_init(&renderer.arena, backing)
    arena_allocator := mem.arena_allocator(&renderer.arena)

    renderer.ctx = context
    state_size := RENDERER_API.state_size()
    
    renderer.renderer_states = make([]byte, state_size * renderers, arena_allocator)
    renderer.state_size = state_size
    renderer.max_renderers = renderers
    renderer.frame_allocator = context.temp_allocator
    renderer.render_commands = make([]Render_Command, MAX_RENDER_COMMANDS, arena_allocator)
}

clear_commands :: proc() {
    renderer.render_command_c = 0
}

destroy :: proc() {
    delete(renderer.arena.data)
}

present :: proc() {
    RENDERER_API.present()
}

init_renderer :: proc(window: Window_Provider) -> Renderer_ID {
    return RENDERER_API.init(window)
}

Renderer_ID :: distinct uint

Vertex_Format :: enum {
    Float,
    Float2,
    Float3,
    Float4,
    UByte4,
}

Vertex_Attribute :: struct {
    format:  Vertex_Format,
    offset:  uintptr,
    binding: int, 
}

Vertex_Layout :: struct {
    stride:    int,
    step_rate: Vertex_Step_Rate,
}

Vertex_Step_Rate :: enum {
    PerVertex,
    PerInstance,
}

Renderer_State_Header :: struct {
    is_alive: bool,
    window:   Window_Provider,
}

get_free_state :: proc() -> (state: rawptr, id: Renderer_ID) {
    for i in 0..<renderer.max_renderers {
		state_ptr := get_state_from_id(Renderer_ID(i))
		if !is_state_alive(state_ptr) {
			return state_ptr, Renderer_ID(i)
        }
    }
	log.panic("All renderer states are in use!")
}

get_state_from_id :: proc(id: Renderer_ID) -> rawptr {
	assert(int(id) < renderer.max_renderers && int(id) >= 0, "Invalid Render_ID")
    
	offset := renderer.state_size * int(id)
	return raw_data(renderer.renderer_states[offset:])
}

is_state_alive :: proc(state: rawptr) -> bool {
	header := cast(^Renderer_State_Header)state
	return header.is_alive
}

Window_Provider :: struct {
    data:              rawptr,
    get_size:          proc(data: rawptr) -> Vec2i,
    get_native_handle: proc(data: rawptr) -> rawptr,
    is_visible:        proc(data: rawptr) -> bool,
    is_minimized:      proc(data: rawptr) -> bool,
}

// *** Render Command ***
MAX_RENDER_COMMANDS :: #config(MAX_RENDER_COMMANDS, 8_192)

Render_Command :: union {
    Render_Command_Begin_Frame,
    Render_Command_Bind_Pipeline,
    Render_Command_Bind_Texture,
    Render_Command_Bind_Vertex_Buffer,
    Render_Command_Bind_Sampler,
    Render_Command_Draw_Simple,
    
    Render_Command_End_Frame,
    Render_Command_Draw_Indexed,
}

Render_Command_Begin_Frame :: struct {
    id: Renderer_ID,
}

Render_Command_End_Frame :: struct {
    id: Renderer_ID
}

insert_render_command :: proc(cmd: Render_Command) {
    renderer.render_commands[renderer.render_command_c] = cmd
    renderer.render_command_c += 1

    if renderer.render_command_c >= len(renderer.render_commands) {
        assert(false, "Too many commands")
    }
}

cmd_begin_frame :: proc(cmd: Render_Command_Begin_Frame) { insert_render_command(cmd) }
cmd_end_frame :: proc(cmd: Render_Command_End_Frame) { insert_render_command(cmd) }

// *** Pipeline *** 
Pipeline_ID :: distinct uint

Pipeline_Desc :: struct {
    type:       Pipeline_Desc_Type,
    layouts:    []Vertex_Layout,
    attributes: []Vertex_Attribute,
    blend:      Blend_Descriptor,
}

Pipeline_Desc_Type :: union {
    Pipeline_Desc_Metal
}

Pipeline_Desc_Metal :: struct {
    vertex_entry:   string,
    fragment_entry: string,
}

create_pipeline :: proc(id: Renderer_ID, desc: Pipeline_Desc) -> Pipeline_ID {
    return RENDERER_API.create_pipeline(id, desc)
}

destroy_pipeline :: proc(id: Renderer_ID, pipeline: Pipeline_ID) {
    RENDERER_API.destroy_pipeline(id, pipeline)
}

Render_Command_Bind_Pipeline :: struct {
    id:          Renderer_ID,
    pipeline_id: Pipeline_ID,
}

cmd_bind_pipeline :: proc(cmd: Render_Command_Bind_Pipeline) { insert_render_command(cmd) }

// *** Buffer ***
Buffer_ID :: distinct uint

MAX_BUFFERS   :: #config(MAX_BUFFERS, 8)

Buffer_Type :: enum {
    Vertex,
    Index,
}

Buffer_Access :: enum {
    Dynamic,
}

create_buffer :: proc(id: Renderer_ID, data: rawptr, length: int, type: Buffer_Type, access: Buffer_Access) -> Buffer_ID {
    assert(length > 0)
    return RENDERER_API.create_buffer(id, data, length, type, access)
}

create_buffer_zeros :: proc(id: Renderer_ID, length: int, type: Buffer_Type, access: Buffer_Access) -> Buffer_ID {
    assert(length > 0)
    return RENDERER_API.create_buffer_zeros(id, length, type, access)
}

push_buffer :: proc(id: Renderer_ID, bid: Buffer_ID, data: rawptr, offset: uint, length: int, access: Buffer_Access) {
    RENDERER_API.push_buffer(id, bid, data, offset, length, access)
}

push_buffer_slice :: proc(id: Renderer_ID, bid: Buffer_ID, data: $T/[]$E, offset: int) {
    RENDERER_API.push_buffer(id, bid, data, offset, len(data) * size_of(E), offset)
}

destroy_buffer :: proc(id: Renderer_ID, buffer: Buffer_ID) {
    RENDERER_API.destroy_buffer(id, buffer)
}

Render_Command_Bind_Vertex_Buffer :: struct {
    id: Renderer_ID,
    buffer_id: Buffer_ID,
    offset: uint,
    index: uint,
}

cmd_bind_vertex_buffer :: proc(cmd: Render_Command_Bind_Vertex_Buffer) { insert_render_command(cmd) }

// *** Texture ***
import stbi "vendor:stb/image"

Texture_ID :: distinct uint

MAX_TEXTURES  :: #config(MAX_TEXTURES, 32)

Texture_Format :: enum {
    RGBA8,
    BGRA8,
    R8,
    RG8,
    RGBA16F,
    RGBA32F,
    // Depth/Stencil formats
    Depth32F,
}

create_texture :: proc(id: Renderer_ID, desc: Texture_Desc) -> Texture_ID { return RENDERER_API.create_texture(id, desc) }
destroy_texture :: proc(id: Renderer_ID, texture: Texture_ID) { RENDERER_API.destroy_texture(id, texture) }

// NOTE: Caller is responsible for calling stbi.image_free(data) when done
load_tex :: proc(filepath: string) -> (data: rawptr, width: int, height: int) {
    w, h, c: i32

    pixels := stbi.load(strings.clone_to_cstring(filepath, context.temp_allocator), &w, &h, &c, 4)
    assert(pixels != nil, fmt.tprintf("Can't load texture from: %v", filepath))

    width = int(w)
    height = int(h)
    data = pixels

    return
}

Render_Command_Bind_Texture :: struct {
    id:         Renderer_ID,
    texture_id: Texture_ID,
    slot:       uint,
}

cmd_bind_texture :: proc(cmd: Render_Command_Bind_Texture) { insert_render_command(cmd) }

// Drawing
Index_Type :: enum {
    UInt16,
    UInt32,
}

Primitive_Type :: enum {
    Triangle,
}

Render_Command_Draw_Simple :: struct {
    id:            Renderer_ID,
    bid:           Buffer_ID,
    buffer_offset: uint,
    buffer_index:  uint,
    primitive:     Primitive_Type,
    vertex_start:  uint,
    vertex_count:  uint,
}

cmd_draw_simple :: proc(cmd: Render_Command_Draw_Simple) {
    insert_render_command(cmd)
}

draw_instanced :: proc(id: Renderer_ID, vertex_buffer: Buffer_ID, index_count, index_buffer_offset, instance_count: uint, index_type: Index_Type, primitive: Primitive_Type) {
    RENDERER_API.draw_instanced(id, vertex_buffer, index_count, index_buffer_offset, instance_count, index_type, primitive)
}

Render_Command_Draw_Indexed :: struct {
    rid:           Renderer_ID,
    vertex_id:     Buffer_ID,
    vertex_offset: uint,
    vertex_index:  uint,
    primitive:     Primitive_Type,
  
    index_id:      Buffer_ID,
    index_type:    Index_Type,
    index_count:   uint,
    index_offset:  uint,
}

cmd_draw_indexed :: proc(cmd: Render_Command_Draw_Indexed) { insert_render_command(cmd) }

Draw_Batched :: struct {
    texture:  Texture_ID,
    position: Vec3,
    rotation: Vec3,
    scale:    Vec3,
    uv_rect:  UV_Rect,
    color:    Color,
}

draw_batched :: proc(batch: ^Sprite_Batch, cmd: Draw_Batched) {
    if batch.texture != cmd.texture {
        flush(batch)
        batch.texture = cmd.texture
    }

    if batch.vertex_count + 4 >= len(batch.vertices) {
        flush(batch)
    }

    // Build model matrix: Translation * Rotation * Scale
    model := mat4_model(cmd.position, cmd.rotation, cmd.scale)

    // Define local-space quad vertices (unit quad centered at origin)
    // These will be transformed by the model matrix to world space
    local_positions := [4]Vec4{
        {-0.5, -0.5, 0, 1},  // bottom-left
        { 0.5, -0.5, 0, 1},  // bottom-right
        { 0.5,  0.5, 0, 1},  // top-right
        {-0.5,  0.5, 0, 1},  // top-left
    }

    // Transform each vertex by model matrix to get world-space positions
    world_positions: [4]Vec3
    for i in 0..<4 {
        transformed := model * local_positions[i]
        world_positions[i] = {transformed.x, transformed.y, transformed.z}
    }

    batch.vertices[batch.vertex_count] = Sprite_Vertex {
        position = world_positions[0],
        uv = cmd.uv_rect.min,
        color = cmd.color,
    }

    batch.vertices[batch.vertex_count + 1] = Sprite_Vertex {
        position = world_positions[1],
        uv = {cmd.uv_rect.max.x, cmd.uv_rect.min.y},
        color = cmd.color,
    }

    batch.vertices[batch.vertex_count + 2] = Sprite_Vertex {
        position = world_positions[2],
        uv = cmd.uv_rect.max,
        color = cmd.color,
    }

    batch.vertices[batch.vertex_count + 3] = Sprite_Vertex {
        position = world_positions[3],
        uv = {cmd.uv_rect.min.x, cmd.uv_rect.max.y},
        color = cmd.color,
    }

    batch.vertex_count += 4
}

flush :: proc(batch: ^Sprite_Batch) {
    if batch.vertex_count == 0 {
        return
    }

    push_buffer(batch.rid, batch.vertex_buffer, raw_data(batch.vertices[:]), 0, size_of(Sprite_Vertex) * batch.vertex_count, .Dynamic)
    cmd_bind_texture({id=batch.rid, texture_id=batch.texture, slot=batch.texture_slot})
    cmd_draw_indexed(Render_Command_Draw_Indexed{
        rid = batch.rid,
        vertex_id = batch.vertex_buffer,
        index_id = batch.index_buffer,
        primitive = .Triangle,
        vertex_offset = 0,
        vertex_index = 0,
        index_offset = 0,
        index_type = .UInt32,
        index_count = uint(batch.vertex_count / 4) * 6
    })

    batch.vertex_count = 0
}

// Shader

import "core:bufio"
import "core:os"
import "core:io"
import "core:strings"

Shader :: struct {
    vertex_entrypoint: string,
    fragment_entrypoint: string,
}

ShaderLanguage :: enum {
    SPIRV,      // Vulkan
    MSL,        // Metal
    HLSL,       // Direct3D
}

load_shader :: proc(filepath, vertex_identifier, fragment_identifier: string, vertex_end, fragment_end: byte) -> (vertex, fragment: string, err: os.Error) {
    
    source_type: ShaderLanguage
    if strings.has_suffix(filepath, ".metal") {
        source_type = .MSL
    } else if strings.has_suffix(filepath, ".hlsl") {
        source_type = .HLSL
    } else if strings.has_suffix(filepath, ".spv") {
        source_type = .SPIRV
    }

    reader: bufio.Reader
    file_handle := open_file_stream(&reader, filepath) or_return
    defer close_file_stream(file_handle, &reader)

    vertex = read_section(&reader, vertex_identifier, vertex_end) or_return
    fragment = read_section(&reader, fragment_identifier, fragment_end) or_return
    
    return
}

open_file_stream :: proc(reader: ^bufio.Reader, filepath: string) -> (handle: os.Handle, err: os.Error) {
    handle = os.open(filepath) or_return
    bufio.reader_init(reader, os.stream_from_handle(handle))
    
    return
}

close_file_stream :: proc(handle: os.Handle, reader: ^bufio.Reader) {
    os.close(handle)
    bufio.reader_destroy(reader)
}

read_section :: proc(reader: ^bufio.Reader, start: string, end: byte) -> (section: string, err: os.Error) {
    for {
        line, read_err := bufio.reader_read_string(reader, '\n', context.temp_allocator)
        if read_err != nil {
            if read_err == os.ERROR_EOF {
                break
            }
            err = read_err
            return
        }

        if strings.has_prefix(line, start) {
            section = bufio.reader_read_string(reader, end) or_return
            return
        }
    }

    return
}
// *** Drawing ***

Uniforms :: struct {
    view_projection: matrix[4,4]f32,
}


UV_Rect :: struct {
    min: Vec2,  // bottom-left UV
    max: Vec2,  // top-right UV
}

Sprite_Vertex :: struct {
    position: Vec3,
    _:        f32,
    uv:       Vec2,
    color:    Color,
}

MAX_SPRITES :: 4_096
Sprite_Batch :: struct {
    vertices:      [MAX_SPRITES * 4]Sprite_Vertex,
    vertex_buffer: Buffer_ID,
    index_buffer:  Buffer_ID,
    
    vertex_count:  int,
    texture:       Texture_ID,
    texture_slot:  uint,
    rid:           Renderer_ID,
}

sprite_batch_init :: proc(renderer_id: Renderer_ID, texture_id: Texture_ID, texture_slot: uint) -> ^Sprite_Batch {
    batch := new(Sprite_Batch)
    
    indices := make([]u32, 6 * MAX_SPRITES)
    for i in 0..<MAX_SPRITES {
        base := i * 4
        indices[i*6 + 0] = u32(base + 0)
        indices[i*6 + 1] = u32(base + 1)
        indices[i*6 + 2] = u32(base + 2)
        indices[i*6 + 3] = u32(base + 2)
        indices[i*6 + 4] = u32(base + 3)
        indices[i*6 + 5] = u32(base + 0)
    }

    batch.vertex_buffer = create_buffer_zeros(renderer_id, MAX_SPRITES * 4 * size_of(Sprite_Vertex), .Vertex, .Dynamic)
    batch.index_buffer = create_buffer(renderer_id, raw_data(indices[:]), len(indices) * size_of(u32), .Index, .Dynamic)

    batch.texture = texture_id
    batch.texture_slot = texture_slot
    batch.rid = renderer_id

    return batch
}

// *** Pipeline Blending ***

Blend_Factor :: enum {
    Zero,
    One,
    SrcColor,
    OneMinusSrcColor,
    SrcAlpha,
    OneMinusSrcAlpha,
    DstColor,
    OneMinusDstColor,
    DstAlpha,
    OneMinusDstAlpha,
}

Blend_Operation :: enum {
    Add,
    Subtract,
    ReverseSubtract,
    Min,
    Max,
}

Depth_Compare_Function :: enum {
    Never,
    Less,
    Equal,
    LessEqual,
    Greater,
    NotEqual,
    GreaterEqual,
    Always,
}

Blend_Descriptor :: struct {
    enabled: bool,
    src_color: Blend_Factor,
    dst_color: Blend_Factor,
    color_op: Blend_Operation,
    src_alpha: Blend_Factor,
    dst_alpha: Blend_Factor,
    alpha_op: Blend_Operation,
}

OpaqueBlend :: Blend_Descriptor{
    enabled = false,
}

AlphaBlend :: Blend_Descriptor{
    enabled = true,
    
    // RGB: src.rgb * src.a + dst.rgb * (1 - src.a)
    src_color = .SrcAlpha,
    dst_color = .OneMinusSrcAlpha,
    color_op  = .Add,
    
    // Alpha: src.a * 1 + dst.a * (1 - src.a)
    src_alpha = .One,
    dst_alpha = .OneMinusSrcAlpha,
    alpha_op  = .Add,
}

// *** Camera ***

Camera :: struct {
    position:     Vec3,
    rotation:     Vec3,
    aspect_ratio: f32,
    zoom:         f32,
    near_z:       f32,
    far_z:        f32,
}

// *** MATH ***

import "core:math/linalg"
import "core:math"

// TRANSLATE
mat4_translate_vector3 :: proc(v: Vec3) -> matrix[4, 4]f32 {
    return {
        1, 0, 0, v.x,
        0, 1, 0, v.y,
        0, 0, 1, v.z,
        0, 0, 0, 1
    }
}

// ROTATE
mat4_rotate_x :: proc "contextless" (angle_radians: f32) -> matrix[4, 4]f32 {
    c := math.cos(angle_radians)
    s := math.sin(angle_radians)
    return {
        1,  0, 0, 0,
        0,  c, -s, 0,
        0,  s, c, 0,
        0, 0, 0, 1
    }
}

mat4_rotate_y :: proc "contextless" (angle_radians: f32) -> matrix[4, 4]f32 {
    c := math.cos(angle_radians)
    s := math.sin(angle_radians)
    return {
        c, 0, s, 0,
        0, 1,  0, 0, 
        -s, 0,  c, 0,
        0, 0, 0, 1
    }   
}

mat4_rotate_z :: proc "contextless" (angle_radians: f32) -> matrix[4, 4]f32 {
    c := math.cos(angle_radians)
    s := math.sin(angle_radians)
    return {
        c,  -s, 0, 0,
        s,  c, 0, 0,
        0,  0, 1, 0,
        0, 0, 0, 1
    }
}

mat4_rotate_euler :: proc "contextless" (radians_rotation: Vec3) -> matrix[4, 4]f32 {
    Rx := mat4_rotate_x(radians_rotation.x)
    Ry := mat4_rotate_y(radians_rotation.y)
    Rz := mat4_rotate_z(radians_rotation.z)

    return Rz * Ry * Rx
}

// SCALE
mat4_scale_vector3 :: proc(v: Vec3) -> matrix[4, 4]f32 {
    return {
        v.x, 0,   0,   0,
        0,   v.y, 0,   0,
        0,   0,   v.z, 0,
        0,   0,   0,   1
    }
}

mat4_scale_uniform :: proc(s: f32) -> matrix[4, 4]f32 {
    return mat4_scale_vector3({s, s, s})
}

// MODEL
mat4_model :: proc(position, radian_rotation, scale: Vec3) -> matrix[4, 4]f32 {
    T := mat4_translate_vector3(position)
    R := mat4_rotate_euler(radian_rotation)
    S := mat4_scale_vector3(scale)

    return T * R * S
}

// VIEW
mat4_view :: proc(eye, target, up: Vec3) -> matrix[4,4]f32 {
    forward := linalg.normalize(target - eye)  
    right := linalg.normalize(linalg.cross(forward, up))  
    up := linalg.cross(right, forward) 
    
    return {
        right.x,     right.y,     right.z,   -linalg.dot(right, eye),
        up.x,        up.y,        up.z,      -linalg.dot(up, eye),
        -forward.x, -forward.y,  -forward.z,  linalg.dot(forward, eye),
        0,           0,           0,          1,
    }
}

// ORTHOGRAPHIC
mat4_ortho :: proc(left, right, bottom, top, near, far: f32) -> matrix[4, 4]f32 {
    rl := right - left
    tb := top - bottom
    nf := near - far 

    return {
        2/rl,   0,      0,      -(right+left)/rl,
        0,      2/tb,   0,      -(top+bottom)/tb,
        0,      0,      1/nf,    near/nf,
        0,      0,      0,      1,
    }
}

mat4_ortho_fixed_height :: proc(height: f32, aspect: f32, near: f32 = 0, far: f32 = 1) -> matrix[4,4]f32 {
    width := height * aspect
    left   := -width * 0.5
    right  :=  width * 0.5
    bottom := -height * 0.5
    top    :=  height * 0.5
    return mat4_ortho(left, right, bottom, top, near, far)
}

// *** Texture Sampler *** 
Sampler_ID :: distinct uint

MAX_SAMPLERS :: #config(MAX_SAMPLERS, 8)

Texture_Desc :: struct {
    width: int,
    height: int,
    format: Texture_Format,
    
    data: rawptr,          // Pixel data (can be nil for empty texture)
    bytes_per_row: int,    // 0 = auto-calculate
}

Sampler_Desc :: struct {
    min_filter: Sampler_Filter,
    mag_filter: Sampler_Filter,
    wrap_s: Sampler_Wrap_Mode,
    wrap_t: Sampler_Wrap_Mode,
}

Sampler_Filter :: enum {
    Nearest,
    Linear,
}

Sampler_Wrap_Mode :: enum {
    Repeat,
    ClampToEdge,
    MirrorRepeat,
}

Texture_Sampler_Filter :: enum {
    Nearest,
    Linear,
}

Texture_Sampler_Address_Mode :: enum {
    Repeat,
    MirrorRepeat,
    ClampToEdge,
    ClampToBorder,
}

Texture_Sampler_Desc :: struct {
    min_filter:     Texture_Sampler_Filter,
    mag_filter:     Texture_Sampler_Filter,
    mip_filter:     Texture_Sampler_Filter,
    address_mode_u: Texture_Sampler_Address_Mode,
    address_mode_v: Texture_Sampler_Address_Mode,
    address_mode_w: Texture_Sampler_Address_Mode,
    max_anisotropy: int,
}

create_sampler :: proc(id: Renderer_ID, desc: Sampler_Desc) -> Sampler_ID { return RENDERER_API.create_sampler(id, desc) }
destroy_sampler :: proc(id: Renderer_ID, sampler: Sampler_ID) { RENDERER_API.destroy_sampler(id, sampler) }

Render_Command_Bind_Sampler :: struct {
    id:      Renderer_ID,
    sampler: Sampler_ID,
    slot:    uint,
}

cmd_bind_sampler :: proc(cmd: Render_Command_Bind_Sampler) { insert_render_command(cmd) }

