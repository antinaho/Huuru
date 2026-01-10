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
}

Renderer :: struct {
    ctx: runtime.Context,

    renderer_states: []byte,
    state_size: int,
    max_renderers: int,

    frame_allocator: runtime.Allocator,
}

renderer: Renderer

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

// Frame management abstraction
begin_frame :: proc(id: Renderer_ID) {
    RENDERER_API.begin_frame(id)
}

end_frame :: proc(id: Renderer_ID) {
    RENDERER_API.end_frame(id)
}

set_clear_color :: proc(id: Renderer_ID, color: [4]f32) {
    RENDERER_API.set_clear_color(id, color)
}




