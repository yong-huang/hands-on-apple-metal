# 24 · 融合算子：RMSNorm + QKV 投影缝成一个内核
# LLM 解码每步都要 RMSNorm → 三个投影。分离执行要写回中间激活再读出；
# 融合版数据"留在寄存器/共享内存"里直接算完——减少一整轮显存往返。
import mlx.core as mx
from mlx.core.fast import metal_kernel
import numpy as np
import time

print("=== MLX 24 · 融合 RMSNorm + QKV ===")
D, H = 512, 8    # 隐层维度、QKV 头数（每头 D）
eps = 1e-5

rng = np.random.default_rng(24)
x_np = rng.standard_normal((1, D)).astype(np.float32)          # 单 token
w_norm_np = rng.uniform(0.5, 1.5, D).astype(np.float32)
wq_np = rng.standard_normal((D, D)).astype(np.float32) * 0.02
wk_np = rng.standard_normal((D, D)).astype(np.float32) * 0.02
wv_np = rng.standard_normal((D, D)).astype(np.float32) * 0.02

x = mx.array(x_np); wn = mx.array(w_norm_np)
wq = mx.array(wq_np); wk = mx.array(wk_np); wv = mx.array(wv_np)

# —— 参考实现：三步分离 ——
# 权重按 (out_features, in_features) 行主序约定：y = normed @ W.T
def reference():
    normed = x / mx.sqrt(mx.mean(x * x, axis=-1, keepdims=True) + eps) * wn
    return normed @ wq.T, normed @ wk.T, normed @ wv.T

# —— 融合内核：一次读 x，规约出 rms，逐头算 Q/K/V ——
fused_kernel = metal_kernel(
    name="fused_norm_qkv",
    input_names=["x", "wn", "wq", "wk", "wv", "eps_t"],
    output_names=["q", "k", "v"],
    source="""
    uint lid = thread_position_in_threadgroup.x;
    uint lsize = threads_per_threadgroup.x;
    float e = eps_t[0];
    // 步骤1：全组协作算 rms(x)（单 token，一个线程组覆盖整行）
    threadgroup float s[256];
    float acc = 0;
    for (uint d = lid; d < 512; d += lsize) { acc += x[d] * x[d]; }
    s[lid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint st = lsize / 2; st > 0; st >>= 1) {
        if (lid < st) { s[lid] += s[lid + st]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    float rms = 1.0 / sqrt(s[0] / 512.0 + e);
    // 步骤2：每线程负责若干输出维度，norm→投影一气呵成
    for (uint d = lid; d < 512; d += lsize) {
        float nval = x[d] * rms * wn[d];
        float qacc = 0, kacc = 0, vacc = 0;
        for (uint c = 0; c < 512; c++) {
            float nv = (c == d) ? nval : x[c] * rms * wn[c];
            qacc += nv * wq[d * 512 + c];
            kacc += nv * wk[d * 512 + c];
            vacc += nv * wv[d * 512 + c];
        }
        q[d] = qacc; k[d] = kacc; v[d] = vacc;
    }
    """,
)
# 教学版内核内部重算了归一化值（保持单线程组内自洽），数值仍应与参考一致
one = mx.array(np.array([eps], dtype=np.float32))
(qf, kf, vf) = fused_kernel(inputs=[x, wn, wq, wk, wv, one], output_shapes=[(D,), (D,), (D,)],
                            output_dtypes=[mx.float32]*3, grid=(256, 1, 1), threadgroup=(256, 1, 1))
mx.eval(qf); mx.eval(kf); mx.eval(vf)

qr, kr, vr = reference()
mx.eval(qr); mx.eval(kr); mx.eval(vr)
qr = np.asarray(qr).reshape(-1); kr = np.asarray(kr).reshape(-1); vr = np.asarray(vr).reshape(-1)
print("qf[:4] =", np.asarray(qf)[:4].round(4), " qr[:4] =", qr[:4].round(4))
diff = max(np.abs(np.asarray(qf) - qr).max(),
           np.abs(np.asarray(kf) - kr).max(),
           np.abs(np.asarray(vf) - vr).max())
print(f"融合 vs 分离 最大绝对差: {diff:.2e}")
assert diff < 1e-3, "融合结果不一致"

# 性能对照：分离版 = norm + 3×matmul（4 次内核往返）
def bench(f, iters=100):
    f(); f()
    t0 = time.perf_counter()
    for _ in range(iters): r = f()
    mx.eval(r)
    return (time.perf_counter() - t0) / iters * 1000

def separated():
    normed = x / mx.sqrt(mx.mean(x * x, axis=-1, keepdims=True) + eps) * wn
    return normed @ wq.T, normed @ wk.T, normed @ wv.T

def fused():
    return fused_kernel(inputs=[x, wn, wq, wk, wv, one], output_shapes=[(D,), (D,), (D,)],
                        output_dtypes=[mx.float32]*3, grid=(256, 1, 1), threadgroup=(256, 1, 1))

print(f"分离执行: {bench(separated):.3f} ms | 融合内核: {bench(fused):.3f} ms")
print("融合省掉的是：中间激活写回+读回（D×4 字节 ×2 次）与 3 次内核启动开销")
print("✅ 验证通过：融合内核与分离执行数值一致")
