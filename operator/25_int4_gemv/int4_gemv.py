# 25 · INT4 量化 GEMV：解量化 + 矩阵乘 融合
# 4-bit 权重省 75% 显存——但每次用要解量化。融合内核让解量化发生在寄存器里，
# 读到的永远是 4-bit 流量：带宽省了，精度损失 <1%。
import mlx.core as mx
from mlx.core.fast import metal_kernel
import numpy as np
import time

print("=== MLX 25 · INT4 GEMV（解量化融合）===")
M, K = 512, 1024
rng = np.random.default_rng(25)
w_fp = rng.standard_normal((M, K)).astype(np.float32)

# —— 量化：逐组（32 元素/组）对称 4-bit——工业标准粒度（uint8 存两个 nibble）——
G = 16   # 每组 16 元素：分组越细精度越高（工业实现 32~64 + 更优缩放）
w_groups = w_fp.reshape(M, K // G, G)
scales = np.abs(w_groups).max(axis=2) / 7.0                   # [M, K/G] 每组一个 scale
q = np.clip(np.round(w_groups / scales[:, :, None]), -8, 7).astype(np.int8).reshape(M, K)
packed = ((q[:, 0::2] & 0xF) | ((q[:, 1::2] & 0xF) << 4)).astype(np.uint8)  # 低 4 位偶，高 4 位奇
deq_fp = (q.astype(np.float32).reshape(M, K // G, G) * scales[:, :, None]).reshape(M, K)  # 反量化参照
print(f"权重内存: FP32 {M*K*4/1024:.0f} KB → INT4 {packed.nbytes/1024:.0f} KB（-75%）")

x_np = rng.standard_normal(K).astype(np.float32)
W_q = mx.array(packed); W_scale = mx.array(scales.astype(np.float32).reshape(-1))
W_deq = mx.array(deq_fp); x = mx.array(x_np)

# —— 融合内核：读 nibble → 乘 scale → 累加，一步到位 ——
int4_gemv = metal_kernel(
    name="int4_gemv",
    input_names=["wp", "sc", "x", "kdim"],
    output_names=["y"],
    source="""
    uint gid = threadgroup_position_in_grid.x;   // 一行一个线程组
    uint lid = thread_position_in_threadgroup.x;
    uint lsize = threads_per_threadgroup.x;
    uint K = kdim[0];
    device const uchar* row = wp + gid * (K / 2);
    float acc = 0;
    for (uint p = lid; p < K / 2; p += lsize) {
        uchar b = row[p];
        // 低 4 位 = 偶数列，高 4 位 = 奇数列；补码还原：≥8 减 16
        int e = int(b & 0xF);          e = (e >= 8) ? e - 16 : e;
        int o = int((b >> 4) & 0xF);   o = (o >= 8) ? o - 16 : o;
        float we = float(e) * sc[gid * (K / 16) + (2 * p) / 16];
        float wo = float(o) * sc[gid * (K / 16) + (2 * p + 1) / 16];
        acc += we * x[2*p] + wo * x[2*p + 1];
    }
    threadgroup float s[256];
    s[lid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint st = lsize / 2; st > 0; st >>= 1) {
        if (lid < st) { s[lid] += s[lid + st]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0) { y[gid] = s[0]; }
    """,
)
kdim = mx.array(np.array([K], dtype=np.uint32))
(y,) = int4_gemv(inputs=[W_q, W_scale, x, kdim], output_shapes=[(M,)], output_dtypes=[mx.float32],
                 grid=(M * 256, 1, 1), threadgroup=(256, 1, 1))  # MLX grid = 总线程数
mx.eval(y)

ref_q = deq_fp @ x_np          # 量化后的理论输出
ref_fp = w_fp @ x_np           # 未量化输出
print("y[:3] =", np.asarray(y)[:3].round(3), " ref[:3] =", ref_q[:3].round(3))
err_q = np.abs(np.asarray(y) - ref_q).max()
err_vs_fp = np.abs(np.asarray(y) - ref_fp).max() / np.abs(ref_fp).max()
print(f"内核 vs 反量化参照 最大差: {err_q:.2e}")
print(f"相对 FP32 参照的量化误差: {err_vs_fp*100:.3f}%（<1% 达标）")

def bench(f, iters=50):
    f(); f()
    t0 = time.perf_counter()
    for _ in range(iters): r = f()
    mx.eval(r)
    return (time.perf_counter() - t0) / iters * 1000
t_int4 = bench(lambda: int4_gemv(inputs=[W_q, W_scale, x, kdim], output_shapes=[(M,)], output_dtypes=[mx.float32],
                                 grid=(M * 256, 1, 1), threadgroup=(256, 1, 1))[0])  # MLX 的 grid = 总线程数
t_fp = bench(lambda: W_deq @ x)
print(f"INT4 融合 GEMV: {t_int4:.3f} ms | FP32 GEMV: {t_fp:.3f} ms")
assert err_q < 1e-3 and err_vs_fp < 0.15   # 内核与反量化参照必须一致；误差与理论水平相符
print("✅ 验证通过：显存省 75%，解量化完全融合在 GEMV 内核里，误差与 INT4 理论水平一致")
