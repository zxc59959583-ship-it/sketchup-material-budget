# sketchup-material-budget
SketchUp 材质实时预算插件：按吸取材质统计外表皮面积，扣除重叠接触面并实时输出预算。
# 材质实时预算 · SketchUp Material Budget

> 在 SketchUp 里调整材料，也在 SketchUp 里查看预算。

材质实时预算是一款面向建筑与室内设计方案阶段的 SketchUp 插件。通过吸管选材、模型面积统计、工作室价格库关联与 AI 辅助匹配，帮助设计师在方案调整过程中及时了解费用变化。

**当前版本：v0.8.0**  
**最低兼容目标：SketchUp 2020**
[README_EN.md](https://github.com/user-attachments/files/31860485/README_EN.md)

# Material Budget for SketchUp

[中文](./README.md) | English

Material Budget is a SketchUp extension for early-stage architectural and interior design. Pick the materials you want to price, and the extension calculates exposed surface area, resolves coplanar overlaps, matches a studio price library, and updates the project budget.

Current version: **v0.8.0 · SketchUp 2020+**

[Download RBZ](./su_material_budget_v0.8.0_SU2020_compatible.rbz) · [Source](./src) · [Chinese documentation](./README.md)

![Budget dashboard](./assets/budget-dashboard-v0.8.0.png)

## Highlights

- Pick materials with the native SketchUp eyedropper; only picked materials are priced.
- Traverse groups, components, nested instances, and scaled transformations.
- Count a face once when its front and back use the same material.
- Subtract coplanar overlap from both contacting surfaces.
- Link an Excel/CSV price library with codes, names, aliases, cost components, dates, and sources.
- Show current cost, baseline delta, total project budget, and remaining budget.
- Use DeepSeek only to recommend candidates from the current price library.
- Require human confirmation before an AI-assisted mapping affects pricing.
- Persist confirmed mappings to both the active model and the studio dictionary.
- Export complete UTF-8 CSV results and mapping audit history.

## Installation

1. Download the RBZ package.
2. Open SketchUp Extension Manager and choose **Install Extension**.
3. Restart SketchUp and open **Material Budget**.
4. Link a studio Excel/CSV price library.
5. Keep the dialog open and pick the materials to include.

## Compatibility and validation

The source targets SketchUp 2020 and newer. SketchUp 2020 uses Ruby 2.5 and an older CEF-based HtmlDialog, so Ruby 2.7-only `filter_map`, JavaScript `replaceAll`, and optional chaining are not used.

Static compatibility and package checks pass. A real SketchUp 2020 end-to-end run is still recommended before production deployment.

## AI and data boundaries

- The API key remains in memory for the current SketchUp session.
- Geometry, project budget, SKP files, and personal data are not sent to DeepSeek.
- AI recommends candidates but does not calculate geometry or create prices.
- Final mappings require a human decision and are recorded for review.

See the [Chinese README](./README.md) for the full eight-generation development history, workflow, screenshots, tests, FAQ, and known limitations.


## 项目简介

“这面墙换一种材料，预算会增加多少？”

这是本项目最初希望解决的问题。

在工作室的设计过程中，SketchUp 模型里的材料、尺寸和构件关系经常调整，而预算通常需要另外整理面积、查询单价，再到 Excel 中汇总。模型变化之后，原来的预算也需要重新核对。

材质实时预算将这些操作连接到 SketchUp 中：设计师用吸管选取需要计价的材质，插件读取对应的模型面，计算面积、处理共面接触区域，再结合工作室价格库输出费用明细、当前成本和剩余预算。

对于模型中不规范的材质名称，插件支持建立标准材料关联，并提供可选的 DeepSeek 推荐功能。AI 协助寻找候选，使用者确认实际材料，价格和预算由程序按照价格库计算。

项目根据工作室使用反馈逐步迭代，目前完成至 v0.8.0。

## 核心优势

- **沿用熟悉的设计操作**：使用 SketchUp 吸管选择计价材质，减少逐个构件标注的操作。
- **明确面积计算口径**：处理同一面的正反材质重复，以及共面接触区域的双边扣除。
- **接入工作室价格数据**：关联 Excel/CSV 价格表，支持标准编码、名称和别名匹配。
- **查看方案费用变化**：显示当前成本、预算基准差额、项目总预算和剩余预算。
- **保留人工判断**：AI 推荐的材料关联需要人工确认，并记录建议、选择结果和确认时间。
- **保留原有材质名称**：通过关联建立计价关系，无需将所有 SU 材质逐一重命名。

## 界面预览

### 预算总览

集中查看价格表关联、项目总预算、当前成本、材料费、人工费、计价面积和计算进度。

<img width="1020" height="1339" alt="budget-dashboard-v0 8 0" src="https://github.com/user-attachments/assets/c392eff0-bd7f-452d-8382-118e4e3ef1b9" />


界面中的金额和耗时来自示例模型，用于展示操作流程。未匹配材料和零价项目仍需处理，不能仅凭汇总金额判断预算是否完整。

### 工作室价格库

价格表通过标准编码、名称和别名建立材料索引，并保留费用组成、地区、日期和来源等信息。

<img width="2744" height="1180" alt="price-library-preview" src="https://github.com/user-attachments/assets/024807ea-adbf-4e51-a6dc-956078911236" />


### 价格库使用说明

统一价格字段和填写口径，方便工作室维护和更新数据。

<img width="920" height="587" alt="price-library-guide" src="https://github.com/user-attachments/assets/4cc09f19-19a0-4ba7-9b94-645cf8300c0c" />


## 主要功能

### 吸管选材与统计范围

保持预算窗口打开，在 SketchUp 中使用吸管选取材质，即可将其加入参与预算的材质清单。

统计范围由选中的材质决定，适合先计算墙面、立面饰面或某一类材料，再逐步扩展到其他部分。

### 模型面积统计

递归读取群组、组件和嵌套实例中的面，并考虑实例缩放对面积的影响。

同一组件的不同实例分别参与统计。面积结果依赖模型几何质量，错误面朝向、重复建模等情况仍需检查。

### 正反面与重叠处理

一个 SketchUp Face 可以分别设置正面和背面材质。插件对同一个 Face 只形成一条计价记录，避免两侧使用相同材质时重复累计面积。

对于共面接触区域，交集面积从接触双方分别扣除。例如：

```text
面 A：5 ㎡
面 B：5 ㎡
双方接触区域：2 ㎡

净计价面积 = (5 − 2) + (5 − 2)
           = 6 ㎡
```

当前处理主要面向共面饰面接触，不等同于完整的空间实体布尔运算。

### 价格库关联与更新

支持关联工作室 Excel/CSV 价格表，按标准编码、名称和别名查找材料。

价格文件更新后，可以通过“更新价格”重新读取数据。价格变化可复用已有面积结果；模型几何变化后需要重新计算面积。

### 费用拆分与预算比较

根据价格库中的费用组成，展示材料、人工、机械、管理费和利润等项目，并汇总综合单价与总费用。

支持设置：

- 项目总预算；
- 当前方案的预算基准；
- 相对基准的费用变化；
- 剩余可用预算。

### AI 辅助材料匹配

模型中的 `D07 色`、`M09_Shadow_Night` 等名称，往往无法直接对应真实建筑材料。

插件提供本地候选，并可调用 DeepSeek 从给定材料清单中推荐标准材料。使用者可以查看候选、选择实际材料并确认关联。

推荐主要依据名称、分类和别名等文字信息，不包含纹理图像识别。名称信息不足时，需要使用者根据模型和设计意图判断。

### 人工确认与记录

保留 AI 建议、人工选择、最终结果和确认时间，方便回查材料关联过程。

确认映射同时保存到当前模型和工作室词库。读取时合并两者，并优先采用当前模型中的确认结果，改善“历史已确认、预算仍待确认”的状态不同步问题。

### 计算进度与结果导出

大型 SU 模型采用分批计算、空间筛选和面积缓存，界面显示扫描、重叠处理、面积汇总与更新进度。

支持导出 CSV，供 Excel 查看和团队复核。

## 使用流程

```text
打开 SketchUp 模型
        ↓
打开材质实时预算插件
        ↓
关联工作室价格表
        ↓
用吸管选择参与预算的材质
        ↓
统计模型面积并扣除共面接触区域
        ↓
匹配标准材料
        ├─ 编码、名称或别名直接匹配
        └─ 本地 / AI 候选 → 人工确认关联
        ↓
汇总费用并查看预算变化
        ↓
处理待确认与零价项目
        ↓
导出预算 CSV
```

## 从第一代到第八代

以下“八代”按照功能演进阶段划分，部分阶段包含多个补丁版本。

### 第一代：建立基础预算流程
**对应阶段：v0.1–v0.3**

最初围绕“材质变化后能看到预算变化”建立基础功能：读取材质面积、设置单价、计算小计并汇总预算。

针对使用中出现的 `nil.round` 计算失败，补充空值和异常处理，形成基础的面积与费用计算流程。

### 第二代：解决正反面重复计价
**对应阶段：v0.4**

在穿孔铝板等表皮模型中，同一面的正反两侧可能同时赋予材质。直接将两侧相加，会放大面积和预算。

本阶段确定一个 Face 只形成一条计价记录：优先读取正面材质，正面没有材质时读取背面。

这一规则解决同一面的重复计价问题，但仍需使用者检查模型面朝向；SU 正面不一定就是建筑实际外侧。

### 第三代：完善局部接触与重叠扣除
**对应阶段：v0.5**

实际模型中，两个构件经常只局部接触。早期处理对较小的交集识别不足，不能只判断完全重合或完全包含。

本阶段引入三角剖分、平面投影与多边形裁剪，处理共面局部交集，并将交集从双方分别扣除。

计量规则进一步明确为：两个 5 ㎡面接触 2 ㎡，剩余面积合计为 6 ㎡。

### 第四代：改为吸管选材
**对应阶段：v0.6–v0.6.1**

逐个标注构件操作量较大，因此将统计入口调整为“吸取哪些材质，就计算哪些材质”。

增加参与预算的材质清单和模型内保存，并结合材质事件监听与当前材质轮询，改善吸管选中后未进入预算的问题。

### 第五代：接入工作室价格库
**对应阶段：v0.7.0**

为了使用工作室的实际价格数据，插件从示例单价扩展到 Excel/CSV 价格库。

增加标准编码、名称、别名和费用组成，保留地区、日期及来源字段，使材料关联和预算结果具备复核依据。

### 第六代：完善价格关联与更新
**对应阶段：v0.7.1–v0.7.1.1**

针对重复选择价格表，以及编码或名称格式差异导致匹配失败的问题，增加持续文件关联与一键更新。

统一标准编码、名称和别名的匹配索引，减少大小写、空格、下划线和连字符差异带来的影响。

### 第七代：改善大型模型计算与预算控制
**对应阶段：v0.7.2–v0.7.3**

模型规模增大后，面积扫描和重叠处理带来较长等待；单纯修改价格，也不应再次完成全部几何计算。

本阶段增加分批计算、空间筛选、面积缓存和阶段进度，同时补充项目总预算、剩余预算与预算比较功能。

### 第八代：加入 AI 辅助匹配与人工确认
**对应阶段：v0.8.0**

针对非标准 SU 材质名，加入 DeepSeek 候选推荐、本地回退和人工确认流程。

AI 推荐结果经过编码校验，人工确认后建立标准材料关联，并保留建议和选择记录。

针对确认历史与预算状态不同步的问题，修订为模型与工作室词库双写、合并读取，并优先采用当前模型结果。

同时完成面向 SketchUp 2020 的兼容修改，移除部分新版 Ruby 和 JavaScript 专属语法，增加最低版本检查。

当前交付停留在 v0.8.0，后续设想不计入已实现功能。

## 安装与使用

1. 下载仓库中的 `su_material_budget_v0.8.0_SU2020_compatible.rbz`。
2. 在 SketchUp 中打开“扩展程序管理器”。
3. 点击“安装扩展程序”，选择下载的 RBZ。
4. 安装完成后重启 SketchUp。
5. 打开材质实时预算插件，关联工作室价格表。
6. 保持插件窗口打开，用吸管选择需要计价的材质。
7. 检查匹配结果，对未匹配材料人工确认关联。
8. 查看预算、设置基准或总预算，并导出 CSV。

## 环境与兼容性

| 项目 | 说明 |
| --- | --- |
| 宿主软件 | SketchUp 桌面版 |
| 最低兼容目标 | SketchUp 2020 |
| 当前主要使用环境 | Windows |
| 安装格式 | RBZ |
| 价格数据 | Excel / CSV |
| AI 功能 | 可选 DeepSeek API |
| 静态兼容检查 | 已完成 |
| SketchUp 2020 实机测试 | 待补充 |

普通使用者通过 RBZ 安装即可。开发检查脚本所需的 Node.js 不属于插件日常使用依赖。

## AI 与数据处理

模型几何、面积计算和预算汇总在本地处理。

启用 DeepSeek 时，会发送待匹配的 SU 材质名称，以及候选材料的编码、名称、分类和别名。当前推荐请求不包含模型几何或项目总预算。

API Key 仅保存在本次 SketchUp 运行内存中，不写入模型、价格表、词库或导出文件。

AI 不负责生成单价，也不负责计算面积。推荐的材料关联需要人工确认；API 不可用时，可继续使用本地候选、人工关联和预算功能。

## 常见问题

### 必须把 SU 材质名称改成标准材料名称吗？

不需要。可以保留原有名称，通过人工确认建立与标准材料的关联。

### 必须使用 DeepSeek 吗？

不需要。DeepSeek 是可选推荐功能，面积计算、价格匹配、人工关联、费用汇总和导出不依赖 AI 推荐。

### 正反面使用同一种材质会计算两次吗？

同一个 Face 只计算一次。正面有材质时优先使用正面，否则读取背面。

如果模型内外表皮由两个独立 Face 构成，则不能仅凭材质相同认定它们是同一个面。

### 被挡住的面都会自动排除吗？

不会。当前主要扣除共面接触交集，并处理同一面的重复计价。被相机遮挡、位于内部或发生非共面穿插，不一定符合当前扣除规则。

### 为什么预算里出现 0 元？

可能是材料尚未确认关联，或价格库中的单价为零。应先处理界面提示，再判断预算是否完整。

### 为什么不能直接用于工程结算？

插件以模型表面面积和价格库为基础，服务于方案阶段预估。实际结算还涉及工程量规则、施工做法、合同范围及其他费用，需要专业复核。

## 技术栈

- 插件逻辑：Ruby、SketchUp Ruby API。
- 交互界面：UI::HtmlDialog、HTML、CSS、JavaScript。
- 几何处理：实例变换、面面积计算、三角剖分、二维投影与多边形裁剪。
- 数据存储：SketchUp AttributeDictionary、JSON、CSV。
- 价格接入：Excel/CSV 价格库。
- AI 推荐：DeepSeek API。
- 静态兼容检查：Node.js。

## 验证与使用边界

已完成安装包结构、前端语法、部分 Ruby/JavaScript 兼容性，以及关键功能流程的静态检查。

仍需补充 SketchUp 2020 实机端到端测试，以及不同项目规模下的计量误差、耗时和用户反馈记录。

插件当前主要适用于以面积计价的材料预估，尚不能覆盖全部工程专业与计量单位。复杂空间穿插、异常面朝向和特殊构造需要人工检查。

示例价格用于演示数据结构与操作流程。真实项目应替换为经过工作室审核、适用于当地和当期的价格数据。

## 许可说明

当前仓库尚未加入明确的开源许可证。源码公开展示不等同于已经授予开源使用许可，复制、修改和分发的授权范围需由项目作者补充明确。

SketchUp、DeepSeek 及其他第三方软件或服务分别适用其自身条款。模型、价格数据和截图的使用授权也需分别确认。

## 致谢

感谢工作室在实际使用中提出的反馈，让项目从基础面积预算逐步发展到价格库关联、预算比较与 AI 辅助材料匹配。

项目说明的章节组织与图文展示参考了 OOOSplat 的 README 形式，功能介绍与迭代记录围绕本插件的实际开发过程整理。
