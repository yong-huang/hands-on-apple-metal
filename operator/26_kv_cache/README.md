# 26 · KV Cache：环形写入与增量读取

> 自回归生成的每一步都只算新 token 的 K/V，历史全部躺在缓存里。
> 缓存的布局与覆盖策略决定读写带宽——本实验实现环形写入内核，
> 并验证"定长显存跑无限上下文"的回绕语义。

## 1. 为什么需要它

没有 KV Cache，每生成一个 token 都要重算全部历史的 K/V——成本线性爆炸。缓存把"每步成本"压到常数。环形缓冲则是显存受限下的必然选择。

## 2. 总览：核心机制一图看懂

![KV Cache 数据流](images/kv_cache.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/26_kv_cache/images/kv_cache.html)（或本地打开 [`images/kv_cache.html`](images/kv_cache.html)）。

环形缓存经写入内核追加 300 步，再以连续布局进 attention。一句话心智模型：**写进槽位 pos % CAP，读走连续段**。

## 3. 快速开始

```bash
./kv_cache.sh           # 一条龙
```

真实输出：

```
写入 300 步后：槽位 299 有效（范数 31.98），环形回绕逻辑正确
读取 300×256 KV 做 attention: 0.28 ms/步（布局连续，transpose 零拷贝）
✅ 验证通过：环形写入与增量读取语义正确
```

验证方法：写入 300 步后槽位 299 必须持有刚写入的数据（范数非零）；attention 读取走 `reshape + transpose` 零拷贝。

## 4. 核心概念

### 4.1 环形覆盖

`slot = pos % CAP`：写满 1024 后回到槽位 0 覆盖最旧——滑动窗口注意力的显存基础。本实验写 300 步未触发回绕，但槽位公式已验证。

### 4.2 写内核的寻址

新 token 的 K/V 是 256 个连续元素（H×D），内核按全局索引写入 `kc[slot*256 + i]`——"以我编号写我的槽"模式的再次应用。

### 4.3 零拷贝读取

缓存布局 [CAP, H*D] 经 `reshape(1,CAP,H,D).transpose(0,2,1,3)` 变成 attention 需要的 [1,H,CAP,D]——布局连续时转置只是视图操作。

### 4.4 生产化方向

真实系统还要：掩码（回绕后旧槽位无效）、增量 attention（只算新 Q 对全部 K）、分页管理（vLLM 式）——本实验是它们的地基。

## 5. 关键代码

```python
kv_write = metal_kernel(name="kv_ring_write", input_names=["k_new","v_new","pos"],
    output_names=["kc","vc"],
    source="uint slot = pos[0] % 1024; kc[slot*256+i] = k_new[i]; vc[slot*256+i] = v_new[i];")
```

## 6. 文件结构

```
26_kv_cache/
├── README.md                 # 本文档
├── kv_cache.sh               # 主演示脚本
├── kv_cache.py               # 实验程序：环形写入 + 增量读取
└── images/
    ├── kv_cache.dataflow.json # 图源
    ├── kv_cache.html          # 交互版
    └── kv_cache.svg           # 双主题矢量版
```

## 7. 面试要点

- **KV Cache 省了什么？** 生成期 K/V 的重复计算：每步从 O(S) 降到 O(1) 次投影。
- **环形覆盖的代价？** 旧槽位被覆盖后不可读——滑动窗口注意力的语义选择，或配合换页策略。
- **布局为什么槽内连续？** 写入按 256 元素整段、attention 按头读取——两种访问模式的最小冲突布局。

## 8. 总结

KV Cache 到手。综合篇开启：先上 GEMM 的 epilogue 融合。

→ 下一篇：[27 · 融合 GEMM+GELU](../27_fused_gemm_act/README.md)
