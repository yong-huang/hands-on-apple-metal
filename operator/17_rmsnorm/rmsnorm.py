# 17 · RMSNorm：手写实现 vs mx.fast 内置
# RMSNorm = x / rms(x) * weight，是大模型的标准归一化层。
# 目标：手写版与 mx.fast.rms_norm 数值一致——学会"对答案"式算子验证。
import mlx.core as mx
import numpy as np

print("=== MLX 17 · RMSNorm 算子 ===")

def rms_norm_manual(x, weight, eps=1e-5):
    # 最后一个维度归一化：x / sqrt(mean(x²) + eps) * weight
    ms = mx.mean(x * x, axis=-1, keepdims=True)
    return x / mx.sqrt(ms + eps) * weight

# 测试数据：模拟一个 LLM 层的激活 (batch=4, seq=128, dim=512)
rng = np.random.default_rng(42)
x = mx.array(rng.standard_normal((4, 128, 512)).astype(np.float32))
w = mx.array(rng.uniform(0.5, 1.5, 512).astype(np.float32))

mine = rms_norm_manual(x, w)
ref = mx.fast.rms_norm(x, w, 1e-5)
mx.eval(mine); mx.eval(ref)

mine_np = np.asarray(mine)
ref_np = np.asarray(ref)
max_diff = np.abs(mine_np - ref_np).max()
print(f"手写 vs mx.fast 最大绝对差: {max_diff:.2e}")
assert max_diff < 1e-5, "数值不一致"

# 结构验证：输出每行 RMS 应 ≈ 1（乘 weight 前）
normalized = mine_np / w[None, None, :]
row_rms = np.sqrt((normalized**2).mean(axis=-1))
print(f"归一化后各行 RMS ≈ {row_rms.mean():.4f}（期望 ≈ 1）")
print("✅ 验证通过：手写 RMSNorm 与内置 fast 内核数值一致")
print("提示: eps 的位置（加在均值上还是开方后）是最常见的实现差异点")
