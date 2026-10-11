# Slider4 发布 Gerber 独立审计

审计对象：`Gerber_Touch25_Slider4_100x20_R1_Release.zip`，与同目录 `design_manifest.json` 对照。**73 项检查全部通过，失败项为 0。**

此审计直接解析发布 ZIP 中的 RS-274X、Excellon 和 FlyingProbeTesting 数据，不使用板生成脚本或 EasyEDA UI。复用独立解析器的 Gerber、钻孔和几何函数；没有调用其硬编码为原 Touch25 25 键板的 `audit()`。源 ZIP 和清单在审计前后逐字节相同。

| 核对项目 | 实际文件结果 |
|---|---|
| 板框 | 100 × 20 mm；Cartesian 坐标 (0, 0) 至 (100, -20)；4 条边闭合；周长 240 mm；无额外切口 |
| 顶层电极 | S0/S1/S2/S3 共 4 个独立网络；30 个区域分别为 6/9/9/6 个；全部顶点和清单匹配，容差 0.00002 mm |
| 走线 | 顶层 4 段、底层 10 段，共 14 段；坐标逐段匹配；线宽均为 0.2 mm |
| 转接孔 | 4 个 PTH，孔径 0.3 mm；外径 0.8 mm；顶底层名义环宽 0.25 mm |
| J4 孔 | 4 个 PTH，孔径 1.0 mm；焊盘 1.8 mm；顶底层最小名义环宽 0.4 mm |
| 固定孔 | 2 个 NPTH，孔径 3.2 mm；预览坐标 (3, 8.5)、(97, 8.5) mm |
| 钻孔总数 | 8 个 PTH + 2 个 NPTH；无额外孔；全部孔在板内 |
| 阻焊 | 顶底阻焊各仅 6 个非零开窗：2 个固定孔、4 个连接器；所有触摸电极、顶层引出走线及转接孔均无开窗 |
| 钢网 | ZIP 未包含 GTP/GBP 钢网文件 |
| 连接 | 每个电极的所有区域经顶层走线和转接孔，连到底层对应 J4 引脚；共 4 个独立电气连通分量，无互相短路，无多余铜分量 |
| 网络间隙 | 顶层最小约 0.299475 mm；底层最小约 0.600244 mm；均大于清单要求 0.25 mm |
| 引脚方向 | 正面观察，左至右为 J4 1/2/3/4；顶底层 Pin 1 均为方焊盘，其余圆焊盘；间距 2.54 mm |

J4 引脚和清单中的 MPR121 映射如下；Gerber 几何及 ZIP 的 FlyingProbeTesting 引脚网络同时核对通过。MPR121 外部接线归属来自清单，不能由纯铜层几何独立证明。

| J4 引脚 | 网络 | 清单 MPR121 板 | 清单 ELE | 预览孔位 mm |
|---|---|---|---|---|
| 1（方形，正面左侧） | S0 | 1 | 8 | (46.19, 17.5) |
| 2 | S1 | 1 | 9 | (48.73, 17.5) |
| 3 | S2 | 1 | 10 | (51.27, 17.5) |
| 4 | S3 | 1 | 11 | (53.81, 17.5) |

NPTH 在顶底铜层各带一个与 3.2 mm 名义钻孔完全同心、同直径的铜圆盘。审计仅精确扣除这 4 个会被名义钻孔全部去除的圆盘，剩余名义环宽为 0；不把它们误判为独立电气网络。没有模拟加工对准误差、钻孔公差或板厂 CAM 净空处理。

独立解析器对圆、弧的多边形化径向误差不大于 0.001 mm，接触判断容差为 0.002 mm。顶底丝印已完成语法解析和数量记录，但未对文字内容做 OCR。`Gerber_DrillDrawingLayer.GDD` 是说明性的钻孔图；其空心 IconRect/IconTriangle 符号使用解析器不支持的 clear 宏，仅清点并记录 SHA-256，实际制造钻孔以完整解析的两份 Excellon 为审计依据。FlyingProbeTesting 为每个物理 PTH 焊盘重复输出两条记录；铜层和钻孔中每个孔位仍只有一个焊盘/钻孔。

PCB 厚度、材料、触摸灵敏度、装配方向及固件延迟不属于此制造几何审计的证明范围。

输入指纹：

- 发布 ZIP SHA-256：`cc42db0eb285b1beadff57730611564abc13e1622a95892cc32e083ecc9644ef`
- 清单 SHA-256：`5ec3404b73d4923e3bde95b6c0a2a52eae140cc2090e5fbd4c73b4fbc06fe9b3`

完整机器可读报告：[`gerber_release_independent_audit.json`](gerber_release_independent_audit.json)。可复现审计程序：[`audit_release_gerber.py`](audit_release_gerber.py)。运行命令：`python hardware/slider4/verification/audit_release_gerber.py`（在仓库根目录）。
