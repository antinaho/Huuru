#include <metal_stdlib>
using namespace metal;

// Must match MAX_SHAPE_TEXTURES in shapes.odin
#ifndef MAX_SHAPE_TEXTURES
#define MAX_SHAPE_TEXTURES 128
#endif

struct Shape_Uniforms {
    float4x4 view_projection;
    float2 screen_size;      // screen dimensions in pixels
    float pixel_size;        // virtual pixel size (1.0 = no pixelation, 4.0 = 4x4 pixel blocks)
};

struct Shape_Vertex {
    float2 position [[attribute(0)]];
    float2 uv       [[attribute(1)]];
};

// Must match Shape_Instance in shapes.odin (64 bytes)
struct Shape_Instance {
    float2 position;      // offset 0 total 8
    float2 scale;         // offset 8 total 16

    float4 params;        // offset 16 total 32

    float2 uv_min;        // offset 32 total 40
    float2 uv_max;        // offset 40 total 48

    uchar4 color;         // offset 48 total 52
    float  rotation;      // offset 52 total 56
    uint   kind;          // offset 56 total 60
    uint texture_index;   // offset 60 total 64
};

struct Shape_Out {
    float4 position [[position]];
    float2 uv;           // normalized UV [0,1] for SDF calculations
    float2 tex_uv;       // remapped UV for texture sampling
    float2 uv_min;       // raw uv_min for shapes that need it (e.g., line)
    float2 screen_size;  // screen dimensions for pixel snapping
    float pixel_size;    // virtual pixel size
    float4 color;
    uint kind;
    float4 params;
    uint texture_index;
};

constant uint SHAPE_RECT            = 0;
constant uint SHAPE_CIRCLE          = 1;
constant uint SHAPE_DONUT           = 2;
constant uint SHAPE_TRIANGLE        = 3;
constant uint SHAPE_HOLLOW_RECT     = 4;
constant uint SHAPE_HOLLOW_TRIANGLE = 5;
constant uint SHAPE_TEXTURED_RECT   = 6;
constant uint SHAPE_LINE            = 7;

vertex Shape_Out shape_vertex(
    Shape_Vertex             vert      [[stage_in]],
    constant Shape_Instance* instances [[buffer(1)]],
    uint                     instID    [[instance_id]],
    constant Shape_Uniforms& uniforms  [[buffer(2)]]
) {
    Shape_Out out;
    Shape_Instance inst = instances[instID];

    // scale first, then rotation
    float2 scaled = vert.position * inst.scale;
    
    float c = cos(inst.rotation);
    float s = sin(inst.rotation);
    float2 rotated = float2(
        scaled.x * c - scaled.y * s,
        scaled.x * s + scaled.y * c
    );

    // translation
    float2 world_pos = rotated + inst.position;

    out.position = uniforms.view_projection * float4(world_pos, 0.0, 1.0);
    
    // Keep normalized UV for SDF calculations
    out.uv = vert.uv;
    out.uv.y = 1.0 - out.uv.y;
    
    // Remap UV based on instance uv_min/uv_max for texture sampling
    // lerp from uv_min to uv_max based on vertex uv
    out.tex_uv = mix(inst.uv_min, inst.uv_max, vert.uv);
    out.tex_uv.y = 1.0 - out.tex_uv.y;  // flip Y for texture coordinates
    
    out.color         = float4(inst.color) / 255.0;
    out.kind          = inst.kind;
    out.params        = inst.params;
    out.texture_index = inst.texture_index;
    out.uv_min        = inst.uv_min;
    out.screen_size   = uniforms.screen_size;
    out.pixel_size    = uniforms.pixel_size;

    return out;
}

// SDF for equilateral triangle centered at origin
// p: point to test, r: radius (distance from center to vertex)
float sdf_triangle(float2 p, float r) {
    const float k = sqrt(3.0);
    p.x = abs(p.x) - r;
    p.y = p.y + r / k;
    if (p.x + k * p.y > 0.0) {
        p = float2(p.x - k * p.y, -k * p.x - p.y) / 2.0;
    }
    p.x -= clamp(p.x, -2.0 * r, 0.0);
    return -length(p) * sign(p.y);
}

// SDF for axis-aligned box centered at origin
// p: point to test, b: half-extents (width/2, height/2)
float sdf_box(float2 p, float2 b) {
    float2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// SDF for line segment with round caps
// p: point to test
// a: start point of line segment
// b: end point of line segment
// Returns distance to the line segment (not including radius)
float sdf_line_segment(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

// Pixel-perfect UV sampling (Klems technique)
// Keeps pixels crisp at boundaries while allowing smooth subpixel positioning
float2 uv_klems(float2 uv, int2 texture_size) {
    float2 tex_size = float2(texture_size.x, texture_size.y);
    float2 pixels = uv * tex_size + 0.5;
    
    // tweak fractional value of the texture coordinate
    float2 fl = floor(pixels);
    float2 fr = fract(pixels);
    float2 aa = fwidth(pixels) * 0.75;

    fr = smoothstep(float2(0.5) - aa, float2(0.5) + aa, fr);
    
    return (fl + fr - 0.5) / tex_size;
}



// Pixel-snap a position for SDF calculations
// Similar concept to uv_klems but for SDF coordinate space
// frag_coord: fragment screen position
// screen_size: screen dimensions
// pixel_size: virtual pixel size (1.0 = native, 2.0 = 2x2 blocks, etc.)
// Returns snapped position offset to apply
float2 sdf_pixel_snap(float2 frag_coord, float2 screen_size, float pixel_size) {
    if (pixel_size <= 1.0) {
        return float2(0.0);  // No snapping needed
    }
    
    // Calculate virtual pixel grid
    float2 virtual_pixels = frag_coord / pixel_size;
    float2 fl = floor(virtual_pixels);
    float2 fr = fract(virtual_pixels);
    
    // Snap to pixel center with smooth edge (klems-style)
    float2 aa = fwidth(virtual_pixels) * 0.75;
    fr = smoothstep(float2(0.5) - aa, float2(0.5) + aa, fr);
    
    float2 snapped = (fl + fr) * pixel_size;
    return snapped - frag_coord;
}

// Quantize SDF distance for hard pixel edges
// dist: SDF distance
// pixel_size: virtual pixel size  
// Returns quantized alpha (0 or 1 style, but with slight AA at virtual pixel boundaries)
float sdf_alpha_pixelated(float dist, float radius, float pixel_size) {
    if (pixel_size <= 1.0) {
        // Normal smooth AA
        float aa = fwidth(dist);
        return 1.0 - smoothstep(radius - aa, radius + aa, dist);
    }
    
    // Hard threshold for pixelated look
    return dist < radius ? 1.0 : 0.0;
}



// Argument buffer structure for bindless textures
struct TextureArray {
    array<texture2d<float>, MAX_SHAPE_TEXTURES> textures;
};

fragment float4 shape_fragment(
    Shape_Out                 in             [[stage_in]],
    float4                    frag_coord     [[position]],
    constant TextureArray&    textureArray   [[buffer(3)]],
    sampler                   textureSampler [[sampler(0)]]
) {
    float4 color = in.color;
    float pixel_size = in.pixel_size;
    bool pixelated = pixel_size > 1.0;
    
    // For pixelated mode, snap the UV coordinates to virtual pixel grid
    float2 uv = in.uv;
    if (pixelated) {
        // Convert fragment coord to virtual pixel grid and snap
        float2 virtual_pixel = frag_coord.xy / pixel_size;
        float2 snapped_pixel = floor(virtual_pixel) + 0.5;  // snap to pixel center
        
        // Calculate the offset in UV space
        float2 pixel_offset = (snapped_pixel * pixel_size - frag_coord.xy) / in.screen_size;
        uv = in.uv + pixel_offset;
    }
    
    float2 centered = uv - 0.5;  // center UV at origin, range [-0.5, 0.5]
    float dist = length(centered);

    if (in.kind == SHAPE_CIRCLE) {
        float alpha = sdf_alpha_pixelated(dist, 0.5, pixel_size);
        color.a *= alpha;
    }
    else if (in.kind == SHAPE_DONUT) {
        // Donut: params.x = inner radius ratio (0-1, relative to outer)
        float inner_radius = in.params.x * 0.5;
        float outer_radius = 0.5;
        
        float alpha_outer = sdf_alpha_pixelated(dist, outer_radius, pixel_size);
        float alpha_inner = 1.0 - sdf_alpha_pixelated(dist, inner_radius, pixel_size);
        
        color.a *= alpha_outer * alpha_inner;
    }
    else if (in.kind == SHAPE_TRIANGLE) {
        // Equilateral triangle, radius ~0.4 to fit in quad
        float d = sdf_triangle(centered, 0.4);
        // For triangle, distance < 0 means inside
        float alpha = sdf_alpha_pixelated(-d, 0.0, pixel_size);
        color.a *= alpha;
    }
    else if (in.kind == SHAPE_HOLLOW_RECT) {
        // Hollow rectangle: params.x = border thickness (0-1, relative to size)
        float thickness = in.params.x * 0.5;
        float d_outer = sdf_box(centered, float2(0.5));
        float d_inner = sdf_box(centered, float2(0.5 - thickness));
        
        float alpha_outer = sdf_alpha_pixelated(-d_outer, 0.0, pixel_size);
        float alpha_inner = 1.0 - sdf_alpha_pixelated(-d_inner, 0.0, pixel_size);
        
        color.a *= alpha_outer * alpha_inner;
    }
    else if (in.kind == SHAPE_HOLLOW_TRIANGLE) {
        // Hollow triangle: params.x = border thickness (0-1, relative to size)
        float thickness = in.params.x * 0.4;
        float d_outer = sdf_triangle(centered, 0.4);
        float d_inner = sdf_triangle(centered, 0.4 - thickness);
        
        float alpha_outer = sdf_alpha_pixelated(-d_outer, 0.0, pixel_size);
        float alpha_inner = 1.0 - sdf_alpha_pixelated(-d_inner, 0.0, pixel_size);
        
        color.a *= alpha_outer * alpha_inner;
    }
    else if (in.kind == SHAPE_LINE) {
        // Line using SDF for smooth anti-aliased rendering with round caps
        // params.xy = normalized start point
        // params.zw = normalized end point
        // uv_min.x = thickness ratio (half_thickness / min_box_dimension)
        // uv_min.y = aspect ratio (box_width / box_height)
        
        float2 line_start = float2(in.params.x, -in.params.y);  // flip Y to match UV flip
        float2 line_end = float2(in.params.z, -in.params.w);    // flip Y to match UV flip
        float thickness_ratio = in.uv_min.x;
        float aspect = in.uv_min.y;
        
        // Adjust centered coords for aspect ratio to get correct distances
        float2 p = centered;
        p.x *= aspect;  // Scale x to match aspect ratio
        
        float2 a = line_start;
        a.x *= aspect;
        
        float2 b = line_end;
        b.x *= aspect;
        
        // Calculate distance to line segment
        float d = sdf_line_segment(p, a, b);
        
        float alpha = sdf_alpha_pixelated(d, thickness_ratio, pixel_size);
        color.a *= alpha;
    }

    // SHAPE_RECT and SHAPE_TEXTURED_RECT: no SDF masking, just use texture

    // Sample from the bindless texture array using the instance's texture index
    float2 tex_uv = in.tex_uv;
    float4 texColor = textureArray.textures[in.texture_index].sample(textureSampler, tex_uv);
    return texColor * color;
}
