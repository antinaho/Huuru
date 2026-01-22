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
    depth_stencil_state: ^MTL.DepthStencilState,
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

Metal_Argument_Buffer :: struct {
    is_alive:      bool,
    buffer:        ^MTL.Buffer,
    encoder:       ^MTL.ArgumentEncoder,
    max_textures:  uint,
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
    shader_library: ^MTL.Library,

    // Skip frame flag (set when resize/visibility causes early return)
    skip_frame: bool,

    // MSAA
    msaa_texture: ^MTL.Texture,
    sample_count: NS.UInteger,  // 1 = no MSAA, 2/4/8 for MSAA

    // Depth/Stencil
    depth_stencil_texture: ^MTL.Texture,

    // Pipeline storage
    pipelines: [MAX_PIPELINES]Metal_Pipeline,

    // Buffer storage
    buffers: [MAX_BUFFERS]Metal_Buffer,

    // Texture storage
    textures: [MAX_TEXTURES]Metal_Texture,
    samplers: [MAX_SAMPLERS]Metal_Sampler,

    // Argument buffer storage (for bindless textures)
    argument_buffers: [MAX_ARGUMENT_BUFFERS]Metal_Argument_Buffer,
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

    size := window.get_size(window.data)

    swapchain := CA.MetalLayer.layer()
    swapchain->setDevice(mtl_state.device)
    swapchain->setPixelFormat(.BGRA8Unorm)
    swapchain->setDrawableSize({NS.Float(size.x), NS.Float(size.y)})

    mtl_window := cast(^NS.Window)window.get_native_handle(window.data)
    mtl_window->contentView()->setLayer(swapchain)
    mtl_window->contentView()->setWantsLayer(true)

    mtl_state.command_queue = mtl_state.device->newCommandQueue()
    mtl_state.render_pass_descriptor = MTL.RenderPassDescriptor.alloc()->init()
    mtl_state.swapchain = swapchain

    // Set MSAA sample count and create MSAA/depth textures
    mtl_state.sample_count = NS.UInteger(window.sample_count)
    create_msaa_and_depth_textures(mtl_state, size.x, size.y)

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
            case Render_Command_Bind_Argument_Buffer:
                metal_bind_argument_buffer(cmd.id, cmd.argument_buffer_id, cmd.slot)
            case Render_Command_Draw_Indexed_Instanced:
                metal_draw_index_instanced(cmd.rid, cmd.index_buffer, cmd.index_count, cmd.index_buffer_offset, cmd.instance_count, cmd.index_type, cmd.primitive)
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
    size := mtl_state.window.get_size(mtl_state.window.data)
    mtl_state.swapchain->setDrawableSize({NS.Float(size.x), NS.Float(size.y)})
    
    // Recreate MSAA and depth textures at new size
    create_msaa_and_depth_textures(mtl_state, size.x, size.y)
}

// Creates or recreates MSAA color texture and depth/stencil texture.
// Called during init and on swapchain resize.
create_msaa_and_depth_textures :: proc(state: ^Metal_State, width, height: int) {
    // Release old textures if they exist
    if state.msaa_texture != nil {
        state.msaa_texture->release()
        state.msaa_texture = nil
    }
    if state.depth_stencil_texture != nil {
        state.depth_stencil_texture->release()
        state.depth_stencil_texture = nil
    }

    // Early out if dimensions are invalid
    if width <= 0 || height <= 0 {
        log.error("Trying to create with negative size")
        return
    }

    sample_count := state.sample_count
    if sample_count == 0 {
        sample_count = 1
    }

    // Create MSAA color texture (only if sample_count > 1)
    if sample_count > 1 {
        msaa_desc := MTL.TextureDescriptor.alloc()->init()
        msaa_desc->setTextureType(.Type2DMultisample)
        msaa_desc->setPixelFormat(.BGRA8Unorm)
        msaa_desc->setWidth(NS.UInteger(width))
        msaa_desc->setHeight(NS.UInteger(height))
        msaa_desc->setSampleCount(sample_count)
        msaa_desc->setUsage({.RenderTarget})
        msaa_desc->setStorageMode(.Private)

        state.msaa_texture = state.device->newTextureWithDescriptor(msaa_desc)
        assert(state.msaa_texture != nil, "Failed to create MSAA texture")
        msaa_desc->release()
    }

    // Create depth/stencil texture
    depth_desc := MTL.TextureDescriptor.alloc()->init()
    if sample_count > 1 {
        depth_desc->setTextureType(.Type2DMultisample)
        depth_desc->setSampleCount(sample_count)
    } else {
        depth_desc->setTextureType(.Type2D)
    }
    depth_desc->setPixelFormat(.Depth32Float)
    depth_desc->setWidth(NS.UInteger(width))
    depth_desc->setHeight(NS.UInteger(height))
    depth_desc->setUsage({.RenderTarget})
    depth_desc->setStorageMode(.Private)

    state.depth_stencil_texture = state.device->newTextureWithDescriptor(depth_desc)
    assert(state.depth_stencil_texture != nil, "Failed to create depth/stencil texture")
    depth_desc->release()
}

metal_begin_frame :: proc(id: Renderer_ID){
    mtl_state = cast(^Metal_State)get_state_from_id(id)
    mtl_state.skip_frame = false

    // Acquire next drawable
    mtl_state.drawable = mtl_state.swapchain->nextDrawable()
    
    if !mtl_state.window.is_visible(mtl_state.window.data) || mtl_state.window.is_minimized(mtl_state.window.data) {
        log.info("Window not visible or minimized, skipping draw")
        mtl_state.skip_frame = true
        return
    }

    if mtl_state.drawable == nil {
        log.warn("Warning: No drawable, skipping frame")
        mtl_state.skip_frame = true
        return
    }

    if mtl_state.window.get_size(mtl_state.window.data) != swapchain_size() {
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

    // Configure color attachment
    color_attachment := mtl_state.render_pass_descriptor->colorAttachments()->object(0)
    color_attachment->setLoadAction(.Clear)
    color_attachment->setClearColor(color_to_mtl_color(BACKGROUND_COLOR))

    if mtl_state.sample_count > 1 {
        // MSAA: render to MSAA texture, resolve to drawable
        color_attachment->setTexture(mtl_state.msaa_texture)
        color_attachment->setResolveTexture(mtl_state.drawable->texture())
        color_attachment->setStoreAction(.MultisampleResolve)
    } else {
        // No MSAA: render directly to drawable
        color_attachment->setTexture(mtl_state.drawable->texture())
        color_attachment->setResolveTexture(nil)
        color_attachment->setStoreAction(.Store)
    }

    depth_attachment := mtl_state.render_pass_descriptor->depthAttachment()
    depth_attachment->setTexture(mtl_state.depth_stencil_texture)
    depth_attachment->setLoadAction(.Clear)
    depth_attachment->setStoreAction(.DontCare)
    depth_attachment->setClearDepth(1.0)



    // Create command buffer and render encoder
    mtl_state.command_buffer = mtl_state.command_queue->commandBuffer()
    mtl_state.render_encoder = mtl_state.command_buffer->renderCommandEncoderWithDescriptor(
        mtl_state.render_pass_descriptor,
    )


        // Maybe later if needed
    // stencil_attachment := mtl_state.render_pass_descriptor->stencilAttachment()
    // stencil_attachment->setTexture(mtl_state.depth_stencil_texture)
    // stencil_attachment->setLoadAction(.Clear)
    // stencil_attachment->setStoreAction(.DontCare)
    // stencil_attachment->setClearStencil(0)
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

// *** Pipeline ***

metal_get_free_pipeline :: proc(mtl_state: ^Metal_State) -> Pipeline_ID {
    for i in 0..<MAX_PIPELINES {
        if !mtl_state.pipelines[i].is_alive {
            return Pipeline_ID(i)
        }
    }
    log.panic("All pipeline slots are in use!")
}

metal_vertex_format_to_mtl := [Vertex_Format]MTL.VertexFormat {
    .Float  = .Float,
    .Float2 = .Float2,
    .Float3 = .Float3,
    .Float4 = .Float4,

    .UByte  = .UChar,
    .UByte4 = .UChar4,

    .UInt32 = .UInt,
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

    // Set MSAA sample count (must match render target)
    pipeline_descriptor->setSampleCount(mtl_state.sample_count)

    // Set depth/stencil attachment formats (must match render pass)
    pipeline_descriptor->setDepthAttachmentPixelFormat(.Depth32Float)
    //pipeline_descriptor->setStencilAttachmentPixelFormat(.Stencil8)

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

    depth_Stencil_Descriptor := MTL.DepthStencilDescriptor_alloc()->init();
    depth_Stencil_Descriptor->setDepthCompareFunction(.LessEqual);
    depth_Stencil_Descriptor->setDepthWriteEnabled(true);
    depth_stencil_state := mtl_state.device->newDepthStencilState(depth_Stencil_Descriptor);

    mtl_state.pipelines[pipeline_id].is_alive = true
    mtl_state.pipelines[pipeline_id].pipeline_state = pipeline_state
    mtl_state.pipelines[pipeline_id].depth_stencil_state = depth_stencil_state

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
    
    mtl_state.render_encoder->setFrontFacingWinding(.CounterClockwise)
    mtl_state.render_encoder->setCullMode(.Back)
    mtl_state.render_encoder->setRenderPipelineState(mtl_state.pipelines[pipeline].pipeline_state)
    mtl_state.render_encoder->setDepthStencilState(mtl_state.pipelines[pipeline].depth_stencil_state)
    mtl_state.render_encoder->setTriangleFillMode(.Fill)
}

// *** Buffer ***

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
        case .Static:
            storage_mode = {.StorageModePrivate}
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
        case .Static:
            storage_mode = {.StorageModePrivate}
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

metal_bind_vertex_buffer :: proc(id: Renderer_ID, buffer_id: Buffer_ID, offset: uint, index: uint) {
    if mtl_state == nil || mtl_state.skip_frame do return

    assert(int(buffer_id) < MAX_BUFFERS && int(buffer_id) >= 0, "Invalid Buffer_ID")
    assert(mtl_state.buffers[buffer_id].is_alive, "Cannot bind destroyed buffer")

    mtl_buffer := mtl_state.buffers[buffer_id].buffer
    mtl_state.render_encoder->setVertexBuffer(mtl_buffer, NS.UInteger(offset), NS.UInteger(index))
}

metal_destroy_buffer :: proc(id: Renderer_ID, buffer: Buffer_ID) {
    mtl_state := cast(^Metal_State)get_state_from_id(id)
    
    assert(int(buffer) < MAX_BUFFERS && int(buffer) >= 0, "Invalid Buffer_ID")
    assert(mtl_state.buffers[buffer].is_alive, "Buffer already destroyed")
    
    mtl_state.buffers[buffer].buffer->release()
    mtl_state.buffers[buffer].is_alive = false
    mtl_state.buffers[buffer].buffer = nil
}

// *** Texture ***

@(private="file")
metal_get_free_texture :: proc(mtl_state: ^Metal_State) -> Texture_ID {
    for i in 0..<MAX_TEXTURES {
        if !mtl_state.textures[i].is_alive {
            return Texture_ID(i)
        }
    }
    log.panic("All texture slots are in use!")
}

texture_format_to_mtl := [Texture_Format]MTL.PixelFormat {
    .RGBA8              = .RGBA8Unorm,
    .BGRA8              = .BGRA8Unorm,
    .R8                 = .R8Unorm,
    .RG8                = .RG8Unorm,
    .RGBA16F            = .RGBA16Float,
    .RGBA32F            = .RGBA32Float,
    .Depth32F           = .Depth32Float,
}

depth_compare_to_mtl := [Depth_Compare_Function]MTL.CompareFunction {
    .Never        = .Never,
    .Less         = .Less,
    .Equal        = .Equal,
    .LessEqual    = .LessEqual,
    .Greater      = .Greater,
    .NotEqual     = .NotEqual,
    .GreaterEqual = .GreaterEqual,
    .Always       = .Always,
}

texture_format_bytes_per_pixel := [Texture_Format]int {
    .RGBA8    = 4,
    .BGRA8    = 4,
    .R8       = 1,
    .RG8      = 2,
    .RGBA16F  = 8,
    .RGBA32F  = 16,
    .Depth32F = 16,
}

texture_wrap_to_mtl := [Sampler_Wrap_Mode]MTL.SamplerAddressMode {
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

// *** Drawing ***

index_type_to_MTL_type := [Index_Type]MTL.IndexType {
    .UInt32 = .UInt32,
    .UInt16 = .UInt16,
}

primitive_type_to_MTL_primitive := [Primitive_Type]MTL.PrimitiveType {
    .Triangle = .Triangle,
    .Line     = .Line,
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
        primitiveType     = primitive_type_to_MTL_primitive[primitive],
        indexCount        = NS.UInteger(index_count),
        indexType         = index_type_to_MTL_type[index_type],
        indexBuffer       = mtl_index_buffer,
        indexBufferOffset = NS.UInteger(index_buffer_offset),
    )
}

metal_draw_index_instanced :: proc(id: Renderer_ID, index_buffer: Buffer_ID, index_count, index_buffer_offset, instance_count: uint, index_type: Index_Type, primitive: Primitive_Type = .Triangle) {
    assert(mtl_state != nil, "State not set")
    if mtl_state.skip_frame do return

    assert(int(index_buffer) < MAX_BUFFERS && int(index_buffer) >= 0, "Invalid Buffer_ID")
    assert(mtl_state.buffers[index_buffer].is_alive, "Cannot draw with destroyed buffer")

    buffer := mtl_state.buffers[index_buffer].buffer

    mtl_state.render_encoder->drawIndexedPrimitivesWithInstanceCount(
        primitive_type_to_MTL_primitive[primitive],
        NS.UInteger(index_count),
        index_type_to_MTL_type[index_type],
        buffer,
        NS.UInteger(index_buffer_offset),
        NS.UInteger(instance_count)
    )
}

metal_draw_instanced :: proc(id: Renderer_ID, buffer_id: Buffer_ID, index_count, index_buffer_offset, instance_count: uint, index_type: Index_Type, primitive: Primitive_Type) {
    assert(false, "Not implemented")
}

// *** Texture Sampler ***

Metal_Sampler :: struct {
    is_alive: bool,
    sampler: ^MTL.SamplerState,
}

texture_filter_to_mtl := [Sampler_Filter]MTL.SamplerMinMagFilter {
    .Nearest = .Nearest,
    .Linear  = .Linear,
}

metal_get_free_sampler :: proc(mtl_state: ^Metal_State) -> Sampler_ID {
    for i in 0..<MAX_SAMPLERS {
        if !mtl_state.samplers[i].is_alive {
            return Sampler_ID(i)
        }
    }
    log.panic("All sampler slots are in use!")
}

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

    mtl_state.samplers[sampler_id].is_alive = true
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

// *** Argument Buffer (for bindless textures) ***

@(private="file")
metal_get_free_argument_buffer :: proc(state: ^Metal_State) -> Argument_Buffer_ID {
    for i in 0..<MAX_ARGUMENT_BUFFERS {
        if !state.argument_buffers[i].is_alive {
            return Argument_Buffer_ID(i)
        }
    }
    log.panic("All argument buffer slots are in use!")
}

// Creates an argument buffer for bindless texture access.
// The function_name should match the fragment function that will use this argument buffer.
// buffer_index is the [[buffer(N)]] index where textures will be bound in the shader.
// max_textures is the number of texture slots to allocate.
metal_create_argument_buffer :: proc(id: Renderer_ID, function_name: string, buffer_index: uint, max_textures: uint) -> Argument_Buffer_ID {
    state := cast(^Metal_State)get_state_from_id(id)
    arg_buffer_id := metal_get_free_argument_buffer(state)

    // Get the fragment function to create the argument encoder
    function_name_ns := NS.String.alloc()->initWithOdinString(function_name)
    fragment_function := state.shader_library->newFunctionWithName(function_name_ns)
    assert(fragment_function != nil, "Fragment function not found for argument buffer")

    // Create argument encoder for the specified buffer index
    encoder := fragment_function->newArgumentEncoder(NS.UInteger(buffer_index))
    assert(encoder != nil, "Failed to create argument encoder")

    // Get the encoded length and create the buffer
    encoded_length := encoder->encodedLength()
    buffer := state.device->newBufferWithLength(encoded_length, {.StorageModeManaged})
    assert(buffer != nil, "Failed to create argument buffer")

    // Set the buffer on the encoder
    encoder->setArgumentBufferWithOffset(buffer, 0)

    state.argument_buffers[arg_buffer_id] = {
        is_alive     = true,
        buffer       = buffer,
        encoder      = encoder,
        max_textures = max_textures,
    }

    return arg_buffer_id
}

// Encodes textures into an argument buffer.
// textures is a slice of Texture_IDs to encode.
// The textures will be encoded at indices 0..len(textures)-1 in the argument buffer.
metal_encode_textures :: proc(id: Renderer_ID, arg_buffer_id: Argument_Buffer_ID, textures: []Texture_ID) {
    state := cast(^Metal_State)get_state_from_id(id)

    assert(int(arg_buffer_id) < MAX_ARGUMENT_BUFFERS && int(arg_buffer_id) >= 0, "Invalid Argument_Buffer_ID")
    assert(state.argument_buffers[arg_buffer_id].is_alive, "Argument buffer not alive")

    arg_buffer := &state.argument_buffers[arg_buffer_id]
    assert(uint(len(textures)) <= arg_buffer.max_textures, "Too many textures for argument buffer")

    // Encode each texture
    for texture_id, i in textures {
        assert(int(texture_id) < MAX_TEXTURES && int(texture_id) >= 0, "Invalid Texture_ID")
        assert(state.textures[texture_id].is_alive, "Cannot encode destroyed texture")

        mtl_texture := state.textures[texture_id].texture
        arg_buffer.encoder->setTexture(mtl_texture, NS.UInteger(i))
    }

    // Mark the buffer as modified so Metal knows to sync to GPU
    arg_buffer.buffer->didModifyRange(NS.Range{
        location = 0,
        length = arg_buffer.buffer->length(),
    })
}

// Binds an argument buffer to a fragment buffer slot for rendering.
metal_bind_argument_buffer :: proc(id: Renderer_ID, arg_buffer_id: Argument_Buffer_ID, slot: uint) {
    if mtl_state == nil || mtl_state.skip_frame do return

    assert(int(arg_buffer_id) < MAX_ARGUMENT_BUFFERS && int(arg_buffer_id) >= 0, "Invalid Argument_Buffer_ID")
    assert(mtl_state.argument_buffers[arg_buffer_id].is_alive, "Cannot bind destroyed argument buffer")

    arg_buffer := mtl_state.argument_buffers[arg_buffer_id].buffer
    mtl_state.render_encoder->setFragmentBuffer(arg_buffer, 0, NS.UInteger(slot))
}

// Destroys an argument buffer and releases its resources.
metal_destroy_argument_buffer :: proc(id: Renderer_ID, arg_buffer_id: Argument_Buffer_ID) {
    state := cast(^Metal_State)get_state_from_id(id)

    assert(int(arg_buffer_id) < MAX_ARGUMENT_BUFFERS && int(arg_buffer_id) >= 0, "Invalid Argument_Buffer_ID")
    assert(state.argument_buffers[arg_buffer_id].is_alive, "Argument buffer already destroyed")

    arg_buffer := &state.argument_buffers[arg_buffer_id]
    
    arg_buffer.encoder->release()
    arg_buffer.buffer->release()
    
    arg_buffer.is_alive = false
    arg_buffer.encoder = nil
    arg_buffer.buffer = nil
}
