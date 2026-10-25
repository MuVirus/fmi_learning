# 工具（规划）

这里放后续为教学编写的辅助工具。

计划中的工具：

| 工具 | 用途 | 状态 |
| --- | --- | --- |
| `fmu-inspect` | 解包 FMU，格式化输出 `modelDescription.xml`，列出变量表和平台二进制 | 规划 |
| `fmu-validate` | 用 `docs/spec-3.0.2/schema/` 校验描述文件 | 规划 |
| `fmu-diff` | 对比同一模型的 FMI 2.0 / 3.0 描述差异 | 规划 |

已有的现成工具（无需自己写）：

- [fmusim](https://modelica.github.io/fmusim/)：官方命令行工具，检查、验证、仿真 FMU。
- [FMPy](https://github.com/CATIA-Systems/FMPy)：Python 库，适合快速做导入端实验。
- [FMI Kit for Simulink](https://github.com/CATIA-Systems/FMIKit-Simulink)：Simulink 集成。
