package huuru

///////////////////////////////////////
/////// METAL IMPLEMENTATION //////////

import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"
import NS "core:sys/darwin/Foundation"


METAL_RENDERER_API :: Renderer_API {
    state_size = metal_state_size,
    init = metal_init,
    begin_frame = metal_begin_frame,
    end_frame = metal_end_frame,
    set_clear_color = metal_set_clear_color,
}

Metal_State :: struct {
    using _ : Renderer_State_Header,
    device: ^MTL.Device,
    swapchain: ^CA.MetalLayer,
    command_queue: ^MTL.CommandQueue,
    drawable: ^CA.MetalDrawable,
    render_pass_descriptor: ^MTL.RenderPassDescriptor,
    command_buffer: ^MTL.CommandBuffer,
    render_encoder: ^MTL.RenderCommandEncoder,
}

metal_state_size :: proc() -> int {
    return size_of(Metal_State)
}

metal_init :: proc(window: Window_Provider) -> Renderer_ID {
    state, id := get_free_state()
    mtl_state := cast(^Metal_State)state

    mtl_state.window = window
    mtl_state.is_alive = true
    mtl_state.clear_color = {0.0, 0.0, 0.0, 1.0} // Default black

    mtl_state.device = MTL.CreateSystemDefaultDevice()
    assert(mtl_state.device != nil, "Metal not supported.")

    size := window.get_size(window.window_id)

    swapchain := CA.MetalLayer.layer()
    swapchain->setDevice(mtl_state.device)
    swapchain->setPixelFormat(.BGRA8Unorm)
    swapchain->setDrawableSize({NS.Float(size.x), NS.Float(size.y)})

    mtl_window := cast(^NS.Window)window.get_native_handle(window.window_id)
    mtl_window->contentView()->setLayer(swapchain)
    mtl_window->contentView()->setWantsLayer(true)

    mtl_state.command_queue = mtl_state.device->newCommandQueue()
    mtl_state.render_pass_descriptor = MTL.RenderPassDescriptor.alloc()->init()
    mtl_state.swapchain = swapchain

    return id
}

metal_begin_frame :: proc(id: Renderer_ID) {
    mtl_state := cast(^Metal_State)get_state_from_id(id)

    // Acquire next drawable
    mtl_state.drawable = mtl_state.swapchain->nextDrawable()
    
    // Configure render pass descriptor with clear color
    color_attachment := mtl_state.render_pass_descriptor->colorAttachments()->object(0)
    color_attachment->setTexture(mtl_state.drawable->texture())
    color_attachment->setLoadAction(.Clear)
    color_attachment->setStoreAction(.Store)
    color_attachment->setClearColor(MTL.ClearColor{
        f64(mtl_state.clear_color.r),
        f64(mtl_state.clear_color.g),
        f64(mtl_state.clear_color.b),
        f64(mtl_state.clear_color.a),
    })

    // Create command buffer and render encoder
    mtl_state.command_buffer = mtl_state.command_queue->commandBuffer()
    mtl_state.render_encoder = mtl_state.command_buffer->renderCommandEncoderWithDescriptor(
        mtl_state.render_pass_descriptor,
    )
}

metal_end_frame :: proc(id: Renderer_ID) {
    mtl_state := cast(^Metal_State)get_state_from_id(id)

    // End encoding
    mtl_state.render_encoder->endEncoding()

    // Present and commit
    mtl_state.command_buffer->presentDrawable(mtl_state.drawable)
    mtl_state.command_buffer->commit()
}

metal_set_clear_color :: proc(id: Renderer_ID, color: [4]f32) {
    mtl_state := cast(^Metal_State)get_state_from_id(id)
    mtl_state.clear_color = color
}
