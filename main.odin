package huuru

import "base:runtime"
import "core:fmt"
import "core:log"

RENDERER_CHOISE :: #config(RENDERER, "")

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

    // Initialization
    state_size: proc() -> int,

    // Per frame

    init: proc(window: Window_Provider) -> Renderer_ID,
    begin_frame: proc(id: Renderer_ID),
    end_frame: proc(id: Renderer_ID),

    // Pipeline
    create_pipeline: proc(id: Renderer_ID, desc: Pipeline_Desc) -> Pipeline_ID,
    destroy_pipeline: proc(id: Renderer_ID, pipeline: Pipeline_ID),
    bind_pipeline: proc(id: Renderer_ID, pipeline: Pipeline_ID),

    // Buffers
    create_buffer: proc(id: Renderer_ID, data: rawptr, size: int, type: Buffer_Type, access: Buffer_Access) -> Buffer_ID,
    create_buffer_zeros: proc(id: Renderer_ID, length: int, type: Buffer_Type, access: Buffer_Access) -> Buffer_ID,
    push_buffer: proc(id: Renderer_ID, bid: Buffer_ID, data: rawptr, offset: uint, lenght: int, access: Buffer_Access),
    destroy_buffer: proc(id: Renderer_ID, buffer: Buffer_ID),

    // Textures
    create_texture: proc(id: Renderer_ID, desc: Texture_Desc) -> Texture_ID,
    destroy_texture: proc(id: Renderer_ID, texture: Texture_ID),
    bind_texture: proc(id: Renderer_ID, texture: Texture_ID, slot: uint),

    // Drawing
    draw_simple: proc(renderer_id: Renderer_ID, buffer_id: Buffer_ID, buffer_offset: uint, buffer_index: uint, type: Primitive_Type, vertex_start: uint, vertex_count: uint),
    draw_instanced: proc(id: Renderer_ID, vertex_buffer: Buffer_ID, index_count, offset, instance_count: uint, index_type: Index_Type, primitive: Primitive_Type),

    //
    present: proc(),
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

renderer: Renderer

MAX_PIPELINES :: #config(MAX_PIPELINES, 8)
MAX_BUFFERS   :: #config(MAX_BUFFERS, 8)
MAX_TEXTURES  :: #config(MAX_TEXTURES, 32)

main :: proc() {
    // Example: Setting up the renderer and draw loop
    // 
    // This demonstrates how to use the Huuru renderer API to:
    // 1. Initialize the renderer system
    // 2. Create a renderer attached to a window
    // 3. Set up a pipeline with shaders
    // 4. Create vertex/index buffers
    // 5. Run a basic draw loop

    // Step 1: Initialize the renderer system (call once at startup)
    init(renderers = 1)

    // Step 2: Create a window provider
    // You need to implement these callbacks for your windowing system (e.g., SDL, GLFW, native)
    window := Window_Provider {
        window_id = nil, // Your window handle
        get_size = proc(window_id: rawptr) -> [2]int {
            // Return window dimensions
            return {800, 600}
        },
        get_native_handle = proc(window_id: rawptr) -> rawptr {
            // Return native window handle (NSWindow* on macOS)
            return nil
        },
    }

    // Step 3: Initialize a renderer for the window
    renderer_id := init_renderer(window)

    // Step 5: Create a pipeline
    // Requires a precompiled shaders.metallib with vertex and fragment functions
    Vertex :: struct {
        position: [4]f32,
        color:    [4]f32,
    }

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

    // Step 6: Create vertex and index buffers
    vertices := []Vertex{
        { position = {-0.5, -0.5, 0.0, 0.0}, color = {1.0, 0.0, 0.0, 1.0} }, // Red
        { position = { 0.5, -0.5, 0.0, 0.0}, color = {0.0, 1.0, 0.0, 1.0} }, // Green
        { position = { 0.0,  0.5, 0.0, 0.0}, color = {0.0, 0.0, 1.0, 1.0} }, // Blue
    }
    
    indices := []u16{ 0, 1, 2 }

    vertex_buffer := create_buffer(
        renderer_id,
        raw_data(vertices),
        len(vertices) * size_of(Vertex),
        .Vertex,
        .Static,
    )

    index_buffer := create_buffer(
        renderer_id,
        raw_data(indices),
        len(indices) * size_of(u16),
        .Index,
        .Static,
    )

    // Step 6b: Load and create texture
    tex_data, tex_width, tex_height := load_tex("assets/texture.png")
    texture := create_texture(renderer_id, Texture_Desc{
        width      = tex_width,
        height     = tex_height,
        format     = .RGBA8,
        min_filter = .Linear,
        mag_filter = .Linear,
        wrap_s     = .Repeat,
        wrap_t     = .Repeat,
        data       = tex_data,
    })
    stbi.image_free(cast([^]byte)tex_data)

    sprite_batch := sprite_batch_init(renderer_id, texture, 0)

    // Step 7: Draw loop
    running := true
    frame: u32 = 0
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
                    position = {f32(x) * 100 + 50, f32(y) * 100 + 50},
                    size     = {64, 64},
                    color    = {255, 255, 255, 255},
                })
            }
        }

        // Example: Draw with different tint colors
        draw_batched(sprite_batch, Draw_Batched{
            texture  = texture,
            position = {500, 100},
            size     = {128, 128},
            uv_rect  = full_uv,
            color    = {255, 100, 100, 255},  // Red tint
        })

        draw_batched(sprite_batch, Draw_Batched{
            texture  = texture,
            position = {500, 250},
            size     = {128, 128},
            color    = {100, 255, 100, 255},  // Green tint
        })

        // Example: Using UV rect for sprite sheet (assuming 2x2 atlas)
        // Top-left quadrant of texture
        draw_batched(sprite_batch, Draw_Batched{
            texture  = texture,
            position = {500, 400},
            size     = {96, 96},
            color    = {255, 255, 255, 255},
        })

        // Flush remaining sprites in batch
        flush(sprite_batch)

        cmd_end_frame({renderer_id})

        present()
        frame += 1
    }

    // Step 8: Cleanup
    destroy_texture(renderer_id, texture)
    destroy_buffer(renderer_id, vertex_buffer)
    destroy_buffer(renderer_id, index_buffer)
    destroy_pipeline(renderer_id, pipeline)

    destroy()
}

init :: proc(renderers: int = 1) {
    assert(renderers >= 1, "Need at least 1 renderer!")

    backing := make([]byte, 16 * mem.Kilobyte)
    mem.arena_init(&renderer.arena, backing)
    arena_allocator := mem.arena_allocator(&renderer.arena)

    renderer.ctx = context
    state_size := RENDERER_API.state_size()
    
    renderer.renderer_states = make([]byte, state_size * renderers, arena_allocator)
    renderer.state_size = state_size
    renderer.max_renderers = renderers
    renderer.frame_allocator = context.temp_allocator
    renderer.render_commands = make([]Render_Command, 128, arena_allocator)
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

Renderer_ID :: distinct int
Pipeline_ID :: distinct uint
Buffer_ID :: distinct uint
Texture_ID :: distinct uint

Buffer_Type :: enum {
    Vertex,
    Index,
}

Vertex_Format :: enum {
    Float,
    Float2,
    Float3,
    Float4,
    UByte4,
}

Vertex_Attribute :: struct {
    format: Vertex_Format,
    offset: uintptr,
    binding: int, 
}

Vertex_Layout :: struct {
    stride: int,
    step_rate: Vertex_Step_Rate,
}

Vertex_Step_Rate :: enum {
    PerVertex,
    PerInstance,
}

Buffer_Access :: enum {
    Static,
    Dynamic,
}

// Texture types
Texture_Format :: enum {
    RGBA8,
    BGRA8,
    R8,
    RG8,
    RGBA16F,
    RGBA32F,
}

Texture_Filter :: enum {
    Nearest,
    Linear,
}

Texture_Wrap :: enum {
    Repeat,
    ClampToEdge,
    MirrorRepeat,
}

Texture_Desc :: struct {
    width: int,
    height: int,
    format: Texture_Format,
    min_filter: Texture_Filter,
    mag_filter: Texture_Filter,
    wrap_s: Texture_Wrap,
    wrap_t: Texture_Wrap,
    data: rawptr,          // Pixel data (can be nil for empty texture)
    bytes_per_row: int,    // 0 = auto-calculate
}

Pipeline_Desc :: struct {
    type: Pipeline_Desc_Type,
    layouts: []Vertex_Layout,
    attributes: []Vertex_Attribute,
}

Pipeline_Desc_Type :: union {
    Pipeline_Desc_Metal
}

// So far don't need else if you precompile shaders to metallib and load that in Metal
Pipeline_Desc_Metal :: struct {
    vertex_entry  : string,
    fragment_entry: string,
}


Renderer_State_Header :: struct {
    is_alive: bool,
    window: Window_Provider,
    clear_color: Color,

    vertex_buffer: Buffer_ID,
    index_buffer: Buffer_ID,
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
    window_id: rawptr,
    
    get_size: proc(window_id: rawptr) -> [2]int,
    get_native_handle: proc(window_id: rawptr) -> rawptr,
    is_visible: proc(window_id: rawptr) -> bool,
    is_minimized: proc(window_id: rawptr) -> bool,
}

// Frame management
Render_Command :: union {
    Render_Command_Draw_Simple,
    Render_Command_Bind_Pipeline,
    Render_Command_Bind_Texture,
    Render_Command_Begin_Frame,
    Render_Command_End_Frame,

    Render_Command_Draw_Indexed,
}

Render_Command_Begin_Frame :: struct {
    id: Renderer_ID,
}

Render_Command_End_Frame :: struct {
    id: Renderer_ID
}

cmd_begin_frame :: proc(cmd: Render_Command_Begin_Frame) {
    insert_render_command(cmd)
}

cmd_end_frame :: proc(cmd: Render_Command_End_Frame) {
    insert_render_command(cmd)
}

insert_render_command :: proc(cmd: Render_Command) {
    renderer.render_commands[renderer.render_command_c] = cmd
    renderer.render_command_c += 1

    if renderer.render_command_c >= len(renderer.render_commands) {
        assert(false, "Too many commands")
    }
}

// Pipeline
create_pipeline :: proc(id: Renderer_ID, desc: Pipeline_Desc) -> Pipeline_ID {
    return RENDERER_API.create_pipeline(id, desc)
}

destroy_pipeline :: proc(id: Renderer_ID, pipeline: Pipeline_ID) {
    RENDERER_API.destroy_pipeline(id, pipeline)
}

Render_Command_Bind_Pipeline :: struct {
    id: Renderer_ID,
    pipeline_id: Pipeline_ID,
}

cmd_bind_pipeline :: proc(cmd: Render_Command_Bind_Pipeline) {
    insert_render_command(cmd)
}

// Buffer
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

// Texture
create_texture :: proc(id: Renderer_ID, desc: Texture_Desc) -> Texture_ID {
    return RENDERER_API.create_texture(id, desc)
}

import stbi "vendor:stb/image"
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

destroy_texture :: proc(id: Renderer_ID, texture: Texture_ID) {
    RENDERER_API.destroy_texture(id, texture)
}

Render_Command_Bind_Texture :: struct {
    id: Renderer_ID,
    texture_id: Texture_ID,
    slot: uint,
}

// TODO seperate sampler? Currently binds texture and sampler to same slot
cmd_bind_texture :: proc(cmd: Render_Command_Bind_Texture) {
    insert_render_command(cmd)
}

// Drawing
Index_Type :: enum {
    UInt16,
    UInt32,
}

Primitive_Type :: enum {
    Triangle,
}

Render_Command_Draw_Simple :: struct {
    id: Renderer_ID,
    bid: Buffer_ID,
    buffer_offset: uint,
    buffer_index: uint,
    primitive: Primitive_Type,
    vertex_start: uint,
    vertex_count: uint,
}

cmd_draw_simple :: proc(cmd: Render_Command_Draw_Simple) {
    insert_render_command(cmd)
}

draw_instanced :: proc(id: Renderer_ID, vertex_buffer: Buffer_ID, index_count, index_buffer_offset, instance_count: uint, index_type: Index_Type, primitive: Primitive_Type) {
    RENDERER_API.draw_instanced(id, vertex_buffer, index_count, index_buffer_offset, instance_count, index_type, primitive)
}

Render_Command_Draw_Indexed :: struct {
    rid: Renderer_ID,
    vertex_id: Buffer_ID,
    vertex_offset: uint,
    vertex_index: uint,
    primitive: Primitive_Type,
  
    index_id: Buffer_ID,
    index_type: Index_Type,
    index_count: uint,
    index_offset: uint,
}

cmd_draw_indexed :: proc(cmd: Render_Command_Draw_Indexed) {
    insert_render_command(cmd)
}

Draw_Batched :: struct {
    texture: Texture_ID,
    position: Vector2,
    size: Vector2,
    uv_rect: UV_Rect,
    color: Color,
}

draw_batched :: proc(batch: ^Sprite_Batch, cmd: Draw_Batched) {
    if batch.texture != cmd.texture {
        flush(batch)
        batch.texture = cmd.texture
    }

    if batch.vertex_count + 4 >= len(batch.vertices) {
        flush(batch)
    }

    // TODO MVP matrix
    v1 := Sprite_Vertex {
        position = cmd.position,
        uv = {0, 0},
        color = cmd.color,
    }

    v2 := Sprite_Vertex {
        position = cmd.position + {cmd.size.x, 0},
        uv = {1, 0},
        color = cmd.color,
    }

    v3 := Sprite_Vertex {
        position = cmd.position + cmd.size,
        uv = {1, 1},
        color = cmd.color,
    }

    v4 := Sprite_Vertex {
        position = cmd.position + {0, cmd.size.y},
        uv = {0, 1},
        color = cmd.color,
    }

    batch.vertices[batch.vertex_count] = v1
    batch.vertex_count += 1
    batch.vertices[batch.vertex_count] = v2
    batch.vertex_count += 1
    batch.vertices[batch.vertex_count] = v3
    batch.vertex_count += 1
    batch.vertices[batch.vertex_count] = v4
    batch.vertex_count += 1
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



Color :: [4]u8

// Shader

import "core:bufio"
import "core:os"
import "core:io"
import "core:strings"

Free_Node :: struct {
    next: ^Free_Node
}

Pool_Arena :: struct {
    data: []byte,
    chunk_size: int,

    head: ^Free_Node,
}

pool_init :: proc(p: ^Pool_Arena, data: []byte, chunk_size: int) {
	assert(chunk_size >= size_of(Free_Node), "Chunk size is too small");
	assert(len(data) >= chunk_size, "Backing buffer length is smaller than the chunk size");

    p.data = data
    p.chunk_size = chunk_size

    pool_free_all(p)
}

pool_free_all :: proc(p: ^Pool_Arena) {
    chunk_count := len(p.data) / p.chunk_size
    
    for i in 0..<chunk_count {
        ptr := &p.data[i * p.chunk_size]
        node := cast(^Free_Node)ptr
        node.next = p.head
        p.head = node
    }
}

import "core:mem"
pool_alloc :: proc(p: ^Pool_Arena) -> rawptr {
    node := p.head

    if node == nil {
        assert(false, "Pool has no free memory left")
    }

    p.head = p.head.next

    return mem.set(node, 0, p.chunk_size)
}

pool_free :: proc(p: ^Pool_Arena, ptr: rawptr) {
    node: ^Free_Node

    start := uintptr(p.data[0])
    end := uintptr(p.data[len(p.data)])

    if ptr == nil {
        assert(false, "Trying to free a nil pointer")
    }

    if !(start <= uintptr(ptr) && uintptr(ptr) < end) {
        assert(false, "Memory is out of bounds for the buffer")
    }

    node = cast(^Free_Node)ptr
    node.next = p.head
    p.head = node
}

Shader :: struct {
    vertex_entrypoint: string,
    fragment_entrypoint: string,
}

ShaderLanguage :: enum {
    SPIRV,      // Vulkan
    MSL,        // Metal Shading Language
    HLSL,       // Direct3D
}

file_section :: string

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

read_section :: proc(reader: ^bufio.Reader, start: string, end: byte) -> (section: file_section, err: os.Error) {
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

//

Vector2 :: [2]f32
UV_Rect :: struct {
    min: Vector2,  // top-left UV
    max: Vector2,  // bottom-right UV
}

Sprite_Vertex :: struct {
    position: Vector2,
    uv:      Vector2,
    color:    Color,
}

MAX_SPRITES :: 256
Sprite_Batch :: struct {
    vertices:      [MAX_SPRITES * 4]Sprite_Vertex,
    vertex_buffer: Buffer_ID,
    index_buffer:  Buffer_ID,
    
    vertex_count:  int,
    texture:       Texture_ID,
    texture_slot:  uint,
    rid:           Renderer_ID,
}

import "core:slice"
sprite_batch_init :: proc(renderer_id: Renderer_ID, texture_id: Texture_ID, texture_slot: uint) -> ^Sprite_Batch {
    batch := new(Sprite_Batch)
    
    indices: [6 * MAX_SPRITES]u32
    for i in 0..<MAX_SPRITES {
        base := i * 4
        indices[i*6 + 0] = u32(base + 0)
        indices[i*6 + 1] = u32(base + 1)
        indices[i*6 + 2] = u32(base + 2)
        indices[i*6 + 3] = u32(base + 2)
        indices[i*6 + 4] = u32(base + 3)
        indices[i*6 + 5] = u32(base + 0)
    }

    data := slice.clone(indices[:])
    batch.vertex_buffer = create_buffer_zeros(renderer_id, MAX_SPRITES * 4 * size_of(Sprite_Vertex), .Vertex, .Dynamic)
    batch.index_buffer = create_buffer(renderer_id, raw_data(data[:]), len(indices) * size_of(u32), .Index, .Static)

    batch.texture = texture_id
    batch.texture_slot = texture_slot

    return batch
}
