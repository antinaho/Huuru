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
    create_buffer_zeros = metal_create_buffer_zeros,
    push_buffer = metal_push_buffer,
    destroy_buffer = metal_destroy_buffer,

    create_texture = metal_create_texture,
    destroy_texture = metal_destroy_texture,
    bind_texture = metal_bind_texture,
    
    draw_simple = metal_draw_simple,
    draw_instanced = metal_draw_instanced,

    present = metal_present,

    create_sampler = metal_create_sampler,
    bind_sampler = metal_bind_sampler,
    destroy_sampler = metal_destroy_sampler,
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

Metal_Texture :: struct {
    is_alive: bool,
    texture: ^MTL.Texture,
}

Metal_Sampler :: struct {
    is_alive: bool,
    sampler: ^MTL.SamplerState,
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

    // Skip frame flag (set when resize/visibility causes early return)
    skip_frame: bool,

    // Pipeline storage
    pipelines: [MAX_PIPELINES]Metal_Pipeline,

    // Buffer storage
    buffers: [MAX_BUFFERS]Metal_Buffer,

    // Texture storage
    textures: [MAX_TEXTURES]Metal_Texture,
    samplers: [MAX_SAMPLERS]Metal_Sampler,
}

metal_state_size :: proc() -> int {
    return size_of(Metal_State)
}

metal_init :: proc(window: Window_Provider) -> Renderer_ID {
    state, id := get_free_state()
    mtl_state := cast(^Metal_State)state

    mtl_state.window = window
    mtl_state.is_alive = true

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
            case Render_Command_Bind_Texture:
                metal_bind_texture(cmd.id, cmd.texture_id, cmd.slot)
            case Render_Command_Bind_Vertex_Buffer:
                metal_bind_vertex_buffer(cmd.id, cmd.buffer_id, cmd.offset, cmd.index)
            case Render_Command_Draw_Indexed:
                metal_draw_indexed(cmd.rid, cmd.vertex_id, cmd.vertex_offset, cmd.vertex_index, cmd.primitive, cmd.index_count, cmd.index_type, cmd.index_id, cmd.index_offset)
            case Render_Command_Bind_Sampler:
                metal_bind_sampler(cmd.id, cmd.sampler, cmd.slot)
        }
    }
}

@(private)
mtl_state: ^Metal_State

swapchain_size :: proc() -> [2]int {
    size := mtl_state.swapchain->drawableSize()
    return {
        int(size.width),
        int(size.height)
    }
}

resize_swapchain :: proc() {
    size := mtl_state.window.get_size(mtl_state.window.window_id)
    mtl_state.swapchain->setDrawableSize({NS.Float(size.x), NS.Float(size.y)})
}

metal_begin_frame :: proc(id: Renderer_ID){
    mtl_state = cast(^Metal_State)get_state_from_id(id)
    mtl_state.skip_frame = false

    // Acquire next drawable
    mtl_state.drawable = mtl_state.swapchain->nextDrawable()
    
    if !mtl_state.window.is_visible(mtl_state.window.window_id) || mtl_state.window.is_minimized(mtl_state.window.window_id) {
        log.info("Window not visible or minimized, skipping draw")
        mtl_state.skip_frame = true
        return
    }

    if mtl_state.drawable == nil {
        log.warn("Warning: No drawable, skipping frame")
        mtl_state.skip_frame = true
        return
    }

    if mtl_state.window.get_size(mtl_state.window.window_id) != swapchain_size() {
        log.info("Resizing swapchain")
        resize_swapchain()
        mtl_state.skip_frame = true
        return
    }

    if mtl_state.drawable->texture() == nil {
        log.warn("Warning: Drawable texture is nil, skipping frame")
        mtl_state.skip_frame = true
        return
    }

    color_to_mtl_color :: proc(color: Color) -> MTL.ClearColor {
        return {
            f64(color.r) / 255.0,
            f64(color.g) / 255.0,
            f64(color.b) / 255.0,
            f64(color.a) / 255.0,
        }
    }

    color_attachment := mtl_state.render_pass_descriptor->colorAttachments()->object(0)
    color_attachment->setTexture(mtl_state.drawable->texture())
    color_attachment->setLoadAction(.Clear)
    color_attachment->setStoreAction(.Store)
    color_attachment->setClearColor(color_to_mtl_color(BACKGROUND_COLOR))

    // Create command buffer and render encoder
    mtl_state.command_buffer = mtl_state.command_queue->commandBuffer()
    mtl_state.render_encoder = mtl_state.command_buffer->renderCommandEncoderWithDescriptor(
        mtl_state.render_pass_descriptor,
    )
}

metal_end_frame :: proc(id: Renderer_ID) {
    assert(mtl_state != nil, "Render state is nil")

    if mtl_state.skip_frame {
        mtl_state = nil
        return
    }

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
    .UByte4 = .UChar4,
}

metal_blend_factor := [Blend_Factor]MTL.BlendFactor {
    .Zero             = .Zero,
    .One              = .One,
    .SrcColor         = .SourceColor,
    .OneMinusSrcColor = .OneMinusSourceColor,
    .SrcAlpha         = .SourceAlpha,
    .OneMinusSrcAlpha = .OneMinusSourceAlpha,
    .DstColor         = .DestinationColor,
    .OneMinusDstColor = .OneMinusDestinationColor,
    .DstAlpha         = .DestinationAlpha,
    .OneMinusDstAlpha = .OneMinusDestinationAlpha,
}

metal_blend_operation := [Blend_Operation]MTL.BlendOperation {
    .Add             = .Add,
    .Subtract        = .Subtract,
    .ReverseSubtract = .ReverseSubtract,
    .Min             = .Min,
    .Max             = .Max,
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

    color_attachment := pipeline_descriptor->colorAttachments()->object(0)
    color_attachment->setPixelFormat(.BGRA8Unorm)

    if desc.blend.enabled {
        color_attachment->setBlendingEnabled(true)
        color_attachment->setSourceRGBBlendFactor(metal_blend_factor[desc.blend.src_color])
        color_attachment->setDestinationRGBBlendFactor(metal_blend_factor[desc.blend.dst_color])
        color_attachment->setRgbBlendOperation(metal_blend_operation[desc.blend.color_op])
        
        color_attachment->setSourceAlphaBlendFactor(metal_blend_factor[desc.blend.src_alpha])
        color_attachment->setDestinationAlphaBlendFactor(metal_blend_factor[desc.blend.dst_alpha])
        color_attachment->setAlphaBlendOperation(metal_blend_operation[desc.blend.alpha_op])
    } else {
        color_attachment->setBlendingEnabled(false)
    }   

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
    if mtl_state.skip_frame do return
    
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

metal_create_buffer_zeros :: proc(id: Renderer_ID, length: int, type: Buffer_Type, access: Buffer_Access) -> Buffer_ID {
    mtl_state := cast(^Metal_State)get_state_from_id(id)
    buffer_id := metal_get_free_buffer(mtl_state)

    storage_mode: MTL.ResourceOptions
    switch access {
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

// Texture functions

@(private="file")
metal_get_free_texture :: proc(mtl_state: ^Metal_State) -> Texture_ID {
    for i in 0..<MAX_TEXTURES {
        if !mtl_state.textures[i].is_alive {
            return Texture_ID(i)
        }
    }
    log.panic("All texture slots are in use!")
}

MAX_SAMPLERS :: #config(MAX_SAMPLERS, 4)

metal_get_free_sampler :: proc(mtl_state: ^Metal_State) -> Sampler_ID {
    for i in 0..<MAX_SAMPLERS {
        if !mtl_state.samplers[i].is_alive {
            return Sampler_ID(i)
        }
    }
    log.panic("All sampler slots are in use!")
}

@(private="file")
texture_format_to_mtl := [Texture_Format]MTL.PixelFormat {
    .RGBA8    = .RGBA8Unorm,
    .BGRA8    = .BGRA8Unorm,
    .R8       = .R8Unorm,
    .RG8      = .RG8Unorm,
    .RGBA16F  = .RGBA16Float,
    .RGBA32F  = .RGBA32Float,
}

@(private="file")
texture_format_bytes_per_pixel := [Texture_Format]int {
    .RGBA8    = 4,
    .BGRA8    = 4,
    .R8       = 1,
    .RG8      = 2,
    .RGBA16F  = 8,
    .RGBA32F  = 16,
}

@(private="file")
texture_filter_to_mtl := [Texture_Filter]MTL.SamplerMinMagFilter {
    .Nearest = .Nearest,
    .Linear  = .Linear,
}

@(private="file")
texture_wrap_to_mtl := [Texture_Wrap]MTL.SamplerAddressMode {
    .Repeat       = .Repeat,
    .ClampToEdge  = .ClampToEdge,
    .MirrorRepeat = .MirrorRepeat,
}

metal_create_texture :: proc(id: Renderer_ID, desc: Texture_Desc) -> Texture_ID {
    mtl_state := cast(^Metal_State)get_state_from_id(id)
    texture_id := metal_get_free_texture(mtl_state)

    // Create texture descriptor
    texture_desc := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(
        texture_format_to_mtl[desc.format],
        NS.UInteger(desc.width),
        NS.UInteger(desc.height),
        false, // mipmapped
    )
    texture_desc->setUsage({.ShaderRead})
    texture_desc->setStorageMode(.Managed)

    // Create the texture
    texture := mtl_state.device->newTextureWithDescriptor(texture_desc)
    assert(texture != nil, "Failed to create Metal texture")

    // Upload pixel data if provided
    if desc.data != nil {
        bytes_per_row := desc.bytes_per_row
        if bytes_per_row == 0 {
            bytes_per_row = desc.width * texture_format_bytes_per_pixel[desc.format]
        }

        texture->replaceRegion(
            MTL.Region {
                origin = {0, 0, 0},
                size = {NS.Integer(desc.width), NS.Integer(desc.height), 1},
            },
            0, // mipmap level
            desc.data,
            NS.UInteger(bytes_per_row),
        )
    }

    mtl_state.textures[texture_id].is_alive = true
    mtl_state.textures[texture_id].texture = texture

    return texture_id
}



metal_bind_texture :: proc(id: Renderer_ID, texture: Texture_ID, slot: uint) {
    if mtl_state == nil || mtl_state.skip_frame do return

    assert(int(texture) < MAX_TEXTURES && int(texture) >= 0, "Invalid Texture_ID")
    assert(mtl_state.textures[texture].is_alive, "Cannot bind destroyed texture")

    mtl_state.render_encoder->setFragmentTexture(mtl_state.textures[texture].texture, NS.UInteger(slot))
}

metal_destroy_texture :: proc(id: Renderer_ID, texture: Texture_ID) {
    mtl_state := cast(^Metal_State)get_state_from_id(id)

    assert(int(texture) < MAX_TEXTURES && int(texture) >= 0, "Invalid Texture_ID")
    assert(mtl_state.textures[texture].is_alive, "Texture already destroyed")

    mtl_state.textures[texture].texture->release()
    
    mtl_state.textures[texture].is_alive = false
    mtl_state.textures[texture].texture = nil
    
}


// Drawing functions

metal_bind_vertex_buffer :: proc(id: Renderer_ID, buffer_id: Buffer_ID, offset: uint, index: uint) {
    if mtl_state == nil || mtl_state.skip_frame do return

    assert(int(buffer_id) < MAX_BUFFERS && int(buffer_id) >= 0, "Invalid Buffer_ID")
    assert(mtl_state.buffers[buffer_id].is_alive, "Cannot bind destroyed buffer")

    mtl_buffer := mtl_state.buffers[buffer_id].buffer
    mtl_state.render_encoder->setVertexBuffer(mtl_buffer, NS.UInteger(offset), NS.UInteger(index))
}

index_type_to_MTL_type := [Index_Type]MTL.IndexType {
    .UInt32 = .UInt32,
    .UInt16 = .UInt16,
}

primitive_type_to_MTL_primitive := [Primitive_Type]MTL.PrimitiveType {
    .Triangle = .Triangle,
}

metal_draw_simple :: proc(renderer_id: Renderer_ID, buffer_id: Buffer_ID, buffer_offset: uint, buffer_index: uint, primitive: Primitive_Type, vertex_start: uint, vertex_count: uint) {
    if mtl_state.skip_frame do return
    
    mtl_buffer := mtl_state.buffers[buffer_id].buffer
    mtl_state.render_encoder->setVertexBuffer(mtl_buffer, NS.UInteger(buffer_offset), NS.UInteger(buffer_index))
    mtl_state.render_encoder->drawPrimitives(
        primitive_type_to_MTL_primitive[primitive],
        NS.UInteger(vertex_start),
        NS.UInteger(vertex_count)
    )
}

metal_draw_indexed :: proc(id: Renderer_ID, vertex_buffer_id: Buffer_ID, buffer_offset: uint, buffer_index: uint, primitive: Primitive_Type, index_count: uint, index_type: Index_Type, index_buffer: Buffer_ID, index_buffer_offset: uint) {
    if mtl_state.skip_frame do return

    mtl_vertex_buffer := mtl_state.buffers[vertex_buffer_id].buffer
    mtl_state.render_encoder->setVertexBuffer(mtl_vertex_buffer, NS.UInteger(buffer_offset), NS.UInteger(buffer_index))
    mtl_index_buffer := mtl_state.buffers[index_buffer].buffer
    
    mtl_state.render_encoder->drawIndexedPrimitives(
        primitive_type_to_MTL_primitive[primitive],
        NS.UInteger(index_count),
        index_type_to_MTL_type[index_type],
        mtl_index_buffer,
        NS.UInteger(index_buffer_offset),
    )
}

metal_draw_instanced :: proc(id: Renderer_ID, buffer_id: Buffer_ID, index_count, index_buffer_offset, instance_count: uint, index_type: Index_Type, primitive: Primitive_Type) {
    assert(mtl_state != nil, "State not set")
    if mtl_state.skip_frame do return
    
    assert(int(buffer_id) < MAX_BUFFERS && int(buffer_id) >= 0, "Invalid Buffer_ID")
    assert(mtl_state.buffers[buffer_id].is_alive, "Cannot draw with destroyed buffer")
    assert(mtl_state.buffers[buffer_id].type == .Vertex, "Buffer must be a vertex buffer")

    buffer := mtl_state.buffers[buffer_id].buffer
    
    mtl_state.render_encoder->drawIndexedPrimitivesWithInstanceCount(
        primitive_type_to_MTL_primitive[primitive],
        NS.UInteger(index_count),
        index_type_to_MTL_type[index_type],
        buffer,
        NS.UInteger(index_buffer_offset),
        NS.UInteger(instance_count)
    )
}

// Sampler

metal_create_sampler :: proc(id: Renderer_ID, desc: Sampler_Desc) -> Sampler_ID {
    mtl_state := cast(^Metal_State)get_state_from_id(id)
    sampler_id := metal_get_free_sampler(mtl_state)

    sampler_desc := MTL.SamplerDescriptor.alloc()->init()
    sampler_desc->setMinFilter(texture_filter_to_mtl[desc.min_filter])
    sampler_desc->setMagFilter(texture_filter_to_mtl[desc.mag_filter])
    sampler_desc->setSAddressMode(texture_wrap_to_mtl[desc.wrap_s])
    sampler_desc->setTAddressMode(texture_wrap_to_mtl[desc.wrap_t])

    sampler := mtl_state.device->newSamplerState(sampler_desc)
    assert(sampler != nil, "Failed to create Metal sampler state")

    mtl_state.samplers[sampler_id].sampler = sampler

    return sampler_id
}

metal_bind_sampler :: proc(id: Renderer_ID, sampler: Sampler_ID, slot: uint) {
    if mtl_state == nil || mtl_state.skip_frame do return
    
    assert(int(sampler) < MAX_SAMPLERS && int(sampler) >= 0, "Invalid Sampler_ID")
    assert(mtl_state.samplers[sampler].is_alive, "Cannot bind destroyed sampler")

    mtl_state.render_encoder->setFragmentSamplerState(mtl_state.samplers[sampler].sampler, NS.UInteger(slot))
}

metal_destroy_sampler :: proc(id: Renderer_ID, sampler: Sampler_ID) {
    assert(int(sampler) < MAX_SAMPLERS && int(sampler) >= 0, "Invalid Sampler_OD")
    assert(mtl_state.samplers[sampler].is_alive, "Sampler already destroyed")

    mtl_state.samplers[sampler].sampler->release()
    mtl_state.samplers[sampler].is_alive = false
    mtl_state.samplers[sampler].sampler = nil
}
