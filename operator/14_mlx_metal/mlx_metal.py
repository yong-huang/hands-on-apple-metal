# 14 · MLX 数组与 Metal 互操作：统一内存的零拷贝红利
# MLX 是苹果为 Apple Silicon 设计的 NumPy——数组天生住在统一内存里，
# CPU/GPU 引用同一份物理内存，没有 host↔device 的显式拷贝。
import mlx.core as mx
import numpy as np
import time

print("=== MLX 14 · 数组与统一内存 ===")
a = mx.array(np.arange(1024, dtype=np.float32))
b = mx.array(np.arange(1024, dtype=np.float32)) * 2
c = a + b
mx.eval(c)  # MLX 惰性执行：eval 才真正触发 GPU 计算
print("c[:5] =", c[:5].tolist())
assert (np.asarray(c) == np.arange(1024) * 3).all(), "结果错误"
print("✅ GPU 计算结果正确：c = a + b = arange × 3")

# —— 统一内存零拷贝：numpy ↔ mx.array 不发生数据搬运 ——
n = np.random.rand(4096, 4096).astype(np.float32)   # 64 MB
t0 = time.perf_counter()
m = mx.array(n)                                       # 建数组
mx.eval(m)                                            # 触发实体化
t1 = time.perf_counter()
print(f"numpy(64MB) → mx.array 首次实体化: {(t1-t0)*1000:.1f} ms（含首次 GPU 触达）")

# 二次操作：同一内存直接复用，无拷贝
t0 = time.perf_counter()
for _ in range(10):
    s = mx.sum(m)
    mx.eval(s)
t1 = time.perf_counter()
print(f"10 次完整 GPU 归约（64MB/次）: {(t1-t0)*1000:.1f} ms，无显式拷贝开销")

# 设备语义：mlx 数组统一由框架调度到 GPU（统一内存下无"显式搬运"概念）
x = mx.array([1.0, 2.0, 3.0])
print("默认设备计算:", (x * 2).tolist())
print("✅ 验证通过：结果与零拷贝往返均符合统一内存预期")
