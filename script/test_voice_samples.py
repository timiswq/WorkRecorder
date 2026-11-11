#!/usr/bin/env python3
"""Prepare the public input files used by the opt-in voice recognition integration test."""
import argparse
import pathlib
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
RELEASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models"
SAMPLES = ("fangjun-sr-2", "fangjun-test-sr-1", "leijun-test-sr-2")


def raw_packets(ogg):
    cursor = 0
    partial = bytearray()
    packets = []
    while cursor < len(ogg):
        if ogg[cursor:cursor + 4] != b"OggS":
            raise ValueError("Unexpected Ogg header")
        segments = ogg[cursor + 26]
        lengths = ogg[cursor + 27:cursor + 27 + segments]
        cursor += 27 + segments
        for length in lengths:
            partial.extend(ogg[cursor:cursor + length])
            cursor += length
            if length < 255:
                packets.append(bytes(partial))
                partial.clear()
    audio = packets[2:]
    if partial or not audio or any(len(packet) != 40 for packet in audio):
        raise ValueError("Expected one 40-byte card packet per 20 ms")
    return b"".join(audio)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=pathlib.Path, help="Output outside the source repository")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="Executable with the libopus encoder")
    args = parser.parse_args()
    destination = args.directory.expanduser().resolve()
    if destination == ROOT or ROOT in destination.parents:
        parser.error("Choose a directory outside the source repository")
    destination.mkdir(parents=True, exist_ok=True)
    for name in SAMPLES:
        wav = destination / (name + ".wav")
        with urllib.request.urlopen(f"{RELEASE}/{name}.wav", timeout=30) as response:
            wav.write_bytes(response.read())
        ogg = subprocess.check_output([
            args.ffmpeg, "-v", "error", "-i", str(wav), "-c:a", "libopus", "-ar", "16000",
            "-ac", "1", "-b:a", "16k", "-application", "voip", "-frame_duration", "20",
            "-vbr", "off", "-f", "opus", "pipe:1",
        ])
        wav.with_suffix(".opusraw").write_bytes(raw_packets(ogg))


if __name__ == "__main__":
    main()
