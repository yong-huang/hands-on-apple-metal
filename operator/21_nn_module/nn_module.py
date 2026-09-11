# 21 · 自定义层（nn.Module）：Linear 的最小复刻
# 理解 nn.Module 的三件事：参数注册、forward、状态保存/加载。
import mlx.core as mx
import mlx.nn as nn
import numpy as np

print("=== MLX 21 · 自定义 nn.Module ===")

class MyLinear(nn.Module):
    """仿 nn.Linear 的最小实现：y = x @ W.T + b"""
    def __init__(self, in_features: int, out_features: int, bias: bool = True):
        super().__init__()
        scale = 1.0 / in_features**0.5
        self.weight = mx.random.uniform(-scale, scale, (out_features, in_features))
        self.bias = mx.zeros((out_features,)) if bias else None

    def __call__(self, x):
        x = x @ self.weight.T
        return x + self.bias if self.bias is not None else x

layer = MyLinear(64, 32)
print("参数清单:", {k: v.shape for k, v in layer.parameters().items()})

x = mx.array(np.random.randn(8, 64).astype(np.float32))
y = layer(x)
assert y.shape == (8, 32), "输出形状错误"
# 语义验证：与 numpy 手算一致
y_ref = x @ layer.weight.T + layer.bias
mx.eval(y); mx.eval(y_ref)
assert np.allclose(np.asarray(y), np.asarray(y_ref), atol=1e-5), "前向数值错误"
print("✅ 前向验证: 输出 [8,32]，与手算一致")

# 参数保存 / 加载（safetensors 格式）
layer.save_weights("/tmp/mylinear.safetensors")
layer2 = MyLinear(64, 32)
layer2.load_weights("/tmp/mylinear.safetensors")
y2 = layer2(x)
assert np.allclose(np.asarray(y), np.asarray(y2), atol=1e-6), "加载后不一致"
print("✅ 保存/加载验证: 重建的层前向输出逐位一致")
print("这就是 LoRA/量化工具操作模型权重时的同一套底座")
