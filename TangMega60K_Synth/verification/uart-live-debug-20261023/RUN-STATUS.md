# 2026-10-23 串口实机定位记录

当前握手尚未验收通过，不能将编译通过或空闲采样当作连接成功。

- 原完整主工程 `8FE0` 实机状态：2048 个有效样本，音频 PLL、主复位与触摸芯片状态正常，BCLK/LRCLK/音频心跳存在跳变。原始 `main_status_core0.csv` 的导出时间单位为软件显示设置；分析采用设计的 50 MHz 采样假设，不是测量时钟频率。
- 保留全部功能、只增加被动 UART 观察的完整主工程已编译并下载 SRAM，实机读回 **UserCode `3B9F`**；对应 GAO 配置 ID 为 `5544`。时序报告 setup/hold 违例均为 0。源副本有 81 个输入，原生产源码及原实现目录未改。
- `capture-before/main_status_core0.csv` 保存发送前基线：RX/TX 空闲高，所有 UART 事件计数为 0，ready/lock/reset 四位均为 1。尚无成功发送后的对照样本。
- 两次蓝牙探测均停在发现设备阶段，未发送 READBACK。随后枚举确认 C3 的 VID 303A USB 设备和 COM3 消失，FPGA 的两路 FTDI 仍在线。已请用户重新插紧 C3 数据线；不能据此认定 UART 布线或解析有错。
- C3 被动 TX 引脚观察候选位于 `c3-tx-observation-source/ble_bridge`；只增加 GPIO7 输入观察、ISR 计数与 USB 日志，未上传该候选，生产固件未修改。构建和 ELF 审计另存于本目录。
- 本次未写入 FPGA 非易失 Flash。当前 `3B9F` 是 SRAM 下载，掉电后的启动内容仍是之前的 Flash 内容。必须在实际查询、同序号 ACK 与遥测返回验证后再决定固化版本。

后续步骤：C3 恢复上线后，不复位 FPGA，先发送一次已有 BLE READBACK，再重新采集并导出 GAO 状态到 `capture-after`。用 `decode_uart_gao.py` 比较；结合 C3 实际发送计数确认增量。一次正常查询应收到 16 字节、接受 1 条命令、发送 ACK 加遥测共 32 字节。若需要重启或重新下载，必须重新取得基线，不能跨复位直接相减。
