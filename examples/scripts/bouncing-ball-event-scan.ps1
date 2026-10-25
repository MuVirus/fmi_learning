<#
.SYNOPSIS
    用显式欧拉法扫描 BouncingBall 的事件序列（教学用，不依赖 FMU 二进制）。

.DESCRIPTION
    复现 examples/reference-fmus/BouncingBall/model.c 的方程与事件更新：

        der(h) = v
        der(v) = g
        z      = h        （h 落在 (-eps, 0] 且 v > 0 时取 -eps）

    事件更新（eventUpdate）：

        h = DBL_MIN
        v = -v * e
        若 |v| < 0.1，则 v = 0、g = 0，小球停止弹跳

    这是「导入端视角」的简化数值实验：用固定步长和事件后立即重初始化，
    复现 simulate_fmi3_me.c 的显式欧拉循环，帮助理解事件指示器的符号域变化。
    它不替代真正的 FMU 调用，也不做事件定位（二分/插值）。

.PARAMETER Step
    积分步长，默认 1e-3（与 BouncingBall/config.h 的 FIXED_SOLVER_STEP 一致）。

.PARAMETER StopTime
    仿真终止时间，默认 3.0（与 FMI3.xml 的 DefaultExperiment 一致）。

.PARAMETER E
    恢复系数，默认 0.7（与 FMI3.xml 中参数 e 的 start 值一致）。

.EXAMPLE
    .\examples\scripts\bouncing-ball-event-scan.ps1

.EXAMPLE
    .\examples\scripts\bouncing-ball-event-scan.ps1 -Step 0.0005 -StopTime 3
#>
[CmdletBinding()]
param(
    [ValidateRange(1e-6, 0.1)]
    [double]$Step = 1e-3,

    [ValidateRange(1e-3, 1000)]
    [double]$StopTime = 3.0,

    [ValidateRange(0.5, 1.0)]
    [double]$E = 0.7
)

$ErrorActionPreference = 'Stop'

$h = 1.0
$v = 0.0
$g = -9.81
$e = $E
$event = 0
$stopped = $false
$events = [System.Collections.Generic.List[object]]::new()

$steps = [int][math]::Ceiling($StopTime / $Step)

for ($i = 1; $i -le $steps; $i++) {

    $h += $Step * $v
    $v += $Step * $g
    $t = $i * $Step

    if ($h -le 0 -and $v -lt 0) {

        $event++

        $heightBefore = $h
        $velocityBefore = $v

        $h = 2.2250738585072014E-308   # C 的 DBL_MIN
        $v = -$v * $e

        if ([math]::Abs($v) -lt 0.1) {
            $v = 0.0
            $g = 0.0
            $stopped = $true
        }

        $events.Add([pscustomobject]@{
            Event          = $event
            Time           = [math]::Round($t, 3)
            HeightBefore   = [math]::Round($heightBefore, 6)
            VelocityBefore = [math]::Round($velocityBefore, 4)
            VelocityAfter  = [math]::Round($v, 4)
            Stopped        = $stopped
        })
    }
}

"Step = $Step s, StopTime = $StopTime s, e = $e"
"Events found: $event"
""

$events | Format-Table -AutoSize

if ($stopped) {
    "Ball stopped after event $event (|v| < 0.1 m/s)."
} else {
    "Ball was still bouncing at StopTime."
}
