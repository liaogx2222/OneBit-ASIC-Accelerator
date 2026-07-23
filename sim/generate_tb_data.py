# sim/generate_tb_data.py
import numpy as np
import struct

def float16_to_hex(f):
    # 将 float16 转换为 4 字符的十六进制字符串
    return "{:04x}".format(np.float16(f).view(np.uint16))

def hex_to_float16(h):
    # 将十六进制字符串转换回 float16
    return np.frombuffer(int(h, 16).to_bytes(2, 'little'), dtype=np.float16)[0]

def is_normal(val_hex):
    # 检查是否为正常的规格化数 (排查 Exp=00000 和 Exp=11111)
    val_int = int(val_hex, 16)
    exp = (val_int >> 10) & 0x1F
    return exp != 0x00 and exp != 0x1F

num_tests = 10000
valid_pairs = []

print("正在生成 10,000 组 FP16 测试数据...")
while len(valid_pairs) < num_tests:
    # 随机生成两个 16-bit 无符号整数
    a_uint = np.random.randint(0, 65536, dtype=np.uint16)
    b_uint = np.random.randint(0, 65536, dtype=np.uint16)
    
    a_hex = "{:04x}".format(a_uint)
    b_hex = "{:04x}".format(b_uint)
    
    # 过滤异常输入
    if not (is_normal(a_hex) and is_normal(b_hex)):
        continue
        
    a_f16 = hex_to_float16(a_hex)
    b_f16 = hex_to_float16(b_hex)
    
    # Python(Numpy) 计算标准答案 (默认使用 RNE 奇偶舍入)
    c_f16 = a_f16 + b_f16
    c_hex = float16_to_hex(c_f16)
    
    # 过滤异常输出
    if not is_normal(c_hex):
        continue
        
    valid_pairs.append((a_hex, b_hex, c_hex))

# 保存到 txt 文件
with open("test_data.txt", "w") as f:
    for a, b, c in valid_pairs:
        f.write(f"{a}{b}{c}\n")

print("测试数据生成完毕！已保存至 sim/test_data.txt")