<#
.SYNOPSIS
    对 FMI 3.0 modelDescription.xml 做 XSD 之外的语义检查。

.DESCRIPTION
    XSD 只能检查结构和数据类型，检查不了引用关系和语义规则。
    本脚本补充检查以下内容：

      * 变量名、别名名、valueReference、类型名、单位名是否唯一
      * unit / displayUnit / declaredType 引用是否存在
      * displayUnit 是否定义在对应的 Unit 下
      * 变量元素类型与 declaredType 指向的类型是否一致
      * Enumeration 是否声明了 declaredType，且指向 EnumerationType
      * Dimension 的 valueReference 是否指向 UInt64 的 constant / structuralParameter
      * initial / start 的搭配规则
      * parameter / input / constant 是否提供了 start
      * ModelStructure 的 Output 是否与所有 output 变量一一对应
      * ContinuousStateDerivative 指向的变量是否带 derivative 属性

    这是教学用的「最小检查器」，不是完整的一致性验证器。
    例如它不检查 ModelStructure 的 dependencies、不检查 Clock 的
    intervalVariability 组合、也不检查二进制文件是否存在。

    退出码：
      0  没有错误（可能有警告）
      1  存在错误
      2  文件无法读取或解析

.PARAMETER Path
    要检查的 XML 文件。

.EXAMPLE
    .\examples\scripts\check-model-description.ps1 `
        .\examples\reference-fmus\BouncingBall\FMI3.xml
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "ERROR: file not found: $Path" -ForegroundColor Red
    exit 2
}

$xmlPath = (Resolve-Path -LiteralPath $Path).Path

try {
    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($xmlPath)
}
catch {
    Write-Host "ERROR: cannot parse XML: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

$root = $doc.DocumentElement
$script:errorCount = 0
$script:warningCount = 0

function Write-ErrorItem {
    param([string]$Message)
    Write-Host "ERROR   $Message" -ForegroundColor Red
    $script:errorCount++
}

function Write-WarningItem {
    param([string]$Message)
    Write-Host "WARNING $Message" -ForegroundColor Yellow
    $script:warningCount++
}

function Get-Children {
    param([System.Xml.XmlElement]$Element, [string]$Name)
    if ($null -eq $Element) { return @() }
    return @($Element.SelectNodes($Name))
}

# ---------------------------------------------------------------------------
# 建立索引：单位、类型、变量
# ---------------------------------------------------------------------------

$unitDefinitions = $root.SelectSingleNode('UnitDefinitions')
$displayUnitsByUnit = New-Object 'System.Collections.Generic.Dictionary[string,object]'
$unitNames = New-Object 'System.Collections.Generic.HashSet[string]'

foreach ($unit in (Get-Children $unitDefinitions 'Unit')) {
    if (-not $unitNames.Add($unit.name)) {
        Write-ErrorItem "duplicate Unit name '$($unit.name)'"
    }

    $displayNames = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($displayUnit in (Get-Children $unit 'DisplayUnit')) {
        if (-not $displayNames.Add($displayUnit.name)) {
            Write-ErrorItem "duplicate DisplayUnit name '$($displayUnit.name)' in Unit '$($unit.name)'"
        }
    }
    $displayUnitsByUnit[$unit.name] = $displayNames
}

$typeNodes = Get-Children $root.SelectSingleNode('TypeDefinitions') '*'
$typesByName = New-Object 'System.Collections.Generic.Dictionary[string,object]'
foreach ($typeNode in $typeNodes) {
    if ($typesByName.ContainsKey($typeNode.name)) {
        Write-ErrorItem "duplicate TypeDefinition name '$($typeNode.name)'"
    }
    $typesByName[$typeNode.name] = $typeNode
}

$variableContainer = $root.SelectSingleNode('ModelVariables')
if ($null -eq $variableContainer) {
    Write-Host "ERROR   missing <ModelVariables>" -ForegroundColor Red
    exit 1
}

$variables = Get-Children $variableContainer '*'
$variablesByVr = @{}
$allNames = New-Object 'System.Collections.Generic.HashSet[string]'

function Test-StartPresent {
    param([System.Xml.XmlElement]$Variable)
    if ($Variable.HasAttribute('start')) { return $true }
    return ($null -ne $Variable.SelectSingleNode('Start'))
}

foreach ($variable in $variables) {
    $name = $variable.name
    $vr = $variable.valueReference
    $type = $variable.LocalName

    if ([string]::IsNullOrEmpty($name)) {
        Write-ErrorItem "variable with valueReference '$vr' has an empty name"
    }
    elseif (-not $allNames.Add($name)) {
        Write-ErrorItem "duplicate variable name '$name'"
    }
    if ($typesByName.ContainsKey($name)) {
        Write-ErrorItem "variable name '$name' collides with a TypeDefinition name"
    }

    if ([string]::IsNullOrEmpty($vr)) {
        Write-ErrorItem "variable '$name' has no valueReference"
    }
    elseif ($variablesByVr.ContainsKey($vr)) {
        Write-ErrorItem "duplicate valueReference '$vr' ('$name' and '$($variablesByVr[$vr].name)')"
    }
    else {
        $variablesByVr[$vr] = $variable
    }

    foreach ($alias in (Get-Children $variable 'Alias')) {
        if (-not $allNames.Add($alias.name)) {
            Write-ErrorItem "alias name '$($alias.name)' on variable '$name' is not unique"
        }
    }

    # declaredType 与类型定义
    $declaredTypeName = $null
    if ($variable.HasAttribute('declaredType')) {
        $declaredTypeName = $variable.declaredType
        if (-not $typesByName.ContainsKey($declaredTypeName)) {
            Write-ErrorItem "variable '$name' references unknown declaredType '$declaredTypeName'"
        }
        else {
            $expected = ($typesByName[$declaredTypeName].LocalName -replace 'Type$', '')
            if ($expected -ne $type -and -not ($type -eq 'Clock' -and $expected -eq 'Clock')) {
                Write-ErrorItem "variable '$name' is <$type> but declaredType '$declaredTypeName' is <$($typesByName[$declaredTypeName].LocalName)>"
            }
            if ($type -eq 'Enumeration' -and $typesByName[$declaredTypeName].LocalName -ne 'EnumerationType') {
                Write-ErrorItem "Enumeration '$name' declares non-enumeration type '$declaredTypeName'"
            }
        }
    }
    elseif ($type -eq 'Enumeration') {
        Write-ErrorItem "Enumeration '$name' has no declaredType"
    }

    # 有效单位：变量自身 unit 优先，否则继承 declaredType 的 unit
    $effectiveUnit = $null
    if ($variable.HasAttribute('unit')) {
        $effectiveUnit = $variable.unit
        if (-not $unitNames.Contains($effectiveUnit)) {
            Write-ErrorItem "variable '$name' references unknown unit '$effectiveUnit'"
            $effectiveUnit = $null
        }
    }
    elseif ($declaredTypeName -and $typesByName.ContainsKey($declaredTypeName)) {
        $typeNode = $typesByName[$declaredTypeName]
        if ($typeNode.HasAttribute('unit')) {
            $effectiveUnit = $typeNode.unit
            if (-not $unitNames.Contains($effectiveUnit)) {
                Write-ErrorItem "type '$declaredTypeName' references unknown unit '$effectiveUnit'"
                $effectiveUnit = $null
            }
        }
    }

    if ($variable.HasAttribute('displayUnit')) {
        if (-not $effectiveUnit) {
            Write-ErrorItem "variable '$name' has displayUnit '$($variable.displayUnit)' but no unit"
        }
        elseif (-not $displayUnitsByUnit[$effectiveUnit].Contains($variable.displayUnit)) {
            Write-ErrorItem "variable '$name' references unknown displayUnit '$($variable.displayUnit)' in unit '$effectiveUnit'"
        }
    }

    # initial / start 搭配
    $initial = $null
    if ($variable.HasAttribute('initial')) { $initial = $variable.initial }
    $causality = if ($variable.HasAttribute('causality')) { $variable.causality } else { 'local' }
    $variability = if ($variable.HasAttribute('variability')) { $variable.variability } else { $null }
    $hasStart = Test-StartPresent $variable

    if ($causality -eq 'independent' -and $hasStart) {
        Write-ErrorItem "independent variable '$name' must not have a start value"
    }
    if ($initial -eq 'calculated' -and $hasStart) {
        Write-ErrorItem "variable '$name' has initial=calculated but provides a start value"
    }
    if (($initial -eq 'exact' -or $initial -eq 'approx') -and -not $hasStart) {
        Write-ErrorItem "variable '$name' has initial=$initial but no start value"
    }
    if ($type -ne 'Clock') {
        $needsStart = ($causality -eq 'parameter' -or $causality -eq 'input' -or $variability -eq 'constant')
        if ($needsStart -and -not $hasStart -and $initial -ne 'calculated') {
            Write-ErrorItem "variable '$name' is a $causality/$variability value and must have a start value"
        }
    }

    # Dimension 引用
    foreach ($dimension in (Get-Children $variable 'Dimension')) {
        if ($dimension.HasAttribute('valueReference')) {
            $dimVr = $dimension.valueReference
            if (-not $variablesByVr.ContainsKey($dimVr)) {
                Write-ErrorItem "variable '$name' has a Dimension referencing unknown valueReference '$dimVr'"
            }
            else {
                $target = $variablesByVr[$dimVr]
                if ($target.LocalName -ne 'UInt64') {
                    Write-ErrorItem "variable '$name' has a Dimension referencing '$($target.name)' of type <$($target.LocalName)>, expected <UInt64>"
                }
                $targetCausality = if ($target.HasAttribute('causality')) { $target.causality } else { 'local' }
                $targetVariability = if ($target.HasAttribute('variability')) { $target.variability } else { 'fixed' }
                if ($targetCausality -ne 'structuralParameter' -and $targetVariability -ne 'constant') {
                    Write-ErrorItem "variable '$name' has a Dimension referencing '$($target.name)' (causality=$targetCausality, variability=$targetVariability), expected constant or structuralParameter"
                }
            }
        }
        elseif ($dimension.HasAttribute('start')) {
            if ([double]$dimension.start -le 0) {
                Write-ErrorItem "variable '$name' has a Dimension with non-positive start '$($dimension.start)'"
            }
        }
        else {
            Write-ErrorItem "variable '$name' has a Dimension without start or valueReference"
        }
    }
}

# ---------------------------------------------------------------------------
# ModelStructure
# ---------------------------------------------------------------------------

$structure = $root.SelectSingleNode('ModelStructure')
if ($null -eq $structure) {
    Write-ErrorItem "missing <ModelStructure>"
}
else {
    $outputs = @($variables | Where-Object { $_.HasAttribute('causality') -and $_.causality -eq 'output' })
    $outputVrs = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($output in $outputs) { [void]$outputVrs.Add($output.valueReference) }

    $listedOutputVrs = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($entry in (Get-Children $structure 'Output')) {
        $vr = $entry.valueReference
        if (-not $listedOutputVrs.Add($vr)) {
            Write-ErrorItem "duplicate <Output> entry for valueReference '$vr'"
        }
        if (-not $outputVrs.Contains($vr)) {
            Write-ErrorItem "<Output> references '$vr', which is not an output variable"
        }
    }
    foreach ($vr in $outputVrs) {
        if (-not $listedOutputVrs.Contains($vr)) {
            $missing = $variablesByVr[$vr]
            Write-ErrorItem "output '$($missing.name)' (valueReference $vr) is missing from <ModelStructure><Output>"
        }
    }

    foreach ($entry in (Get-Children $structure 'ContinuousStateDerivative')) {
        $vr = $entry.valueReference
        if (-not $variablesByVr.ContainsKey($vr)) {
            Write-ErrorItem "<ContinuousStateDerivative> references unknown valueReference '$vr'"
        }
        elseif (-not $variablesByVr[$vr].HasAttribute('derivative')) {
            Write-ErrorItem "variable '$($variablesByVr[$vr].name)' is a ContinuousStateDerivative but has no derivative attribute"
        }
    }
}

# ---------------------------------------------------------------------------
# 结果
# ---------------------------------------------------------------------------

Write-Host ""
if ($script:errorCount -gt 0) {
    Write-Host ("FAILED: {0} error(s), {1} warning(s) in {2}" -f $script:errorCount, $script:warningCount, $xmlPath) -ForegroundColor Red
    exit 1
}

Write-Host ("OK: no errors, {0} warning(s) in {1}" -f $script:warningCount, $xmlPath) -ForegroundColor Green
exit 0
