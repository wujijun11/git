# 转接底板原生工程草稿

## 当前交付：R1 可编辑工程包

`../release/TangMega60K-Backplane-R1-Editable.zip` 包含可在嘉立创 EDA 专业版继续编辑的文件夹工程。整包解压后打开其中的 `.eprj3`，必须保留相邻的 `sch/`、`pcb/`、`panel/` 目录。

R1 使用 C601944 公针 IDC40 座，通过母对母直通排线接 FPGA J13，不是 FPGA 直插母座。模块通过按网名对应的线束连接。包含9个连接器、69个焊盘、42个接线端点、27个NC；原理图和PCB网络与接口CSV交叉校验一致。已清理30条继承的过期原理图说明，PCB为100×60 mm初步布局，尚无走线和安装孔。

本次通过 `package_editable_r1.py` 直接处理本地原生文件，没有使用电脑操控，也未在EDA中重新打开打包副本验证。校验记录在包内 `validation_report.json`。原理图原生DRC仍有1条未解决警告；PCB未完成布线、原生DRC和制造导出，不能下单。

以下为 R0 历史状态；不要将旧采购清单中的J1母座用于R1。

## R0 历史草稿

`TangMega60K-Interconnect-R0/` 的原理图已替换为9个真实连接器，并按父目录的接口定义完成逻辑网络。原生导出网表与CSV交叉检查一致：42个接线端点、27个NC端点。原理图严格DRC尚有1条警告，记录见 `evidence/draft-schematic-wiring-and-drc.json`，不能称为DRC全通过。

原AHCT参考PCB中的元件和走线已清除。新底板PCB仍为空白工作页：本轮原理图变更导入未产生预期的9个连接器，自动检查已中止，记录见 `evidence/actual-backplane-pcb-draft.json`。尚未完成PCB元件导入、布线、安装面/尺寸核实和PCB DRC，不是生产版本。

预览为 `preview/Backplane_Draft_Schematic.png`；原生网表为 `preview/Backplane_Draft_Netlist.enet`；候选采购料号为 `draft_procurement_bom.csv`。

该目录不得用于下单，也不进入当前接口交付ZIP。生产前仍需根据实际模块针序确定直插母座或线束、安装方向与外形，再完成走线、DRC及制造导出。参见父目录 `order_preparation.md`。
