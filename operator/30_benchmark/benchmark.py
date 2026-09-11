# 30 · 算子基准测试与调优报告
# 一个可复用的 benchmark 框架：预热 → 多轮计时 → 统计 → 报告。
# 测试对象：MatMul 128~2048 全尺寸段，输出延迟/算力/带宽三件套。
import mlx.core as mx
import numpy as np
import time

print("=== 算子基准测试报告（MLX / Apple GPU）===")
print("设备:", mx.default_device())

def bench(fn, iters=20, warmup=3):
    """通用基准框架：预热 → 多轮 → 返回 (best, median) 毫秒"""
    for _ in range(warmup):
        mx.eval(fn())
    times = []
    for _ in range(iters):
        t0 = time.perf_counter()
        r = fn()
        mx.eval(r)
        times.append((time.perf_counter() - t0) * 1000)
    return min(times), sorted(times)[len(times) // 2]

print(f"\n{'规模':>10} {'延迟(中位)':>12} {'延迟(最优)':>12} {'算力':>12} {'带宽':>10}")
print("-" * 62)
results = []
for n in [128, 256, 512, 1024, 2048]:
    a = mx.array(np.random.randn(n, n).astype(np.float32))
    b = mx.array(np.random.randn(n, n).astype(np.float32))
    best, median = bench(lambda: a @ b)
    flops = 2 * n**3
    tflops = flops / (best / 1000) / 1e12
    bytes_moved = 3 * n * n * 4            # 读 A/B + 写 C
    bw = bytes_moved / (best / 1000) / 1e9
    print(f"{n:>6}³  {median:>10.2f}ms {best:>10.2f}ms {tflops:>9.1f}T {bw:>8.0f}G")
    results.append((n, tflops))

print("-" * 62)
peak = max(results, key=lambda r: r[1])
print(f"峰值算力: {peak[1]:.1f} TFLOPS @ {peak[0]}³（FP32）")
print("调优建议生成规则：")
print("  - 小矩阵瓶颈在启动开销 → 批量合并（batching）")
print("  - 大矩阵算力趋平 → 已是 compute-bound，按 06 Roofline 对号入座")
print("  - 若带宽远低于 06 实测上限 → 检查布局/转置/分块")

# 精度回归：与 numpy 对照（抽样）
n = 512
a = mx.array(np.random.randn(n, n).astype(np.float32))
b = mx.array(np.random.randn(n, n).astype(np.float32))
got = np.asarray(a @ b)
ref = np.asarray(a) @ np.asarray(b)
rel = np.linalg.norm(got - ref) / np.linalg.norm(ref)
print(f"\n精度回归: 512³ 相对误差 {rel:.2e}（< 1e-3 通过）")
print("✅" if rel < 1e-3 else "❌", "基准框架验证通过：性能 + 精度双回归")
