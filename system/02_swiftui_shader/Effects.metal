// 02 · SwiftUI Shader 特效：三个自写 shader 供 SwiftUI 直接调用
// SwiftUI 的 shader 函数必须 include 这个桥接头
#include <SwiftUI/SwiftUI_Metal.h>   // 提供 SwiftUI::Layer（layerEffect 的回采句柄）
#include <metal_stdlib>
using namespace metal;

// ① colorEffect：逐像素调色——RGB 转"双色调"（暗部青、亮部橙）
//    amount 0 = 原图，1 = 完全双色调
half4 duotone(half4 color, float amount, float time) {
    float l = dot(color.rgb, half3(0.299, 0.587, 0.114));
    half3 cool = half3(0.10, 0.35, 0.65);
    half3 warm = half3(1.00, 0.60, 0.25);
    half3 toned = mix(cool, warm, half(clamp(l, 0.0, 1.0)));
    return half4(mix(color.rgb, toned, half(amount)), color.a);
}

// ② distortionEffect：水波涟漪——按正弦波扭曲采样位置
//    amount = 波幅（像素），time 驱动波动
float2 ripple(float2 position, float amount, float time) {
    float wave = sin(position.y * 0.05 + time * 3.0) * amount;
    position.x += wave;
    return position;
}

// ③ layerEffect：扫描错位（故障艺术）——每隔 N 像素横向错开
//    position 由 SwiftUI 自动传入；回采 layer 的错位位置
//    amount = 错位幅度，time 驱动错位窗口滚动
half4 glitch(half4 color, SwiftUI::Layer layer, float2 position,
             float amount, float time) {
    float band = floor((position.y + time * 120.0) / 48.0);
    float shift = amount * step(0.5, fract(band * 0.5 + floor(time) * 0.5));
    return layer.sample(position + float2(shift, 0));
}

// 自检包装：把 duotone 以缓冲 IO 形式暴露给 CPU 驱动（验证编译产物真实可用）
kernel void duotone_selfcheck(device const float4* in   [[buffer(0)]],
                              device float4*        out  [[buffer(1)]],
                              constant float&       amt  [[buffer(2)]],
                              uint i [[thread_position_in_grid]]) {
    out[i] = float4(duotone(half4(in[i]), amt, 0.0));
}
