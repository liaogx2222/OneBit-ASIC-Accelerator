# sim/generate_matrix_data.py
import numpy as np

# 设定仿真序列长度 (输入 20 组 1x16 的激活值向量)
N_SEQ = 20
ROWS = 16
COLS = 16

print("🚀 正在生成 16x16 脉动阵列的软硬件协同验证数据...")

def float16_to_hex(f):
    return "{:04x}".format(np.float16(f).view(np.uint16))

def vec_to_flat_hex(vec):
    # Verilog 拼接 [255:0] 时，索引 15 在最左边(MSB)，索引 0 在最右边(LSB)
    hex_str = ""
    for i in range(15, -1, -1):
        hex_str += float16_to_hex(vec[i])
    return hex_str

# 1. 随机生成 1-bit 权重 W (用 0 和 1 表示 -1 和 1)
W_bits = np.random.randint(0, 2, size=(ROWS, COLS))

# 2. 生成无极端异常值的 FP16 激活值 X, 以及缩放向量 g, h
# 使用均匀分布确保没有极小的 Subnormal 数干扰基础验证
X = np.random.uniform(0.5, 1.5, size=(N_SEQ, ROWS)).astype(np.float16)
g = np.random.uniform(0.5, 1.5, size=(ROWS,)).astype(np.float16)
h = np.random.uniform(0.5, 1.5, size=(COLS,)).astype(np.float16)

# 3. 按照硬件流水线的“绝对路径”计算 Y_expected
Y_expected = np.zeros((N_SEQ, COLS), dtype=np.float16)

for n in range(N_SEQ):
    # a. 预处理 (Pre-mul)
    X_scaled = np.zeros(ROWS, dtype=np.float16)
    for i in range(ROWS):
        X_scaled[i] = np.float16(X[n, i] * g[i])
        
    # b. 脉动阵列 (Systolic Accumulation)
    for j in range(COLS):
        acc = np.float16(0.0)
        for i in range(ROWS):
            val = X_scaled[i]
            if W_bits[i, j] == 0:
                val = np.float16(-val) # 符号位取反 (OneBit 特性)
            acc = np.float16(acc + val) # 必须这样逐行累加，才能和硬件完全一致！
            
        # c. 后处理 (Post-mul)
        Y_expected[n, j] = np.float16(acc * h[j])

# 4. 保存为 Verilog Testbench 可读的文本
# A. 写入 W.txt (注意：依据移位链规则，最后一位(15,15)最先压入，(0,0)最后压入)
with open("W_test.txt", "w") as f:
    for i in range(ROWS-1, -1, -1):
        for j in range(COLS-1, -1, -1):
            f.write(f"{W_bits[i, j]}\n")

# B. 写入 g_test.txt 和 h_test.txt
with open("g_test.txt", "w") as f: f.write(vec_to_flat_hex(g) + "\n")
with open("h_test.txt", "w") as f: f.write(vec_to_flat_hex(h) + "\n")

# C. 写入 X_test.txt 和 Y_expected.txt
with open("X_test.txt", "w") as f_x, open("Y_expected.txt", "w") as f_y:
    for n in range(N_SEQ):
        f_x.write(vec_to_flat_hex(X[n]) + "\n")
        f_y.write(vec_to_flat_hex(Y_expected[n]) + "\n")

print("✅ 测试数据生成完毕！(包含权重链路、尺度向量与 20 组矩阵吞吐数据)")