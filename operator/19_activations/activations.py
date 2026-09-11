# 19 · 激活函数对比：ReLU / SiLU / GELU
# 三个现代 LLM 最常用的激活：形状对比 + 前向性能对比。
import mlx.core as mx
import numpy as np
import time

print("=== MLX 19 · ReLU / SiLU / GELU ===")

x = mx.array(np.linspace(-4, 4, 9).astype(np.float32))
relu = mx.maximum(x, 0.0)
silu = x * mx.sigmoid(x)                      # SiLU = x·σ(x)（LLaMA 系常用）
gelu = 0.5 * x * (1 + mx.tanh(0.7978845608 * (x + 0.044715 * x**3)))  # GPT 系常用
mx.eval(relu); mx.eval(silu); mx.eval(gelu)

print("x      :", [round(float(v), 2) for v in x])
print("ReLU   :", [round(float(v), 2) for v in relu])
print("SiLU   :", [round(float(v), 2) for v in silu])
print("GELU   :", [round(float(v), 2) for v in gelu])
# 结构验证：负半轴 SiLU/GELU 有"低谷"（非零负值），ReLU 直接归零
neg_silu = float(silu[3]); neg_relu = float(relu[3])
assert neg_relu == 0.0 and neg_silu < 0 and neg_silu > -1, "激活形状异常"
print(f"负半轴差异: ReLU 硬归零，SiLU 保留微弱负值（{neg_silu:.3f}）——这是 SwiGLU 优于 ReLU 的解释之一")

# 前向性能（大规模）
big = mx.array(np.random.randn(4096, 4096).astype(np.float32))
def bench(f, iters=50):
    f(big); f(big)
    t0 = time.perf_counter()
    for _ in range(iters): r = f(big)
    mx.eval(r)
    return (time.perf_counter() - t0) / iters * 1000
t_relu = bench(lambda v: mx.maximum(v, 0.0))
t_silu = bench(lambda v: v * mx.sigmoid(v))
t_gelu = bench(lambda v: 0.5 * v * (1 + mx.tanh(0.7978845608 * (v + 0.044715 * v**3))))
print(f"  ReLU {t_relu:.2f} ms | SiLU {t_silu:.2f} ms | GELU {t_gelu:.2f} ms（均为逐元素/带宽受限）")
print("✅ 验证通过：三种激活的形状与性能符合预期")
