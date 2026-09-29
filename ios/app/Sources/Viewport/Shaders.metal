// Shaders of the 3D viewport: model mesh, bed, and toolpath preview.
// Coordinates are millimetres on the bed, Z up (same as the G-code).
#include <metal_stdlib>
using namespace metal;

// Must match `Uniforms` in Renderer.swift (only float4 / float4x4: no padding surprises).
struct Uniforms {
    float4x4 viewProj;
    float4   eye;       // camera position
    float4   color;     // mesh / flat colour
    float4   lightDir;  // towards the light
    float4   params;    // x: top z of the last visible layer, y: dim lower layers (0/1)
};

struct LitVertex {
    float4 position [[position]];
    float3 normal;
    float3 world;
    float3 color;
};

static float4 shade(LitVertex in, constant Uniforms& u)
{
    float3 n = normalize(in.normal);
    float3 v = normalize(u.eye.xyz - in.world);
    if (dot(n, v) < 0.0)
        n = -n;                                   // two-sided: STLs are not always well oriented
    float3 l = normalize(u.lightDir.xyz);
    float diffuse = max(dot(n, l), 0.0);
    float specular = pow(max(dot(n, normalize(l + v)), 0.0), 40.0) * 0.18;
    float3 c = in.color * (0.38 + 0.62 * diffuse) + specular;
    return float4(c, 1.0);
}

// ---- Model mesh: 6 floats per vertex, non-indexed triangles -----------------

struct MeshVertex {
    packed_float3 position;
    packed_float3 normal;
};

vertex LitVertex mesh_vertex(uint vid [[vertex_id]],
                             const device MeshVertex* vertices [[buffer(0)]],
                             constant Uniforms& u [[buffer(1)]])
{
    float3 p = float3(vertices[vid].position);
    LitVertex out;
    out.position = u.viewProj * float4(p, 1.0);
    out.normal = float3(vertices[vid].normal);
    out.world = p;
    out.color = u.color.rgb;
    return out;
}

fragment float4 lit_fragment(LitVertex in [[stage_in]], constant Uniforms& u [[buffer(1)]])
{
    return shade(in, u);
}

// ---- Bed: plain positions, one colour ------------------------------------------

struct FlatVertex {
    float4 position [[position]];
};

vertex FlatVertex flat_vertex(uint vid [[vertex_id]],
                              const device packed_float3* positions [[buffer(0)]],
                              constant Uniforms& u [[buffer(1)]])
{
    FlatVertex out;
    out.position = u.viewProj * float4(float3(positions[vid]), 1.0);
    return out;
}

fragment float4 flat_fragment(FlatVertex in [[stage_in]], constant Uniforms& u [[buffer(1)]])
{
    return u.color;
}

// ---- Toolpaths: one instance per extrusion segment, drawn as a box ------------

struct Segment {                // 9 floats, see SlicerCore::Toolpaths
    packed_float3 a;
    packed_float3 b;
    float width;
    float height;
    float role;
};

// BambuStudio's preview colours (GCodeRenderer/BaseRenderer.cpp), by ExtrusionRole.
constant float3 kRoleColors[22] = {
    float3(0.90, 0.70, 0.70),   // None
    float3(1.00, 0.90, 0.30),   // Inner wall
    float3(1.00, 0.49, 0.22),   // Outer wall
    float3(0.12, 0.12, 1.00),   // Overhang wall
    float3(0.69, 0.19, 0.16),   // Sparse infill
    float3(0.59, 0.33, 0.80),   // Internal solid infill
    float3(0.90, 0.70, 0.70),   // Floating vertical shell
    float3(0.94, 0.25, 0.25),   // Top surface
    float3(0.40, 0.36, 0.78),   // Bottom surface
    float3(1.00, 0.55, 0.41),   // Ironing
    float3(0.30, 0.50, 0.73),   // Bridge
    float3(1.00, 1.00, 1.00),   // Gap infill
    float3(0.00, 0.53, 0.43),   // Skirt
    float3(0.00, 0.23, 0.43),   // Brim
    float3(0.00, 1.00, 0.00),   // Support
    float3(0.00, 0.50, 0.00),   // Support interface
    float3(0.00, 0.25, 0.00),   // Support transition
    float3(0.60, 1.00, 0.60),   // Support ironing
    float3(0.70, 0.89, 0.67),   // Prime tower
    float3(0.37, 0.82, 0.58),   // Custom
    float3(0.85, 0.65, 0.95),   // Flush
    float3(0.60, 0.60, 0.60),   // Mixed
};

// Box corners: bit0 = end (0 start, 1 end), bit1 = side (0 left, 1 right), bit2 = top.
// 6 faces x 2 triangles: top, bottom, right, left, start cap, end cap.
constant uchar kBoxCorners[36] = {
    4, 5, 7,  4, 7, 6,
    0, 2, 3,  0, 3, 1,
    2, 6, 7,  2, 7, 3,
    0, 1, 5,  0, 5, 4,
    0, 4, 6,  0, 6, 2,
    1, 3, 7,  1, 7, 5,
};

vertex LitVertex toolpath_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 const device Segment* segments [[buffer(0)]],
                                 constant Uniforms& u [[buffer(1)]])
{
    Segment s = segments[iid];
    float3 a = float3(s.a);
    float3 b = float3(s.b);

    float2 d = b.xy - a.xy;
    float len = length(d);
    float2 dir = len > 1e-5 ? d / len : float2(1.0, 0.0);
    float3 fwd = float3(dir, 0.0);
    float3 side = float3(-dir.y, dir.x, 0.0);

    // Stretch both ends a little so consecutive segments close the corners.
    float ext = s.width * 0.35;
    uint corner = kBoxCorners[vid];
    float3 p = (corner & 1u) ? b + fwd * ext : a - fwd * ext;
    p += side * (((corner & 2u) ? 0.5 : -0.5) * s.width);
    if ((corner & 4u) == 0u)
        p.z -= s.height;

    uint face = vid / 6u;
    float3 n = face == 0u ? float3(0, 0, 1)
             : face == 1u ? float3(0, 0, -1)
             : face == 2u ? side
             : face == 3u ? -side
             : face == 4u ? -fwd
             : fwd;

    uint role = min(uint(s.role), 21u);
    float3 color = kRoleColors[role];
    // Optionally dim everything below the current (last visible) layer.
    if (u.params.y > 0.5 && max(a.z, b.z) < u.params.x - 1e-3)
        color *= 0.45;

    LitVertex out;
    out.position = u.viewProj * float4(p, 1.0);
    out.normal = n;
    out.world = p;
    out.color = color;
    return out;
}
