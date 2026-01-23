#include <metal_stdlib>
using namespace metal;

// Must match MAX_SHAPE_TEXTURES in shapes.odin
#ifndef MAX_SHAPE_TEXTURES
#define MAX_SHAPE_TEXTURES 128
#endif

struct Shape_Uniforms {
    float4x4 view_projection;
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



// Argument buffer structure for bindless textures
struct TextureArray {
    array<texture2d<float>, MAX_SHAPE_TEXTURES> textures;
};

fragment float4 shape_fragment(
    Shape_Out                 in             [[stage_in]],
    constant TextureArray&    textureArray   [[buffer(3)]],
    sampler                   textureSampler [[sampler(0)]]
) {
    float4 color = in.color;
    float2 centered = in.uv - 0.5;  // center UV at origin, range [-0.5, 0.5]
    float dist = length(centered);
    float aa = fwidth(dist);

    if (in.kind == SHAPE_CIRCLE) {
        float alpha = 1.0 - smoothstep(0.5 - aa, 0.5, dist);
        color.a *= alpha;
    }
    else if (in.kind == SHAPE_DONUT) {
        // Donut: params.x = inner radius ratio (0-1, relative to outer)
        float inner_radius = in.params.x * 0.5;
        float outer_radius = 0.5;
        
        float alpha_outer = 1.0 - smoothstep(outer_radius - aa, outer_radius, dist);
        float alpha_inner = smoothstep(inner_radius - aa, inner_radius, dist);
        
        color.a *= alpha_outer * alpha_inner;
    }
    else if (in.kind == SHAPE_TRIANGLE) {
        // Equilateral triangle, radius ~0.4 to fit in quad
        float d = sdf_triangle(centered, 0.4);
        float alpha = 1.0 - smoothstep(-aa, aa, d);
        color.a *= alpha;
    }
    else if (in.kind == SHAPE_HOLLOW_RECT) {
        // Hollow rectangle: params.x = border thickness (0-1, relative to size)
        float thickness = in.params.x * 0.5;
        float d_outer = sdf_box(centered, float2(0.5));
        float d_inner = sdf_box(centered, float2(0.5 - thickness));
        
        float alpha_outer = 1.0 - smoothstep(-aa, aa, d_outer);
        float alpha_inner = smoothstep(-aa, aa, d_inner);
        
        color.a *= alpha_outer * alpha_inner;
    }
    else if (in.kind == SHAPE_HOLLOW_TRIANGLE) {
        // Hollow triangle: params.x = border thickness (0-1, relative to size)
        float thickness = in.params.x * 0.4;
        float d_outer = sdf_triangle(centered, 0.4);
        float d_inner = sdf_triangle(centered, 0.4 - thickness);
        
        float alpha_outer = 1.0 - smoothstep(-aa, aa, d_outer);
        float alpha_inner = smoothstep(-aa, aa, d_inner);
        
        color.a *= alpha_outer * alpha_inner;
    }

    else if (in.kind == SHAPE_LINE) {
        // Line using SDF for smooth anti-aliased rendering with round caps
        // params.xy = normalized start point
        // params.zw = normalized end point
        // tex_uv.x = thickness ratio (half_thickness / min_box_dimension)
        // tex_uv.y = aspect ratio (box_width / box_height)
        
        float2 line_start = in.params.xy;
        float2 line_end = in.params.zw;
        float thickness_ratio = in.tex_uv.x;
        float aspect = in.tex_uv.y;
        
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
        
        float aa_line = fwidth(d);
        float alpha = 1.0 - smoothstep(radius - aa_line, radius + aa_line, d);
        color.a *= alpha;
    }

    // SHAPE_RECT and SHAPE_TEXTURED_RECT: no SDF masking, just use texture

    // Sample from the bindless texture array using the instance's texture index
    float4 texColor = textureArray.textures[in.texture_index].sample(textureSampler, in.tex_uv);
    return texColor * color;
}
