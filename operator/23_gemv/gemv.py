# 23 · 自定义 GEMV 内核：矩阵-向量乘
# GEMV 是 LLM 解码阶段（batch=1）的核心算子：y = W·x。
# 每线程组负责一行：组内跨步分摊 + 共享内存规约（03 的规约 × 04 的 GEMM）。
import mlx.core as mx
from mlx.core.fast import metal_kernel
import numpy as np
import time

print("=== MLX 23 · 自定义 GEMV 内核 ===")

gemv_kernel = metal_kernel(
    name="my_gemv",
    input_names=["w", "x", "k_dim"],
    output_names=["y"],
    source="""
    uint gid = threadgroup_position_in_grid.x;   // 一组一行
    uint lid = thread_position_in_threadgroup.x;
    uint lsize = threads_per_threadgroup.x;
    uint K = k_dim[0];
    device const float* row = w + gid * K;
    float acc = 0;
    for (uint k = lid; k < K; k += lsize) { acc += row[k] * x[k]; }
    threadgroup float scratch[256];
    scratch[lid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = lsize / 2; s > 0; s >>= 1) {
        if (lid < s) { scratch[lid] += scratch[lid + s]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0) { y[gid] = scratch[0]; }
    """,
)

M, K = 512, 1024
rng = np.random.default_rng(3)
W_np = rng.standard_normal((M, K)).astype(np.float32)
x_np = rng.standard_normal(K).astype(np.float32)
W, x = mx.array(W_np), mx.array(x_np)
kdim = mx.array(np.array([K], dtype=np.uint32))

(y,) = gemv_kernel(inputs=[W, x, kdim], output_shapes=[(M,)], output_dtypes=[mx.float32],
                   grid=(M * 256, 1, 1), threadgroup=(256, 1, 1))  # MLX 的 grid 参数 = 总线程数
mx.eval(y)
ref = W_np @ x_np
max_diff = np.abs(np.asarray(y) - ref).max()
print("y[:4] =", np.asarray(y)[:4].round(3), " ref[:4] =", ref[:4].round(3))
print(f"自定义 GEMV vs numpy 最大绝对差: {max_diff:.2e}")

def bench(f, iters=50):
    f(); f()
    t0 = time.perf_counter()
    for _ in range(iters): r = f()
    mx.eval(r)
    return (time.perf_counter() - t0) / iters * 1000
t_mine = bench(lambda: gemv_kernel(inputs=[W, x, kdim], output_shapes=[(M,)], output_dtypes=[mx.float32],
                                   grid=(M * 256, 1, 1), threadgroup=(256, 1, 1))[0])
t_native = bench(lambda: W @ x)
print(f"自定义 GEMV: {t_mine:.3f} ms | MLX 原生 matmul: {t_native:.3f} ms")
assert max_diff < 1e-3, "数值不一致"
print("✅ 验证通过：数值一致，性能同量级（原生内核有 simd 优化，教学版不必追平）")
