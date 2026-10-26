"""曲库联网诊断：只发起公开曲库请求，不初始化蓝牙、不上传或播放曲谱。"""
from __future__ import annotations

import os
import sys
import time
import traceback
from pathlib import Path
from urllib.error import URLError

from .service import ScoreLibrary


def error_summary(error: Exception) -> str:
    """保留错误类型及系统错误码；界面用纯文本显示，最多500字。"""
    reason = error.reason if isinstance(error, URLError) else error
    return f"{type(reason).__name__}: {reason}"[:500]


def check_catalog(cache_root: Path) -> dict:
    """强制联网检查搜索和推荐；返回JSON可序列化报告，缓存限制在指定目录。"""
    started = time.monotonic()
    report = {
        "frozen": bool(getattr(sys, "frozen", False)),
        "hardwareAccessed": False,
        "proxyEnvironmentPresent": {
            name: bool(os.environ.get(name))
            for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY")
        },
        "checks": [],
    }
    try:
        library = ScoreLibrary(cache_root)
        for operation in ("search", "recommend"):
            start = time.monotonic()
            try:
                result = (library.catalog.search("piano", 0, refresh=True)
                          if operation == "search" else library.recommend(0, True))
                report["checks"].append({
                    "operation": operation,
                    "ok": bool(result["items"]) and not result.get("offline", False),
                    "items": len(result["items"]),
                    "cached": result.get("cached", False),
                    "offline": result.get("offline", False),
                    "error": result.get("offlineReason"),
                    "seconds": round(time.monotonic() - start, 3),
                })
            except Exception as error:
                report["checks"].append({
                    "operation": operation, "ok": False,
                    "error": error_summary(error),
                    "traceback": traceback.format_exc(),
                    "seconds": round(time.monotonic() - start, 3),
                })
    except Exception as error:
        report["error"] = error_summary(error)
    report["ok"] = len(report["checks"]) == 2 and all(item["ok"] for item in report["checks"])
    report["seconds"] = round(time.monotonic() - started, 3)
    return report
