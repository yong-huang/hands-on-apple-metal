# 生成基准用小型分类模型：784 → 256 → 10 的两层全连接（权重随机，只测延迟不测精度）
import numpy as np
import coremltools as ct
from coremltools.models.datatypes import Array
from coremltools.models.neural_network import NeuralNetworkBuilder

rng = np.random.default_rng(42)
W1 = rng.standard_normal((256, 784)).astype(np.float32) * 0.05
b1 = np.zeros(256, dtype=np.float32)
W2 = rng.standard_normal((10, 256)).astype(np.float32) * 0.05
b2 = np.zeros(10, dtype=np.float32)

builder = NeuralNetworkBuilder(
    input_features=[("x", Array(784))],
    output_features=[("y", Array(10))],
)
builder.add_inner_product(name="fc1", W=W1, b=b1, input_channels=784, output_channels=256, has_bias=True, input_name="x", output_name="h")
builder.add_activation(name="relu1", non_linearity="RELU", input_name="h", output_name="h1")
builder.add_inner_product(name="fc2", W=W2, b=b2, input_channels=256, output_channels=10, has_bias=True, input_name="h1", output_name="y")
builder.set_input(["x"], [[784]])
builder.set_output(["y"], [[10]])
model = ct.models.MLModel(builder.spec)
model.short_description = "784-256-10 两层全连接，基准延迟用"
model.save("Model.mlpackage")
print("Model.mlpackage 已生成")
