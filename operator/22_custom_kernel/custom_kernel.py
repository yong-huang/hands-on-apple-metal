# 22 · MLX 自定义 Metal 内核入门：mx.fast.metal_kernel
# 这是"在 MLX 里塞一段自己的 Metal 源码"的官方通道：
# 声明输入/输出名字 → 写 MSL kernel → 像普通算子一样调用。
import mlx.core as mx
from mlx.core.fast import metal_kernel
import numpy as np

print("=== MLX 22 · 自定义 Metal 内核 ===")

add_kernel = metal_kernel(
    name="my_vector_add",
    input_names=["a", "b"],
    output_names=["out"],
    source="""
    // MLX 自动生成 kernel 签名与参数绑定，这里只写函数体
    uint i = thread_position_in_grid.x;
    out[i] = a[i] + b[i];
    """,
)

n = 4096
a = mx.array(np.arange(n, dtype=np.float32))
b = mx.array(np.arange(n, dtype=np.float32) * 2)
(out,) = add_kernel(inputs=[a, b], output_shapes=[(n,)], output_dtypes=[mx.float32],
                    grid=(n, 1, 1), threadgroup=(256, 1, 1))
mx.eval(out)
print("out[:5] =", out[:5].tolist())
assert (np.asarray(out) == np.arange(n) * 3).all(), "内核结果错误"
print("✅ 验证通过：自定义内核 out = a + b 与期望一致")

# 反例：网格只派一半线程——后半区不会被写入（算子开发要自己保证覆盖）
(out2,) = add_kernel(inputs=[a[:8], b[:8]], output_shapes=[(8,)], output_dtypes=[mx.float32],
                     grid=(4, 1, 1), threadgroup=(4, 1, 1))
mx.eval(out2)
half = np.asarray(out2)
print(f"线程只派一半时后半区未写（示例 {half[6]:.0f}, {half[7]:.0f}）——这就是边界检查的意义")
print("✅ 自定义内核入门完成：声明式 IO + MSL 源码 + 显式网格")
