
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results.txt"
POOL = ROOT / "pool.txt"


def read_lines(path):
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8-sig").splitlines()


def address_key(line):
    # 地址部分作为唯一标识，忽略 # 后面的备注
    return line.split("#", 1)[0].strip()


def speed(line):
    match = re.search(r"(\d+(?:\.\d+)?)\s*MB/s", line, re.I)
    return float(match.group(1)) if match else 0.0


best = {}

# 先载入历史 IP 池
for line in read_lines(POOL):
    line = line.strip()
    key = address_key(line)
    if not key:
        continue
    best[key] = (speed(line), line)

# 再合并本次测速结果
for line in read_lines(RESULTS):
    line = line.strip()
    key = address_key(line)
    if not key:
        continue

    current_speed = speed(line)
    previous = best.get(key)

    if previous is None or current_speed > previous[0]:
        best[key] = (current_speed, line)

# 按历史最高下载速度降序排列
ordered = sorted(
    best.values(),
    key=lambda item: item[0],
    reverse=True,
)

POOL.write_text(
    "".join(line + "\n" for _, line in ordered),
    encoding="utf-8",
)

print(f"本次输入：{len(read_lines(RESULTS))} 行")
print(f"累计不同地址：{len(best)} 个")
print(f"已更新：{POOL}")
