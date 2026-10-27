"""Windows实时曲谱：原生线程计时、独占协议会话，不依赖界面刷新。"""
from .player import NativePlayback, validate_rows

__all__ = ["NativePlayback", "validate_rows"]
