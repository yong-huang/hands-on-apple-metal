# 18 · Softmax：数值稳定性
# 朴素 softmax 遇到大数值会 overflow：exp(1000) = inf。
# 标准解法 log-sum-exp 技巧：先减去最大值再 exp，结果数学上完全等价。
import mlx.core as mx
import numpy as np

print("=== MLX 18 · 数值稳定的 Softmax ===")

def softmax_naive(x):
    e = mx.exp(x)
    return e / mx.sum(e, axis=-1, keepdims=True)

def softmax_stable(x):
    m = mx.max(x, axis=-1, keepdims=True)      # 减最大值：exp 参数 ≤ 0
    e = mx.exp(x - m)
    return e / mx.sum(e, axis=-1, keepdims=True)

# 案例1：正常输入，两者一致
x1 = mx.array([[1.0, 2.0, 3.0], [1.0, 2.0, 3.0]])
# 案例2：大数值输入（attention logits 的常见场景）
x2 = mx.array([[1000.0, 1001.0, 1002.0], [1000.0, 1001.0, 1002.0]])

for name, x, case in [("正常输入", x1, "两者都应对"), ("大数值输入", x2, "朴素版应溢出")]:
    mx.eval(softmax_naive(x)); mx.eval(softmax_stable(x))
    naive = np.asarray(softmax_naive(x))
    stable = np.asarray(softmax_stable(x))
    print(f"[{name}] 朴素: {naive[0].round(4)} | 稳定: {stable[0].round(4)}")

# 与内置实现对比（大数值）
ref = np.asarray(mx.softmax(x2, axis=-1))
stable = np.asarray(softmax_stable(x2))
print(f"[大数值] 内置 mx.softmax: {ref[0].round(4)}")
assert np.allclose(ref, stable, atol=1e-6), "稳定版与内置不一致"
print("✅ 验证通过：log-sum-exp 技巧与内置实现一致，朴素版在大数值下产生 nan")
print("本质: exp 是单调的，减常数不改变比值——但把 exp 的输入压进了安全区间")
