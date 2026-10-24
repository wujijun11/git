# 现有工程完善：蓝牙写入、串口恢复与按键释放

本轮直接修改现有工程，并完成 C3 固件、完整 FPGA 主工程和 Windows 软件的
实际编译。尚未烧录硬件，不能据此宣称实机 ACK、琴键音高或音频已经验收。

## 修改与依据

1. **C3 写入不再被覆盖或跨连接重放。** 当前实际使用的 Arduino-ESP32 3.3.5
   NimBLE 包装库会立即更新特征值，却延迟调用仅持有特征指针的写回调。
   相邻包会覆盖前包；旧连接延迟回调也可能读到新连接的首包。本项目固定一个
   局部 BLE 库副本，仅将该分支改为同步回调。桥接回调只做校验、复制和零等待
   入队，不通知、不等待 UART；原先用于支持回调内通知的延迟不再需要。
   全局 SDK 未改。许可证、来源和逐文件校验见 `firmware/libraries/BridgeBLE/`。
2. **FPGA 遇到截断帧头时保留下一包起点。** 在等待版本字节时收到 `A5`，
   将其保留为新同步前缀，避免 `A5 5A` 残留吞掉后续完整 READBACK 请求。
   有效版本、payload 和 CRC 仍需正常校验。
3. **电脑端整批释放先排队。** `releaseAll()` 同步排入全部去重 NOTE OFF 后
   才等待响应，避免释放旧和弦期间的新按键被后续旧 NOTE OFF 静音。
   Windows 交付版本为 1.0.2。

## 验证记录

- [C3：真实 SDK 函数与桥接联编](c3-deferred-write/README.md)：原 56 项通过、
  新增 4 项失败；修复后 **60/60** 通过，输入校验一致。覆盖相邻写、重连、
  首包重复及畸形写。原 UART 辅助代码的 49 项故障测试仍对应同一头文件。
- [FPGA 异常流恢复](../fpga-transport-audit-20261023/README.md)：修复前故障复现；
  修复后新增 10 项、既有 UART、watchdog 和真实 arbiter/FIFO 集成回归通过。
- [电脑控制器](desktop-controller/README.md)：旧版新增竞态用例失败；新版完整
  回归通过，另验证连续释放、新按键、音高去重和失败关闭无未处理拒绝。
- [C3 实际编译清单](c3-firmware/build-manifest.json)：编译成功，程序
  667500 / 1310720 字节，静态 RAM 24004 / 327680 字节；确认使用全部 30 个
  局部 BLE C++ 源文件，64 个库文件和 2 个桥接源文件均已冻结校验。
- [FPGA 完整构建](fpga-build/build_uart-prefix-recovery_20261023_094225_1ccb041d/build-results.json)：
  编译、布局布线成功；Setup/Hold 违例均 0；Setup/Hold/Recovery/Removal
  最小余量分别为 0.038 / 0.146 / 6.396 / 0.504 ns。原 `full/impl` 保持完好。
  新完整主工程 GAO 标识为 `6D50`，不是旧版 `CCCF`。
- [Windows 打包清单](desktop-build/evidence/build-manifest.json)：正式 EXE 打包
  和依赖自检通过，内嵌网页文件逐一匹配当前源码。
- [真实 EXE 原生传输回归](desktop-build/evidence/packaged-native-result.json)：
  从本次 EXE 提取代码运行 11 项测试，全部通过，代码与当前源码一致。
- [Chromium 界面回归](desktop-ui/run-manifest.json)：既有完整界面、演奏、曲谱、
  录音和取消用例通过，页面错误为 0，生产输入前后校验一致。

编译和模拟验证不代替 BLE 射频、实际接线、板外 I²S 或功放试听。沿用当前
UART 接线、协议和 25 键/64 声部主工程功能；本轮只修复已复现的软件边界。

## 构建与交付

从工程目录使用 `scripts/build-ble-bridge.ps1` 编译 C3；脚本强制选择项目局部
BLE 库，并拒绝源码在编译期间变化或编译器选回旧 SDK 库的产物。
完整 FPGA 构建采用 `scripts/build-contest-isolated.py`，输入源码与现有实现隔离。
Windows 构建使用 `desktop/build.ps1 -SkipInstall` 和现有项目依赖环境。

本次源码与 C3/FPGA 产物打包在 `release/piano-code-hardening-20261023/`；
Windows 便携包为 `desktop/TangNeonStudio-Windows-1.0.2.zip`。
