# 20 · Scaled Dot-Product Attention：手写 vs mx.fast
# Attention 是 Transformer 的算子核心。手写矩阵乘版本对照
# mx.fast.scaled_dot_product_attention——两者应数值一致。
import mlx.core as mx
import numpy as np

print("=== MLX 20 · Attention 算子 ===")

def attention_manual(q, k, v, scale=None):
    # q,k,v: [B, H, S, D]；注意力 = softmax(QKᵀ/√d)·V
    d = q.shape[-1]
    scale = scale or 1.0 / d**0.5
    logits = (q * scale) @ k.transpose(0, 1, 3, 2)     # [B,H,S,S]
    # 数值稳定 softmax（减 max）
    m = mx.max(logits, axis=-1, keepdims=True)
    e = mx.exp(logits - m)
    p = e / mx.sum(e, axis=-1, keepdims=True)
    return p @ v                                        # [B,H,S,D]

rng = np.random.default_rng(7)
B, H, S, D = 2, 4, 256, 64
q = mx.array(rng.standard_normal((B, H, S, D)).astype(np.float32))
k = mx.array(rng.standard_normal((B, H, S, D)).astype(np.float32))
v = mx.array(rng.standard_normal((B, H, S, D)).astype(np.float32))

mine = attention_manual(q, k, v)
ref = mx.fast.scaled_dot_product_attention(q, k, v, scale=1.0 / D**0.5)
mx.eval(mine); mx.eval(ref)

mine_np = np.asarray(mine); ref_np = np.asarray(ref)
max_diff = np.abs(mine_np - ref_np).max()
print(f"形状: {q.shape} → 输出 {mine.shape}")
print(f"手写 vs mx.fast 最大绝对差: {max_diff:.2e}")

# 语义验证：注意力输出应是 V 的凸组合（每行权重和为 1）
d = q.shape[-1]
logits = (q * (1.0 / d**0.5)) @ k.transpose(0, 1, 3, 2)
m = mx.max(logits, axis=-1, keepdims=True)
p = mx.softmax(logits - m, axis=-1)
mx.eval(p)
print(f"注意力权重行和 ≈ {np.asarray(p.sum(axis=-1)).mean():.6f}（期望 = 1）")
assert max_diff < 1e-3   # 融合内核与手写链路的浮点累加顺序差异
print("✅ 验证通过：手写 SDP 与 mx.fast 融合内核数值一致")
print("提示: scale=1/√d 是关键——不做缩放时 logits 方差随 d 增大，softmax 会饱和")
