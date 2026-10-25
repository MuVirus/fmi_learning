# 辅助指南

三份适合配合规范阅读的离线资料，均为单页 HTML，已连同样式和图片一起存档，可断网打开。

## Implementers' Guide

- 路径：[`implementers-guide/index.html`](implementers-guide/index.html)
- 来源：<https://modelica.github.io/fmi-guides/main/fmi-guide/>
- 内容：FMI 项目维护的实现者指南，面向 **FMU 实现者**和**导入端开发者**，解释规范背后的设计动机、接口使用中的常见问题、与其他标准的配合方式。
- 建议：读完规范第 2 章后通读一遍，遇到「规范为什么这样规定」的问题时回来查。

## FMI 3.0 & FMPy Cheatsheet

- 在线地址：<https://dr-clementcoic.github.io/fmi-cheat-sheet/>
- 内容：一页纸速查，涵盖 ME / CS 状态机、函数调用顺序、FMPy（Python）用法示例。
- 建议：打印或放在第二块屏幕，写代码时对照状态机和调用顺序。
- 说明：该页面**未声明开源许可证**，因此没有纳入本仓库，仅在本地留了一份离线副本供个人学习；公开仓库中请直接访问在线地址。

## fmusim 教程

- 路径：[`fmusim-tutorial/index.html`](fmusim-tutorial/index.html)
- 来源：<https://modelica.github.io/fmusim/tutorial/>
- 内容：用 `fmusim` 命令行工具完成 FMU 的解包、`modelDescription.xml` 检查、仿真、日志和绘图。
- 建议：配合 `examples/reference-fmus` 中的 FMU 边看边做。
- 说明：为离线阅读，教程中的站内导航链接（如 Compatibility、Reference）已改为指向在线站点。

## 存档说明

- 上述页面为 2026-10 抓取的静态快照；如与最新在线版本有差异，以在线版本为准。
- 页面中的外部链接（YouTube、GitHub 等）需要联网访问，其余正文、样式、图片均为本地文件。
- 速查表因原站未声明许可证，未纳入本仓库；`docs/guides/fmi-3.0-cheatsheet/` 仅作为本地个人学习副本存在，已被 `.gitignore` 忽略。
