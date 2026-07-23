# sim/generate_4x4_data.py
import numpy as np

N_SEQ = 20
ROWS = 4
COLS = 4

print("🚀 正在生成 4x4 Mini-Chip 物理后仿验证数据...")

def float16_to_hex(f):
    return "{:04x}".format(np.float16(f).view(np.uint16))

def vec_to_flat_hex(vec):
    hex_str = ""
    for i in range(ROWS-1, -1, -1): # 修正了之前的硬编码位宽
        hex_str += float16_to_hex(vec[i])
    return hex_str

W_bits = np.random.randint(0, 2, size=(ROWS, COLS))
X = np.random.uniform(0.5, 1.5, size=(N_SEQ, ROWS)).astype(np.float16)
g = np.random.uniform(0.5, 1.5, size=(ROWS,)).astype(np.float16)
h = np.random.uniform(0.5, 1.5, size=(COLS,)).astype(np.float16)

Y_expected = np.zeros((N_SEQ, COLS), dtype=np.float16)

for n in range(N_SEQ):
    X_scaled = np.zeros(ROWS, dtype=np.float16)
    for i in range(ROWS):
        X_scaled[i] = np.float16(X[n, i] * g[i])
    for j in range(COLS):
        acc = np.float16(0.0)
        for i in range(ROWS):
            val = X_scaled[i]
            if W_bits[i, j] == 0:
                val = np.float16(-val)
            acc = np.float16(acc + val)
        Y_expected[n, j] = np.float16(acc * h[j])

with open("W_test_4x4.txt", "w") as f:
    for i in range(ROWS-1, -1, -1):
        for j in range(COLS-1, -1, -1):
            f.write(f"{W_bits[i, j]}\n")

with open("g_test_4x4.txt", "w") as f: f.write(vec_to_flat_hex(g) + "\n")
with open("h_test_4x4.txt", "w") as f: f.write(vec_to_flat_hex(h) + "\n")

with open("X_test_4x4.txt", "w") as f_x, open("Y_expected_4x4.txt", "w") as f_y:
    for n in range(N_SEQ):
        f_x.write(vec_to_flat_hex(X[n]) + "\n")
        f_y.write(vec_to_flat_hex(Y_expected[n]) + "\n")

print("✅ 4x4 测试数据生成完毕！")