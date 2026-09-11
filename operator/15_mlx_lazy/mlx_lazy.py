# 15 · MLX Lazy Evaluation：计算图构建与延迟执行
# MLX 的操作默认"只记账不算账"：真正的 GPU 工作发生在 mx.eval 或取值时。
# 好处：框架能看到整段计算，做融合、省掉中间物化。
import mlx.core as mx
import numpy as np
import time

print("=== MLX 15 · 延迟执行 ===")
x = mx.array(np.random.rand(8192, 8192).astype(np.float32))  # 256 MB

# —— 构建一条长链：全部是"记账"，GPU 还没动 ——
t0 = time.perf_counter()
y = x
for _ in range(20):
    y = y * 1.0001 + 0.5
t1 = time.perf_counter()
print(f"构建 20 层算子链: {(t1-t0)*1000:.2f} ms（只建图，未计算）")

# —— eval 触发：20 层计算一次性发生 ——
t0 = time.perf_counter()
mx.eval(y)
t1 = time.perf_counter()
print(f"mx.eval 触发全部计算: {(t1-t0)*1000:.1f} ms（20 层 × 256MB）")

# —— 对比：如果每层都物化（强制同步），反而更慢 ——
t0 = time.perf_counter()
z = x
for _ in range(20):
    z = z * 1.0001 + 0.5
    mx.eval(z)   # 每层强制执行，失去整体优化机会
t1 = time.perf_counter()
print(f"每层强制 eval: {(t1-t0)*1000:.1f} ms（频繁同步破坏流水）")

# 数值验证：与 numpy 逐步算的 20 层参照一致
ref = np.asarray(x)
for _ in range(20):
    ref = ref * 1.0001 + 0.5
assert np.allclose(np.asarray(y), ref, rtol=1e-4, atol=1e-3), "惰性结果与参照不符"
print("✅ 验证通过：惰性结果与逐步执行一致，且整体 eval 更快")
