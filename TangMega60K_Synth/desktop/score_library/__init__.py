"""曲库只负责搜索、缓存、MIDI转换，不直接发送任何FPGA命令。"""
from .service import ScoreLibrary

__all__ = ["ScoreLibrary"]
