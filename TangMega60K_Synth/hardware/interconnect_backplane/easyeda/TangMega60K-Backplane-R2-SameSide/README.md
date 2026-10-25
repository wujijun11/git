# Tang Mega 60K 外设转接底板 R2

R2 是 190 × 50 mm 的同侧出线转接底板，9 个接口沿同一条长边朝外：FPGA J13、3.3V、三块 MPR121、C3、AHCT 信号、AHCT 5V 和外部 5V。

原生工程：[TangMega60K-Backplane-R2-SameSide.eprj3](TangMega60K-Backplane-R2-SameSide.eprj3)

当前已完成：

- 9 个右角接口的料号、朝向和同侧机械布局。
- 原理图 42 条连接、10 条说明文字。
- 190 × 50 mm 板框、4 个安装孔。
- 两层布线已导入嘉立创 EDA，当前工程已打开并保存。

当前状态：**已通过原生 PCB DRC，可进入嘉立创下单预览**。最终工程实测为 506 条线、56 个过孔；重新打开并保存后再次运行原生 DRC，错误列表为空（`evidence/r2-drc-final-reopen.json`）。下单前仍应在嘉立创预览中确认板框、安装孔、接口方向和线束长度。

接口逻辑保持：MPR 三路 SCL/SDA 独立；ADD 全部接地为 0x5A；C3 使用 GPIO7 TX、GPIO6 RX、GND；AHCT 信号和 5V 电源分开；FPGA J13-11 及 J13-15～40 保持 NC。
