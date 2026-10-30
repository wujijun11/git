# Chord F571延音独立测试版

分支`codex/sustain-20261030`，基线`df6e8f6f8fcc60a31d0ff549eab37640f67aa4f7`。
新增默认关闭的延音、板上菜单和Windows/Android开关，不改变公共V2或音源算法。

用户最终选择仍是F571。2026-10-30按用户要求发布到独立测试分支，保留“未上板测试”；不合并main、不自动下载、不写Flash。
测试FS UserCode `7D2F`，新增硬件听感与长期稳定性待用户实测。
34项ModelSim入口、21条客户端检查命令及完整Gowin构建通过；额外Logic164、Register103，BSRAM/DSP/时钟资源无增加。
最小Setup1.165ns、Hold0.126ns。Windows1.5.2-sustain-test，Android1.9-sustain-test/code11。
完整原理、测试、资源、限制及复现见`docs/开关式延音与蓝牙控制实现说明_20261030.md`。
