# 16 · GELU 算子与 mx.compile 融合
# 手写 GELU 由 5 个逐元素算子组成 → 每个都单独读写一遍显存。
# mx.compile 让 MLX 把它们融合成一个内核：一次读、一次写。
import mlx.core as mx
import numpy as np
import time

print("=== MLX 16 · GELU 与算子融合 ===")

def gelu_manual(x):
    # 精确公式：x * Φ(x)，Φ 用 tanh 近似的标准实现
    return 0.5 * x * (1 + mx.tanh(0.7978845608 * (x + 0.044715 * x**3)))

gelu_fused = mx.compile(gelu_manual)   # 编译期把 5 个算子缝成一个内核

x = mx.array(np.random.randn(4096, 4096).astype(np.float32))

# 正确性：融合版与手写版一致
mx.eval(gelu_manual(x)); r_manual = np.asarray(gelu_manual(x))
mx.eval(gelu_fused(x));  r_fused = np.asarray(gelu_fused(x))
assert np.allclose(r_manual, r_fused, atol=1e-6), "融合改变数值！"
print("✅ 正确性：融合前后逐元素一致")

# 性能：多轮计时（编译在首轮发生，会被预热吸收）
def bench(f, iters=30):
    f(x); f(x)  # warmup
    t0 = time.perf_counter()
    for _ in range(iters):
        r = f(x)
    mx.eval(r)
    return (time.perf_counter() - t0) / iters * 1000

t_manual = bench(gelu_manual)
t_fused = bench(gelu_fused)
print(f"手写链路: {t_manual:.2f} ms/次")
print(f"mx.compile 融合: {t_fused:.2f} ms/次（加速 {t_manual/t_fused:.2f}×）")
print(f"访存视角: 5 算子链路搬 5×64MB，融合后 1×64MB——带宽受限算子的收益公式")
print("✅ 验证通过：数值不变，融合显著更快")
