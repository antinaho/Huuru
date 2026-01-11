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
    state_size: proc() -> int,

    init: proc(window: Window_Provider, size_vertex: uint, size_index: uint) -> Renderer_ID,
    begin_frame: proc(id: Renderer_ID),
    end_frame: proc(id: Renderer_ID),
    set_clear_color: proc(id: Renderer_ID, color: Color),

    // Pipeline
    create_pipeline: proc(id: Renderer_ID, desc: Pipeline_Desc) -> Pipeline_ID,
    destroy_pipeline: proc(id: Renderer_ID, pipeline: Pipeline_ID),
    bind_pipeline: proc(id: Renderer_ID, pipeline: Pipeline_ID),

    // Buffers
    create_buffer: proc(id: Renderer_ID, data: rawptr, size: int, type: Buffer_Type, access: Buffer_Access) -> Buffer_ID,
    create_buffer_zeros: proc(id: Renderer_ID, length: int, type: Buffer_Type, access: Buffer_Access),
    push_buffer: proc(id: Renderer_ID, bid: Buffer_ID, data: rawptr, offset: uint, lenght: int, access: Buffer_Access),
    destroy_buffer: proc(id: Renderer_ID, buffer: Buffer_ID),

    // Drawing
    draw_instanced: proc(id: Renderer_ID, vertex_buffer: Buffer_ID, index_count, offset, instance_count: uint, index_type: Index_Type, primitive: Primitive_Type),
}

Renderer :: struct {
    ctx: runtime.Context,

    renderer_states: []byte,
    state_size: int,
    max_renderers: int,

    frame_allocator: runtime.Allocator,
}

renderer: Renderer

MAX_PIPELINES :: #config(MAX_PIPELINES, 8)
MAX_BUFFERS   :: #config(MAX_BUFFERS, 8)

main :: proc() {

    // Shader assets
    max_amount_of_active_shaders := 16
    backing_buffer := make([]byte, max_amount_of_active_shaders * size_of(Shader))
    shader_pool: Pool_Arena
    pool_init(&shader_pool, backing_buffer, size_of(Shader))

    // Loading
    v, f, e := load_shader("test.metal", "#VERTEX", "#FRAGMENT")
    assert(e == nil)
    shader := Shader {
        vertex_source = v,
        fragment_source = f,
    }
}

init :: proc(renderers: int = 1) {
    assert(renderers >= 1, "Need at least 1 renderer!")

    renderer.ctx = context

    state_size := RENDERER_API.state_size()
    
    renderer.renderer_states = make([]byte, state_size * renderers)
    renderer.state_size = state_size
    renderer.max_renderers = renderers
    renderer.frame_allocator = context.temp_allocator
}

init_renderer :: proc(window: Window_Provider, size_vertex, size_index: uint) -> Renderer_ID {
    return RENDERER_API.init(window, size_vertex, size_index)
}

Renderer_ID :: distinct uint
Pipeline_ID :: distinct uint
Buffer_ID :: distinct uint

Buffer_Type :: enum {
    Vertex,
    Index,
}

Vertex_Format :: enum {
    Float,
    Float2,
    Float3,
    Float4,
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

Pipeline_Desc :: struct {
    using _ : Shader,
    layouts: []Vertex_Layout,
    attributes: []Vertex_Attribute,
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
}

// Frame management
begin_frame :: proc(id: Renderer_ID) {
    RENDERER_API.begin_frame(id)
}

end_frame :: proc(id: Renderer_ID) {
    RENDERER_API.end_frame(id)
}

// Pipeline
create_pipeline :: proc(id: Renderer_ID, desc: Pipeline_Desc) -> Pipeline_ID {
    return RENDERER_API.create_pipeline(id, desc)
}

destroy_pipeline :: proc(id: Renderer_ID, pipeline: Pipeline_ID) {
    RENDERER_API.destroy_pipeline(id, pipeline)
}

bind_pipeline :: proc(id: Renderer_ID, pipeline: Pipeline_ID) {
    RENDERER_API.bind_pipeline(id, pipeline)
}

// Buffer
create_buffer :: proc(id: Renderer_ID, data: rawptr, length: int, type: Buffer_Type, access: Buffer_Access) -> Buffer_ID {
    assert(length > 0)
    return RENDERER_API.create_buffer(id, data, length, type, access)
}

create_buffer_zeros :: proc(id: Renderer_ID, length: int, type: Buffer_Type, access: Buffer_Access) {
    assert(length > 0)
    RENDERER_API.create_buffer_zeros(id, length, type, access)
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

// Shader


// Drawing
Index_Type :: enum {
    UInt16,
    UInt32,
}

Primitive_Type :: enum {
    Triangle,
}

set_clear_color :: proc(id: Renderer_ID, color: Color) {
    RENDERER_API.set_clear_color(id, color)
}

draw_instanced :: proc(id: Renderer_ID, vertex_buffer: Buffer_ID, index_count, index_buffer_offset, instance_count: uint, index_type: Index_Type, primitive: Primitive_Type) {
    RENDERER_API.draw_instanced(id, vertex_buffer, index_count, index_buffer_offset, instance_count, index_type, primitive)
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
    vertex_source: string,
    vertex_entrypoint: string,
    fragment_source: string,
    fragment_entrypoint: string,
}

ShaderLanguage :: enum {
    SPIRV,      // Vulkan
    MSL,        // Metal Shading Language
    HLSL,       // Direct3D
}

file_section :: string

load_shader :: proc(filepath, vertex_identifier, fragment_identifier: string) -> (vertex, fragment: string, err: os.Error) {
    
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

    vertex = read_section(&reader, vertex_identifier, '}') or_return
    fragment = read_section(&reader, fragment_identifier, '}') or_return
    
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
