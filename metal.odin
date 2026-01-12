package huuru

///////////////////////////////////////
/////// METAL IMPLEMENTATION //////////

import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"
import NS "core:sys/darwin/Foundation"

import "core:mem"
import "core:log"

// Whether we're building for MacOS or iOS, does nothing for now
MACOS :: #config(MACOS, true)

METAL_RENDERER_API :: Renderer_API {
    state_size = metal_state_size,
    init = metal_init,
    begin_frame = metal_begin_frame,
    end_frame = metal_end_frame,
    create_pipeline = metal_create_pipeline,
    destroy_pipeline = metal_destroy_pipeline,
    bind_pipeline = metal_bind_pipeline,
    
    create_buffer = metal_create_buffer,
    create_buffer_zeros = create_buffer_zeros,
    push_buffer = metal_push_buffer,
    destroy_buffer = metal_destroy_buffer,
    
    draw_simple = metal_draw_simple,
    draw_instanced = metal_draw_instanced,

    present = metal_present,
}

Metal_Pipeline :: struct {
    is_alive: bool,
    pipeline_state: ^MTL.RenderPipelineState,
}

Metal_Buffer :: struct {
    is_alive: bool,
    buffer: ^MTL.Buffer,
    type: Buffer_Type,
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

    // Shader library
    shader_library: ^MTL.Library,

    // Pipeline storage
    pipelines: [MAX_PIPELINES]Metal_Pipeline,

    // Buffer storage
    buffers: [MAX_BUFFERS]Metal_Buffer,
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

    url := NS.URL.alloc()->initFileURLWithPath(NS.AT("shaders.metallib"))
    library, err := mtl_state.device->newLibraryWithURL(url)
    assert(err == nil, "Error loading metallib")
    mtl_state.shader_library = library

    return id
}

metal_present :: proc() {
    NS.scoped_autoreleasepool()

    for render_command in renderer.render_commands[:renderer.render_command_c] {
        switch cmd in render_command {
            case Render_Command_Begin_Frame:
                metal_begin_frame(cmd.id)
            case Render_Command_End_Frame:
                metal_end_frame(cmd.id)
            case Render_Command_Draw_Simple:
                metal_draw_simple(cmd.id, cmd.bid, cmd.buffer_offset, cmd.buffer_index, cmd.primitive, cmd.vertex_start, cmd.vertex_count)
            case Render_Command_Bind_Pipeline:
                metal_bind_pipeline(cmd.id, cmd.pipeline_id)
        }
    }
}

@(private)
mtl_state: ^Metal_State

metal_begin_frame :: proc(id: Renderer_ID){
    mtl_state = cast(^Metal_State)get_state_from_id(id)

    // Acquire next drawable
    mtl_state.drawable = mtl_state.swapchain->nextDrawable()
    
    if mtl_state.drawable == nil {
        log.warn("Warning: No drawable, skipping frame")
        return
    }

    if mtl_state.drawable->texture() == nil {
        log.warn("Warning: Drawable texture is nil, skipping frame")
        return
    }
    
    // Configure render pass descriptor with clear color
    color_attachment := mtl_state.render_pass_descriptor->colorAttachments()->object(0)
    color_attachment->setTexture(mtl_state.drawable->texture())
    color_attachment->setLoadAction(.Clear)
    color_attachment->setStoreAction(.Store)

    color_to_mtl_color :: proc(color: Color) -> MTL.ClearColor {
        return {
            f64(color.r / 255.0),
            f64(color.g / 255.0),
            f64(color.b / 255.0),
            f64(color.a / 255.0),
        }
    }

    color_attachment->setClearColor(color_to_mtl_color(mtl_state.clear_color))

    // Create command buffer and render encoder
    mtl_state.command_buffer = mtl_state.command_queue->commandBuffer()
    mtl_state.render_encoder = mtl_state.command_buffer->renderCommandEncoderWithDescriptor(
        mtl_state.render_pass_descriptor,
    )
}

metal_end_frame :: proc(id: Renderer_ID) {
    assert(mtl_state != nil, "Render state is nil")

    // End encoding
    mtl_state.render_encoder->endEncoding()

    // Present and commit
    mtl_state.command_buffer->presentDrawable(mtl_state.drawable)
    mtl_state.command_buffer->commit()

    mtl_state = nil
}

// Pipeline functions

@(private="file")
metal_get_free_pipeline :: proc(mtl_state: ^Metal_State) -> Pipeline_ID {
    for i in 0..<MAX_PIPELINES {
        if !mtl_state.pipelines[i].is_alive {
            return Pipeline_ID(i)
        }
    }
    log.panic("All pipeline slots are in use!")
}

@(private="file")
metal_vertex_format_to_mtl := [Vertex_Format]MTL.VertexFormat {
    .Float  = .Float,
    .Float2 = .Float2,
    .Float3 = .Float3,
    .Float4 = .Float4,
}

metal_create_pipeline :: proc(id: Renderer_ID, desc: Pipeline_Desc) -> Pipeline_ID {
    mtl_state := cast(^Metal_State)get_state_from_id(id)
    pipeline_id := metal_get_free_pipeline(mtl_state)

    function_name_vert := NS.String.alloc()->initWithOdinString(desc.type.(Pipeline_Desc_Metal).vertex_entry)
    vertex_function := mtl_state.shader_library->newFunctionWithName(function_name_vert)
    assert(vertex_function != nil, "Vertex function 'vertex_main' not found")
    
    function_name_frag := NS.String.alloc()->initWithOdinString(desc.type.(Pipeline_Desc_Metal).fragment_entry)
    fragment_function := mtl_state.shader_library->newFunctionWithName(function_name_frag)
    assert(fragment_function != nil, "Fragment function 'fragment_main' not found")

    // Create vertex descriptor
    vertex_descriptor := MTL.VertexDescriptor.alloc()->init()
    
    for attr, i in desc.attributes {
        mtl_attr := vertex_descriptor->attributes()->object(NS.UInteger(i))
        mtl_attr->setFormat(metal_vertex_format_to_mtl[attr.format])
        mtl_attr->setOffset(NS.UInteger(attr.offset))
        mtl_attr->setBufferIndex(NS.UInteger(attr.binding))
    }

    for layout, i in desc.layouts {
        mtl_layout := vertex_descriptor->layouts()->object(NS.UInteger(i))
        mtl_layout->setStride(NS.UInteger(layout.stride))
        mtl_layout->setStepFunction(step_rate_to_mtl_step_rate[layout.step_rate])
    }

    // Create pipeline descriptor
    pipeline_descriptor := MTL.RenderPipelineDescriptor.alloc()->init()
    pipeline_descriptor->setVertexDescriptor(vertex_descriptor)
    pipeline_descriptor->setVertexFunction(vertex_function)
    pipeline_descriptor->setFragmentFunction(fragment_function)
    pipeline_descriptor->colorAttachments()->object(0)->setPixelFormat(.BGRA8Unorm)

    // Create pipeline state
    pipeline_state, pipeline_err := mtl_state.device->newRenderPipelineState(pipeline_descriptor)
    assert(pipeline_err == nil, "Failed to create render pipeline state")

    mtl_state.pipelines[pipeline_id].is_alive = true
    mtl_state.pipelines[pipeline_id].pipeline_state = pipeline_state

    return pipeline_id
}

step_rate_to_mtl_step_rate := [Vertex_Step_Rate]MTL.VertexStepFunction {
    .PerVertex = .PerVertex,
    .PerInstance = .PerInstance,
}

metal_destroy_pipeline :: proc(id: Renderer_ID, pipeline: Pipeline_ID) {
    mtl_state := cast(^Metal_State)get_state_from_id(id)
    
    assert(int(pipeline) < MAX_PIPELINES && int(pipeline) >= 0, "Invalid Pipeline_ID")
    assert(mtl_state.pipelines[pipeline].is_alive, "Pipeline already destroyed")
    
    // Release the pipeline state
    mtl_state.pipelines[pipeline].pipeline_state->release()
    mtl_state.pipelines[pipeline].is_alive = false
    mtl_state.pipelines[pipeline].pipeline_state = nil
}

metal_bind_pipeline :: proc(id: Renderer_ID, pipeline: Pipeline_ID) {
    assert(mtl_state != nil, "State not set")    
    assert(int(pipeline) < MAX_PIPELINES && int(pipeline) >= 0, "Invalid Pipeline_ID")
    assert(mtl_state.pipelines[pipeline].is_alive, "Cannot bind destroyed pipeline")
    
    mtl_state.render_encoder->setRenderPipelineState(mtl_state.pipelines[pipeline].pipeline_state)
    mtl_state.render_encoder->setTriangleFillMode(.Fill)
}

// Buffer functions

metal_get_free_buffer :: proc(mtl_state: ^Metal_State) -> Buffer_ID {
    for i in 0..<MAX_BUFFERS {
        if !mtl_state.buffers[i].is_alive {
            return Buffer_ID(i)
        }
    }
    log.panic("All buffer slots are in use!")
}

metal_create_buffer_zeros :: proc(id: Renderer_ID, length: uint, type: Buffer_Type, access: Buffer_Access) -> Buffer_ID {
    mtl_state := cast(^Metal_State)get_state_from_id(id)
    buffer_id := metal_get_free_buffer(mtl_state)

    storage_mode: MTL.ResourceOptions
    switch access {
        case .Static:
            storage_mode = {.StorageModePrivate}
        case .Dynamic:
            storage_mode = {.StorageModeManaged}
    }

    mtl_buffer := mtl_state.device->newBufferWithLength(
        NS.UInteger(length),
        storage_mode
    )
    assert(mtl_buffer != nil, "Failed to create Metal buffer")

    mtl_state.buffers[buffer_id].is_alive = true
    mtl_state.buffers[buffer_id].buffer = mtl_buffer
    mtl_state.buffers[buffer_id].type = type

    return buffer_id
}

metal_create_buffer :: proc(id: Renderer_ID, data: rawptr, length: int, type: Buffer_Type, access: Buffer_Access) -> Buffer_ID {
    mtl_state := cast(^Metal_State)get_state_from_id(id)
    buffer_id := metal_get_free_buffer(mtl_state)

    storage_mode: MTL.ResourceOptions
    switch access {
        case .Static:
            storage_mode = {.StorageModePrivate}
        case .Dynamic:
            storage_mode = {.StorageModeManaged}
    }

    mtl_buffer := mtl_state.device->newBufferWithBytes(
        mem.byte_slice(data, length),
        storage_mode,
    )
    assert(mtl_buffer != nil, "Failed to create Metal buffer")

    mtl_state.buffers[buffer_id].is_alive = true
    mtl_state.buffers[buffer_id].buffer = mtl_buffer
    mtl_state.buffers[buffer_id].type = type

    return buffer_id
}

metal_push_buffer :: proc(id: Renderer_ID, bid: Buffer_ID, data: rawptr, offset: uint, length: int, access: Buffer_Access) {
    mtl_state := cast(^Metal_State)get_state_from_id(id)
    buffer := mtl_state.buffers[bid].buffer

    contents := buffer->contents()

    assert(int(offset) + length <= len(contents), "Buffer overflow")

    dest := mem.ptr_offset(raw_data(contents), offset)
    mem.copy(dest, data, length)

    //On MacOS, Shared buffers need manual sync. Not in iOS
    when MACOS {
        if access == .Dynamic {
            buffer->didModifyRange(NS.Range{
                location = NS.UInteger(offset),
                length   = NS.UInteger(length),
            })
        }
    }
}

metal_destroy_buffer :: proc(id: Renderer_ID, buffer: Buffer_ID) {
    mtl_state := cast(^Metal_State)get_state_from_id(id)
    
    assert(int(buffer) < MAX_BUFFERS && int(buffer) >= 0, "Invalid Buffer_ID")
    assert(mtl_state.buffers[buffer].is_alive, "Buffer already destroyed")
    
    mtl_state.buffers[buffer].buffer->release()
    mtl_state.buffers[buffer].is_alive = false
    mtl_state.buffers[buffer].buffer = nil
}

// Drawing functions

index_type_to_MTL_type := [Index_Type]MTL.IndexType {
    .UInt32 = .UInt32,
    .UInt16 = .UInt16,
}

primitive_type_to_MTL_primitive := [Primitive_Type]MTL.PrimitiveType {
    .Triangle = .Triangle,
}

metal_draw_simple :: proc(renderer_id: Renderer_ID, buffer_id: Buffer_ID, buffer_offset: uint, buffer_index: uint, primitive: Primitive_Type, vertex_start: uint, vertex_count: uint) {
    mtl_buffer := mtl_state.buffers[0].buffer
    mtl_state.render_encoder->setVertexBuffer(mtl_buffer, NS.UInteger(buffer_offset), NS.UInteger(buffer_index))
    mtl_state.render_encoder->drawPrimitives(
        primitive_type_to_MTL_primitive[primitive],
        NS.UInteger(vertex_start),
        NS.UInteger(vertex_count)
    )
}

metal_draw_instanced :: proc(id: Renderer_ID, bid: Buffer_ID, index_count, index_buffer_offset, instance_count: uint, index_type: Index_Type, primitive: Primitive_Type) {
    assert(mtl_state != nil, "State not set")
    assert(int(bid) < MAX_BUFFERS && int(bid) >= 0, "Invalid Buffer_ID")
    assert(mtl_state.buffers[bid].is_alive, "Cannot draw with destroyed buffer")
    assert(mtl_state.buffers[bid].type == .Vertex, "Buffer must be a vertex buffer")

    buffer := mtl_state.buffers[bid].buffer
    
    mtl_state.render_encoder->drawIndexedPrimitivesWithInstanceCount(
        primitive_type_to_MTL_primitive[primitive],
        NS.UInteger(index_count),
        index_type_to_MTL_type[index_type],
        buffer,
        NS.UInteger(index_buffer_offset),
        NS.UInteger(instance_count)
    )
}
