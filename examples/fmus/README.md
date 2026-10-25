# 预编译 FMU

来自 [Reference-FMUs v0.0.42](https://github.com/modelica/Reference-FMUs/releases/tag/v0.0.42) 的官方 release 包，未做任何修改。

```
fmus/
├─ 3.0/   # 9 个 FMI 3.0 FMU
├─ 2.0/   # 6 个 FMI 2.0 FMU
└─ LICENSE.txt
```

每个 FMU 都是 ZIP 包，包含 `modelDescription.xml`、多平台二进制（Windows x86/x86_64、Linux x86_64/aarch64、macOS aarch64、WASM）、C 源码、文档和分层标准扩展。

## 快速使用

FMU 本质是 ZIP，可直接查看内容：

```powershell
# 列出内容（把 .fmu 当 zip 打开）
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::OpenRead("$PWD\3.0\BouncingBall.fmu").Entries |
    Select-Object FullName, Length
```

或解包后阅读 `modelDescription.xml`：

```powershell
Copy-Item .\3.0\BouncingBall.fmu .\BouncingBall.zip
Expand-Archive .\BouncingBall.zip .\BouncingBall
```

## 与源码的对应关系

| FMU | 源码 |
| --- | --- |
| `3.0/BouncingBall.fmu` | [`../reference-fmus/BouncingBall`](../reference-fmus/BouncingBall) |
| `3.0/Feedthrough.fmu` | [`../reference-fmus/Feedthrough`](../reference-fmus/Feedthrough) |
| ... | 每个模型目录下都有 `FMI3.xml` 和 `model.c` |

修改源码后重新编译，即可生成自己的 FMU：

```powershell
cd ..\reference-fmus
cmake -B build .
cmake --build build --config Release
# 输出：build/fmus/*.fmu
```
