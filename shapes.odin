package huuru

import "base:runtime"
import stbi "vendor:stb/image"

SPRITES_PER_FRAME :: #config(SPRITES_PER_FRAME, 100_000)

sprite_batch: ^Sprite_Batch



batcher_init :: proc(renderer_id: Renderer_ID, allocator: runtime.Allocator) {
    sprite_batch = new(Sprite_Batch, allocator)
    indices := make([]u32, 6 * SPRITES_PER_FRAME, allocator)
    for i in 0..<SPRITES_PER_FRAME {
        base := i * 4
        indices[i*6 + 0] = u32(base + 0)
        indices[i*6 + 1] = u32(base + 1)
        indices[i*6 + 2] = u32(base + 2)
        indices[i*6 + 3] = u32(base + 2)
        indices[i*6 + 4] = u32(base + 3)
        indices[i*6 + 5] = u32(base + 0)
    }

    tex_data, tex_width, tex_height := load_tex(get_asset_path("assets/White_1x1.png"))
    
    sprite_batch^ = {
        rid           = renderer_id,
        texture       = create_texture(renderer_id, Texture_Desc {
            data   = tex_data,
            width  = tex_width,
            height = tex_height,
            format = .RGBA8
        }),
        texture_slot  = 0,
        vertex_buffer = create_buffer_zeros(renderer_id, SPRITES_PER_FRAME * 4 * size_of(Sprite_Vertex), .Vertex, .Dynamic),
        index_buffer  = create_buffer(renderer_id, raw_data(indices[:]), len(indices) * size_of(u32), .Index, .Dynamic),
    }

    stbi.image_free(cast([^]byte)tex_data)
}


QUAD_LOCAL_POSITIONS :: [4]Vec4 {
    {-0.5, -0.5, 0, 1},  // bottom-left
    { 0.5, -0.5, 0, 1},  // bottom-right
    { 0.5,  0.5, 0, 1},  // top-right
    {-0.5,  0.5, 0, 1},  // top-left
}

QUAD_LOCAL_UVS :: [4]Vec2 {
    {0, 0}, // bottom-left
    {1, 0}, // bottom-right
    {1, 1}, // top-right
    {0, 1}, // top-left
}

quad_local_positions := QUAD_LOCAL_POSITIONS
quad_local_uvs := QUAD_LOCAL_UVS

draw_rect :: proc(position: Vec2, rotation: f32, size: Vec2, color: Color) {
    model := mat4_model(
        position        = {position.x, position.y, 0}, 
        radian_rotation = Vec3{0, 0, rotation},
        scale           = Vec3{size.x, size.y, 0}
    )

    for i in 0..<4 {
        transformed := model * quad_local_positions[i]
        sprite_batch.vertices[sprite_batch.vertex_count + i] = Sprite_Vertex {
            position = {transformed.x, transformed.y, 0, 0},
            uv = quad_local_uvs[i],
            color = color,
        }
    }

    sprite_batch.vertex_count += 4
}

flush_shapes_batch :: proc() {
    if sprite_batch.vertex_count == 0 {
        return
    }

    byte_offset := uint(sprite_batch.buffer_offset * size_of(Sprite_Vertex))

    push_buffer(sprite_batch.rid, sprite_batch.vertex_buffer, raw_data(sprite_batch.vertices[:]), byte_offset, size_of(Sprite_Vertex) * sprite_batch.vertex_count, .Dynamic)
    cmd_bind_texture({id=sprite_batch.rid, texture_id=sprite_batch.texture, slot=sprite_batch.texture_slot})
    cmd_draw_indexed(Render_Command_Draw_Indexed{
        rid = sprite_batch.rid,
        vertex_id = sprite_batch.vertex_buffer,
        index_id = sprite_batch.index_buffer,
        primitive = .Triangle,
        vertex_offset = byte_offset,
        vertex_index = 0,
        index_offset = 0,
        index_type = .UInt32,
        index_count = uint(sprite_batch.vertex_count / 4) * 6
    })

    sprite_batch.buffer_offset += sprite_batch.vertex_count
    sprite_batch.vertex_count = 0
}

import "core:os"
import "core:path/filepath"
import "core:strings"

ASSET_BASE_PATH: string

get_executable_dir :: proc(allocator := context.allocator) -> (dir: string, ok: bool) {
    exe_path := os.args[0]
    dir = filepath.dir(exe_path, allocator)

    // when ODIN_OS == .Darwin { dir = filepath.dir(dir, allocator) } // optional

    return dir, dir != ""
}

get_asset_path :: proc(rel_path: string, allocator := context.allocator) -> string {
    if ASSET_BASE_PATH == "" {
        exe_dir, ok := get_executable_dir(context.temp_allocator)
        if !ok {
            panic("Failed to find executable directory!\n")
        }

        ASSET_BASE_PATH = strings.clone(exe_dir)
    }
    return filepath.join({ASSET_BASE_PATH, rel_path}, allocator)
}