#include <metal_stdlib>
using namespace metal;

// Must match MAX_SHAPE_TEXTURES in shapes.odin
#ifndef MAX_SHAPE_TEXTURES
#define MAX_SHAPE_TEXTURES 128
#endif

struct Shape_Uniforms {
    float4x4 view_projection;
    float4x4 inv_view_projection;  // For reconstructing world position from clip space
    float2   screen_size;          // Screen dimensions in pixels
    float    pixel_size;           // World units per pixel art "pixel" (0 = smooth/no pixelation)
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
    float2 uv;              // normalized UV [0,1] for SDF calculations
    float2 tex_uv;          // remapped UV for texture sampling
    float2 uv_min;          // raw uv_min for shapes that need it (e.g., line)
    float2 world_pos;       // world position for pixel snapping
    float2 shape_center;    // shape center in world space
    float2 shape_scale;     // shape scale for SDF calculations

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
    
    // Pass world position for pixel snapping in fragment shader
    out.world_pos = world_pos;
    out.shape_center = inst.position;
    out.shape_scale = inst.scale;
        
    // Keep normalized UV for SDF calculations
    out.uv = vert.uv;
    out.uv.y = 1.0 - out.uv.y;
    
    // Remap UV based on instance uv_min/uv_max for texture sampling
    // lerp from uv_min to uv_max based on vertex uv
    out.tex_uv = mix(inst.uv_min, inst.uv_max, vert.uv);
    out.tex_uv.y = 1.0 - out.tex_uv.y;  // flip Y for texture coordinates
    
    out.uv_min        = inst.uv_min;

    out.color           = float4(inst.color) / 255.0;
    out.kind            = inst.kind;
    out.params          = inst.params;
    out.texture_index   = inst.texture_index;

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

// Snap world position to pixel grid and return snapped UV relative to shape
// pixel_size: world units per "pixel" (e.g., 4.0 means 4x4 world unit pixels)
// world_pos: current fragment world position
// shape_center: center of the shape in world space
// shape_scale: size of the shape in world space
// Returns: UV in [0,1] range relative to shape, snapped to pixel grid
float2 snap_to_pixel_grid(float2 world_pos, float2 shape_center, float2 shape_scale, float pixel_size) {
    // Snap world position to pixel grid (floor to cell center)
    float2 snapped = floor(world_pos / pixel_size + 0.5) * pixel_size;
    
    // Convert snapped world position back to UV relative to shape
    // UV = (world_pos - shape_corner) / shape_scale
    // where shape_corner = shape_center - shape_scale * 0.5
    float2 shape_corner = shape_center - shape_scale * 0.5;
    float2 snapped_uv = (snapped - shape_corner) / shape_scale;
    
    return snapped_uv;
}

// Argument buffer structure for bindless textures
struct TextureArray {
    array<texture2d<float>, MAX_SHAPE_TEXTURES> textures;
};

fragment float4 shape_fragment(
    Shape_Out                 in             [[stage_in]],
    constant Shape_Uniforms&  uniforms       [[buffer(2)]],
    constant TextureArray&    textureArray   [[buffer(3)]],
    sampler                   textureSampler [[sampler(0)]]
) {
    float4 color = in.color;
    float pixel_size = uniforms.pixel_size;
    
    // Determine UV for SDF calculations
    // If pixel_size > 0, snap to pixel grid; otherwise use smooth interpolated UV
    float2 uv;
    if (pixel_size > 0.0) {
        uv = snap_to_pixel_grid(in.world_pos, in.shape_center, in.shape_scale, pixel_size);
        uv.y = 1.0 - uv.y;  // flip Y to match the UV flip in vertex shader
    } else {
        uv = in.uv;
    }
    
    float2 centered = uv - 0.5;  // center UV at origin, range [-0.5, 0.5]
    float dist = length(centered);
    
    // Use hard edges for pixel art mode, smooth AA otherwise
    bool pixel_mode = pixel_size > 0.0;

    if (in.kind == SHAPE_CIRCLE) {
        if (pixel_mode) {
            color.a *= (dist < 0.5) ? 1.0 : 0.0;
        } else {
            float aa = fwidth(dist);
            float alpha = 1.0 - smoothstep(0.5 - aa, 0.5 + aa, dist);
            color.a *= alpha;
        }
    }
    else if (in.kind == SHAPE_DONUT) {
        // Donut: params.x = inner radius ratio (0-1, relative to outer)
        float inner_radius = in.params.x * 0.5;
        float outer_radius = 0.5;
        
        if (pixel_mode) {
            color.a *= (dist < outer_radius && dist >= inner_radius) ? 1.0 : 0.0;
        } else {
            float aa = fwidth(dist);
            float alpha_outer = 1.0 - smoothstep(outer_radius - aa, outer_radius, dist);
            float alpha_inner = smoothstep(inner_radius - aa, inner_radius, dist);
            color.a *= alpha_outer * alpha_inner;
        }
    }
    else if (in.kind == SHAPE_TRIANGLE) {
        // Equilateral triangle, radius ~0.4 to fit in quad
        float d = sdf_triangle(centered, 0.4);
        if (pixel_mode) {
            color.a *= (d < 0.0) ? 1.0 : 0.0;
        } else {
            float aa = fwidth(d);
            float alpha = 1.0 - smoothstep(-aa, aa, d);
            color.a *= alpha;
        }
    }
    else if (in.kind == SHAPE_HOLLOW_RECT) {
        // Hollow rectangle: params.x = border thickness (0-1, relative to size)
        float thickness = in.params.x * 0.5;
        float d_outer = sdf_box(centered, float2(0.5));
        float d_inner = sdf_box(centered, float2(0.5 - thickness));

        if (pixel_mode) {
            color.a *= (d_outer < 0.0 && d_inner >= 0.0) ? 1.0 : 0.0;
        } else {
            float aa = fwidth(d_outer);
            float alpha_outer = 1.0 - smoothstep(-aa, aa, d_outer);
            float alpha_inner = smoothstep(-aa, aa, d_inner);
            color.a *= alpha_outer * alpha_inner;
        }
    }
    else if (in.kind == SHAPE_HOLLOW_TRIANGLE) {
        // Hollow triangle: params.x = border thickness (0-1, relative to size)
        float thickness = in.params.x * 0.4;
        float d_outer = sdf_triangle(centered, 0.4);
        float d_inner = sdf_triangle(centered, 0.4 - thickness);

        if (pixel_mode) {
            color.a *= (d_outer < 0.0 && d_inner >= 0.0) ? 1.0 : 0.0;
        } else {
            float aa = fwidth(d_outer);
            float alpha_outer = 1.0 - smoothstep(-aa, aa, d_outer);
            float alpha_inner = smoothstep(-aa, aa, d_inner);
            color.a *= alpha_outer * alpha_inner;
        }
    }
    else if (in.kind == SHAPE_LINE) {
        // Line using SDF for rendering with round caps
        // params.xy = normalized start point
        // params.zw = normalized end point
        // uv_min.x = thickness ratio (half_thickness / box_height)
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
        
        // thickness_ratio is in the normalized space, adjust for aspect
        float radius = thickness_ratio;
        
        if (pixel_mode) {
            color.a *= (d < radius) ? 1.0 : 0.0;
        } else {
            float aa_line = fwidth(d);
            float alpha = 1.0 - smoothstep(radius - aa_line, radius + aa_line, d);
            color.a *= alpha;
        }
    }

    // SHAPE_RECT and SHAPE_TEXTURED_RECT: no SDF masking, just use texture

    // Sample from the bindless texture array using the instance's texture index
    float2 tex_uv = in.tex_uv;
    texture2d<float> tex = textureArray.textures[in.texture_index];
    float2 klem_uv = uv_klems(tex_uv, int2(tex.get_width(), tex.get_height()));
    float4 texColor = tex.sample(textureSampler, klem_uv);
    return texColor * color;
}
