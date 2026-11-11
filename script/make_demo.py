#!/usr/bin/env python3
"""Generate synthetic, timestamped speech outside the repository for UI validation."""
import json
import pathlib
import shutil
import subprocess
import sys
import wave

out = pathlib.Path(sys.argv[1]).expanduser().resolve()
source = pathlib.Path(__file__).resolve().parent.parent
if out == source or source in out.parents:
    raise SystemExit("Demo audio must be outside the source repository")
out.mkdir(parents=True, exist_ok=True)
phrases = [
    "我们先把首页精简为当前、历史和设置三个入口。",
    "历史里按日期查看对话，点击文字就能回听对应录音。",
    "每天结束录音以后再接线，完整原件要先保存在本地。",
    "如果网络中断，已经完成的转写不用重来，继续处理后面的部分。",
    "明天先验证设备断联时录音会不会中断。",
    "测试结果确认以后，再安排全天九个半小时的录音验证。",
]
frames = bytearray(b"\0" * 32000)
lines = []
for index, phrase in enumerate(phrases):
    path = out / f"line-{index}.wav"
    subprocess.run(["/usr/bin/say", "-v", "Tingting", "-r", "190", "--file-format=WAVE", "--data-format=LEI16@16000", "-o", str(path), phrase], check=True)
    with wave.open(str(path)) as f:
        assert f.getframerate() == 16000 and f.getnchannels() == 1 and f.getsampwidth() == 2
        data = f.readframes(f.getnframes())
    start = len(frames) / 32000
    frames.extend(data)
    end = len(frames) / 32000
    lines.append(dict(id=f"0:{index + 1}", start=start, end=end, text=phrase, speaker=None))
    frames.extend(b"\0" * (64000 if index % 2 else 16000))
path = out / "note20261109-083000.wav"
with wave.open(str(path), "wb") as f:
    f.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
    f.writeframes(frames)
shutil.copyfile(path, out / "note20261106-093000.wav")
(out / "transcript.json").write_text(json.dumps(lines, ensure_ascii=False, indent=2))
print(f"Synthetic audio: {len(frames) / 32000:.2f} seconds; {len(lines)} timestamped lines")
