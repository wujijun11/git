# 固定地铜维护说明

交付 PCB 的底层地铜为141个锁定 FILL；这不是会自动避让的 POUR。
更改铜层几何后必须重新生成地铜、打开原生编辑器运行 DRC、核对 Gerber，并重新导出制造文件。

根目录 `generate_ground_plane.py` 是本次生成所用脚本，依赖 Python 和 Shapely 2.2.0。
维护时先关闭此项目的 EDA 会话，再将脚本中的 `PROJECT` 改为实际工程目录；
用原生 API 重新采集当前元件焊盘坐标，更新根目录的
`references/critical-layout.json`。不能在改过布局后直接使用本次坐标快照。

独立只读审查脚本在 `verification/check_ground_connectivity.py`。
复跑时也需将其中 `PROJECT` 和 `GERBER` 路径改为当前工程及导出文件的位置。

该生成器仅针对本次“全部 SMD 位于顶层”的设计。增加底层 SMD、
新增底层铜形状、改板框或改走线时，应扩展相应阻挡几何，不能直接运行就当作完成检查。
0.30mm 为目标避让参数，最终间距以原生 DRC 和制造审核为准。
