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

    init: proc(window: Window_Provider) -> Renderer_ID,
    begin_frame: proc(id: Renderer_ID),
    end_frame: proc(id: Renderer_ID),
    set_clear_color: proc(id: Renderer_ID, color: [4]f32),

    // Pipeline
    create_pipeline: proc(id: Renderer_ID, desc: Pipeline_Desc) -> Pipeline_ID,
    destroy_pipeline: proc(id: Renderer_ID, pipeline: Pipeline_ID),
    bind_pipeline: proc(id: Renderer_ID, pipeline: Pipeline_ID),

    // Buffers
    create_buffer: proc(id: Renderer_ID, desc: Buffer_Desc) -> Buffer_ID,
    push_buffer: proc(id: Renderer_ID, bid: Buffer_ID, data: rawptr, offset: uint, lenght: int),
    destroy_buffer: proc(id: Renderer_ID, buffer: Buffer_ID),

    // Drawing
    draw: proc(id: Renderer_ID, vertex_buffer: Buffer_ID, vertex_count: int),
}

Renderer :: struct {
    ctx: runtime.Context,

    renderer_states: []byte,
    state_size: int,
    max_renderers: int,

    frame_allocator: runtime.Allocator,
}

renderer: Renderer

MAX_PIPELINES :: 64
MAX_BUFFERS :: 256

main :: proc() {
    fmt.println("Hellope")
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

init_renderer :: proc(window: Window_Provider) -> Renderer_ID {
    return RENDERER_API.init(window)
}

Renderer_ID :: distinct uint
Pipeline_ID :: distinct uint
Buffer_ID :: distinct uint

Buffer_Type :: enum {
    Vertex,
    Index,
}

Buffer_Desc :: struct {
    type: Buffer_Type,
    data: rawptr,
    size: int,
}

Vertex_Format :: enum {
    Float,
    Float2,
    Float3,
    Float4,
}

Vertex_Attribute :: struct {
    format: Vertex_Format,
    offset: int,
}

Vertex_Layout :: struct {
    stride: int,
    attributes: []Vertex_Attribute,
}

Pipeline_Desc :: struct {
    vertex_shader:   string,  // Shader source code
    fragment_shader: string,  // Shader source code
    vertex_layout:   Vertex_Layout,
}

Renderer_State_Header :: struct {
    is_alive: bool,
    window: Window_Provider,
    clear_color: [4]f32,
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

set_clear_color :: proc(id: Renderer_ID, color: [4]f32) {
    RENDERER_API.set_clear_color(id, color)
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
create_buffer :: proc(id: Renderer_ID, desc: Buffer_Desc) -> Buffer_ID {
    return RENDERER_API.create_buffer(id, desc)
}

push_buffer :: proc(id: Renderer_ID, bid: Buffer_ID, data: rawptr, offset: uint, lenght: int) {
    RENDERER_API.push_buffer(id, bid, data, offset, length)
}

destroy_buffer :: proc(id: Renderer_ID, buffer: Buffer_ID) {
    RENDERER_API.destroy_buffer(id, buffer)
}

// Drawing
draw :: proc(id: Renderer_ID, vertex_buffer: Buffer_ID, vertex_count: int) {
    RENDERER_API.draw(id, vertex_buffer, vertex_count)
}

Vector2 :: [2]f32 
Vector3 :: [3]f32
Vector4 :: [4]f32

Vertex :: struct {
    position: Vector3,
    rotation: Vector3,
    scale   : Vector3,
}
