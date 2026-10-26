"""将测试台从OLED I2C总线捕获的页式字节渲染成PNG；无第三方依赖，不生成虚构实屏照片。"""
import argparse
import json
import struct
import zlib
from pathlib import Path


def chunk(kind,data):
    return struct.pack(">I",len(data))+kind+data+struct.pack(">I",zlib.crc32(kind+data)&0xffffffff)


def render(frame,path,scale=4):
    width,height=128*scale,64*scale
    rows=[]
    for y in range(height):
        scan=bytearray(b"\x00")
        for x in range(width):
            lit=(frame[(y//scale//8)*128+x//scale]>>(y//scale%8))&1
            scan.extend((255,224,66) if lit else (9,14,19))
        rows.append(scan)
    png=b"\x89PNG\r\n\x1a\n"
    png+=chunk(b"IHDR",struct.pack(">IIBBBBB",width,height,8,2,0,0,0))
    png+=chunk(b"IDAT",zlib.compress(b"".join(rows),9))+chunk(b"IEND",b"")
    path.write_bytes(png)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture",type=Path)
    parser.add_argument("output",type=Path)
    args=parser.parse_args()
    data=[]
    for line in args.capture.read_text(encoding="ascii").splitlines():
        if line.strip().startswith("//"):continue
        data += [int(token,16) for token in line.split()]
    if len(data)!=2048 or any(byte>255 for byte in data):
        raise ValueError("必须是经过OLED测试的两帧共2048字节")
    args.output.mkdir(parents=True,exist_ok=True)
    for index,name in enumerate(("音量模式_仿真像素.png","音色四区_仿真像素.png")):
        render(data[index*1024:(index+1)*1024],args.output/name)
    print(json.dumps({"frames":2,"output":str(args.output)},ensure_ascii=True))


if __name__=="__main__":main()
