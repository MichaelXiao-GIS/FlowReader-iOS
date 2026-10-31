#include <metal_stdlib>
using namespace metal;

struct CurlUniforms {
    float4 viewportAndPage;
    float4 anchorAndFinger;
    float4 placement;
    float4 paper;
    float4 options;
};
struct CurlVertex {
    float4 position [[position]];
    float2 uv;
    float angle;
    float lift;
};

static CurlVertex curlVertex(uint id, device const float2 *grid, constant CurlUniforms &u, bool shadow) {
    float2 pageSize = u.viewportAndPage.zw;
    float2 p = grid[id] * pageSize;
    float2 a = u.anchorAndFinger.xy;
    float2 f = u.anchorAndFinger.zw;
    float distance = length(a - f);
    float2 q = p;
    float angle = 0.0, lift = 0.0;
    if (distance > 0.001) {
        float2 n = (a - f) / distance;
        float activation = min(1.0, distance / 12.0);
        float flexibility = 0.78 + 0.44 * min(1.0, abs(p.y - a.y) / max(1.0, pageSize.y));
        float r = u.placement.z * flexibility;
        float2 fold = (a + f) * 0.5 - n * (M_PI_F * r * 0.5);
        float d = dot(p - fold, n);
        if (d > 0.0) {
            float along;
            if (r < 0.01) {
                angle = M_PI_F; along = -d;
            } else if (d < M_PI_F * r) {
                angle = d / r; along = r * sin(angle); lift = r * (1.0 - cos(angle));
            } else {
                angle = M_PI_F; along = -(d - M_PI_F * r); lift = 2.0 * r;
            }
            q += n * (along - d) * activation;
            lift *= activation;
            angle *= activation;
        }
    }
    float direction = u.placement.y;
    float2 screen = float2(u.placement.x + (direction > 0.0 ? q.x : pageSize.x - q.x), q.y);
    if (shadow) { screen += float2(-direction * lift * 0.16, lift * 0.13); }
    float depth = shadow ? 0.98 : 0.45 - lift / max(1.0, pageSize.x * 4.0);
    CurlVertex out;
    out.position = float4(screen.x / u.viewportAndPage.x * 2.0 - 1.0,
                          1.0 - screen.y / u.viewportAndPage.y * 2.0, depth, 1.0);
    out.uv = float2(direction > 0.0 ? grid[id].x : 1.0 - grid[id].x, grid[id].y);
    out.angle = angle;
    out.lift = lift / max(1.0, u.placement.z * 2.0);
    return out;
}

vertex CurlVertex readerCurlVertex(uint id [[vertex_id]], device const float2 *grid [[buffer(0)]],
                                   constant CurlUniforms &u [[buffer(1)]]) {
    return curlVertex(id, grid, u, false);
}
vertex CurlVertex readerCurlShadowVertex(uint id [[vertex_id]], device const float2 *grid [[buffer(0)]],
                                         constant CurlUniforms &u [[buffer(1)]]) {
    return curlVertex(id, grid, u, true);
}
fragment float4 readerCurlFragment(CurlVertex in [[stage_in]], texture2d<float> front [[texture(0)]],
                                   texture2d<float> back [[texture(1)]], constant CurlUniforms &u [[buffer(1)]]) {
    constexpr sampler paperSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float facing = cos(in.angle);
    float shade = 0.80 + 0.20 * abs(facing);
    if (facing >= 0.0) {
        float4 color = front.sample(paperSampler, in.uv);
        return float4(color.rgb * shade, 1.0);
    }
    float3 reverse = u.paper.rgb;
    if (u.options.x > 0.5) {
        reverse = back.sample(paperSampler, float2(1.0 - in.uv.x, in.uv.y)).rgb;
    } else {
        reverse = mix(u.paper.rgb, front.sample(paperSampler, in.uv).rgb, 0.035);
    }
    return float4(reverse * (0.91 + 0.09 * abs(facing)), 1.0);
}
fragment float4 readerCurlShadowFragment(CurlVertex in [[stage_in]]) {
    float edgeDistance = min(min(in.uv.x, 1.0 - in.uv.x), min(in.uv.y, 1.0 - in.uv.y));
    // Only the curved contact band casts this local soft shadow. Projecting the
    // already-flat reverse face creates detached triangular wedges at the spine.
    float contact = sin(in.angle);
    float alpha = contact * contact * clamp(in.lift, 0.0, 1.0) * 0.12 * smoothstep(0.0, 0.025, edgeDistance);
    return float4(0.0, 0.0, 0.0, alpha);
}
