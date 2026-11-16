#include <metal_stdlib>
using namespace metal;

struct RFBUniforms {
    float2 uvOrigin;
    float2 uvSize;
    float2 textureSize;
    uint pixelFormat;
    uint _padding;
    float4 tintColor;
};

struct RFBVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Pixel format constants matching FrameBufferMetalPixelFormat
#define kPixelFormatBGRX8888 1u
#define kPixelFormatRGBX8888 2u
#define kPixelFormatXBGR8888 3u
#define kPixelFormatRGB444   4u
#define kPixelFormatRGB222   5u
#define kPixelFormatGray8    6u

vertex RFBVertexOut rfbVertexShader(uint vertexID [[vertex_id]],
                                    constant RFBUniforms &uniforms [[buffer(0)]])
{
    // Triangle strip covering NDC [-1, 1] x [-1, 1]
    // 0: bottom-left, 1: bottom-right, 2: top-left, 3: top-right
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    const float2 uvOffsets[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    RFBVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = uniforms.uvOrigin + uvOffsets[vertexID] * uniforms.uvSize;
    return out;
}

static inline float4 applyTint(float3 rgb, float4 tintColor)
{
    float3 blended = mix(rgb, tintColor.rgb, tintColor.a);
    return float4(blended, 1.0);
}

fragment float4 rfbFragmentFloat(RFBVertexOut in [[stage_in]],
                                 constant RFBUniforms &uniforms [[buffer(0)]],
                                 texture2d<float> tex [[texture(0)]])
{
    constexpr sampler linearSampler(coord::normalized,
                                     address::clamp_to_edge,
                                     filter::linear);
    float4 sample = tex.sample(linearSampler, in.texCoord);

    float3 rgb;
    if (uniforms.pixelFormat == kPixelFormatXBGR8888) {
        rgb = sample.abg;
    } else if (uniforms.pixelFormat == kPixelFormatGray8) {
        rgb = sample.rrr;
    } else {
        // BGRX8888 (via BGRA8Unorm) and RGBX8888 (via RGBA8Unorm) both map to .rgb
        rgb = sample.rgb;
    }

    return applyTint(rgb, uniforms.tintColor);
}

fragment float4 rfbFragmentUint(RFBVertexOut in [[stage_in]],
                                constant RFBUniforms &uniforms [[buffer(0)]],
                                texture2d<uint> tex [[texture(0)]])
{
    float2 clampedUV = clamp(in.texCoord, float2(0.0), float2(0.999999));
    uint2 coord = uint2(clampedUV * uniforms.textureSize);
    uint val = tex.read(coord).r;

    float3 rgb;
    if (uniforms.pixelFormat == kPixelFormatRGB444) {
        // HighColorFrameBuffer little-endian: rshift=4, gshift=0, bshift=12
        float r = float((val >> 4) & 0xFu) / 15.0;
        float g = float(val & 0xFu) / 15.0;
        float b = float((val >> 12) & 0xFu) / 15.0;
        rgb = float3(r, g, b);
    } else {
        // LowColorFrameBuffer: rshift=6, gshift=4, bshift=2
        float r = float((val >> 6) & 0x3u) / 3.0;
        float g = float((val >> 4) & 0x3u) / 3.0;
        float b = float((val >> 2) & 0x3u) / 3.0;
        rgb = float3(r, g, b);
    }

    return applyTint(rgb, uniforms.tintColor);
}
