# 主工程集成版 延音功能测试说明

2026-10-31按用户要求，将`codex/sustain-20261030`及其前序和弦、菜单更新统一纳入主工程。
设计源码沿用队友提交`9168f0cdd40e0b49cc801497d184b8d29d82affd`；主入口为`full/ContestFull.gprj`。
配套Windows1.5.2-sustain-test和Android1.9-sustain-test；延音默认关闭，C3固件不变。
新增延音仍未完成实物验收。本次不自动下载或改写板卡Flash，不覆盖原F571发布包。
本次重新检查范围与重建入口见`docs/主工程合并记录_20261031.md`。

## 原独立测试分支发布记录

# Chord F571延音独立测试版

分支`codex/sustain-20261030`，基线`df6e8f6f8fcc60a31d0ff549eab37640f67aa4f7`。
新增默认关闭的延音、板上菜单和Windows/Android开关，不改变公共V2或音源算法。

用户最终选择仍是F571。2026-10-30按用户要求发布到独立测试分支，保留“未上板测试”；不合并main、不自动下载、不写Flash。
测试FS UserCode `7D2F`，新增硬件听感与长期稳定性待用户实测。
34项ModelSim入口、21条客户端检查命令及完整Gowin构建通过；额外Logic164、Register103，BSRAM/DSP/时钟资源无增加。
最小Setup1.165ns、Hold0.126ns。Windows1.5.2-sustain-test，Android1.9-sustain-test/code11。
完整原理、测试、资源、限制及复现见`docs/开关式延音与蓝牙控制实现说明_20261030.md`。
