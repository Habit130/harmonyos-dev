# HarmonyOS 开发文档 —— 本地索引与阅读目录

本仓库本地沉淀了两套文档,定位不同,查资料时按下表判断先查哪套:

| | 商用 HarmonyOS 文档 | 开源 OpenHarmony 文档 |
|---|---|---|
| 目录 | `docs/harmonyos-guides/` | 见下方"OpenHarmony 开发文档"章节,实体在 `~/Documents/HarmonyOSDocs` |
| 来源 | developer.huawei.com(华为商用发行版) | gitee.com/openharmony/docs(开源基座) |
| 适用场景 | **涉及具体 API、DevEco Studio 操作、Kit 用法时优先查这里**——和本机实际安装的 DevEco Studio / SDK 对应 | 架构原理、开源实现细节的补充参考;商用文档没覆盖到的概念可以来这里找 |

**涉及 HarmonyOS API 时,优先查 `docs/harmonyos-guides/`,不确定的 API 不要凭记忆编造。**

## 商用 HarmonyOS 开发文档(`docs/harmonyos-guides/`)

- 来源:`https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/application-dev-guide` 左侧导航树下的全部页面
- 抓取结果直接落盘在本仓库,按官网左侧导航的分类层级组织目录(`分类/子分类/.../页面标题.md`),页面正文自带的截图/配图已下载到同名 `.assets/` 目录并改写为相对路径引用(原图为带 24 小时过期签名的 CDN 链接,不本地化会在一天内全部失效)。抓取脚本当前未纳入本仓库;如需重新抓取或增量更新,需要另行编写抓取工具。
- `docs/harmonyos-guides/sitemap.json`:抓取时生成的完整目录树 + 页面列表(含每个页面的落盘路径),重新抓取或增量更新时复用这份文件即可跳过"展开导航树"这一步。
- `docs/harmonyos-guides/crawl.log` / `crawl_errors.log`:抓取过程日志和失败页面记录(4xx/5xx 或抓取异常的页面会跳过并记录,不影响其余页面)。
- 规模较大:导航树下 **5504 个去重页面全部抓取成功,0 失败**,共约 2.0G(含 6400+ 张本地化的配图),涵盖入门指南、应用框架、系统能力、各 Kit 概念说明**以及全量 API 参考**。其中相当一部分是逐接口/逐参数级别的 API 参考(尤其 AI 分类下的 CANN Kit,约占 845 页),日常学习不需要通读,查具体 API 时按需检索即可。

## OpenHarmony 开发文档

### 文档来源

- 仓库:`https://gitee.com/openharmony/docs.git`
- 本地路径:`~/Documents/HarmonyOSDocs`(未纳入本 git 仓库,体积约 4.6G,浅克隆 `--depth 1`)
- 当前版本:`master` 分支,commit `b8477987`(2026-04-27)

更新文档:

```bash
cd ~/Documents/HarmonyOSDocs && git fetch --depth 1 origin master && git reset --hard origin/master
```

> 浅克隆没有完整历史,常规 `git pull` 在上游有强推/整理历史时可能失败,统一用上面的 `fetch --depth 1` + `reset --hard` 方式更新。

下文所有路径均相对于 `~/Documents/HarmonyOSDocs`。文档本身自带逐级 `Readme-CN.md` 作为官方目录(供工具链生成侧边栏用),下面是按本仓库学习目标(ArkTS / ArkUI / Stage 模型应用开发)整理的精简阅读路径,入口链接到官方目录,不重复罗列全部文件。

### 总目录入口

- 中文文档总入口:`zh-cn/readme.md`
- 应用开发总目录(最常用):`zh-cn/application-dev/Readme-CN.md`
- 设备开发总目录:`zh-cn/device-dev/Readme-CN.md`
- API 参考总目录:`zh-cn/application-dev/reference/Readme-CN.md`
- 贡献指南 / 编码规范:`zh-cn/contribute/`

### 推荐阅读路径

#### 1. 项目认知
- `zh-cn/OpenHarmony-Overview_zh.md` —— OpenHarmony 项目总览
- `zh-cn/glossary.md` —— 术语表

#### 2. 入门
- `zh-cn/application-dev/quick-start/Readme-CN.md`(该目录官方目录,按顺序读)
  - `start-overview.md` 开发准备
  - `start-with-ets-stage.md` 构建第一个 ArkTS 应用(Stage 模型)
  - `arkts-get-started.md`、`introduction-to-arkts.md` —— ArkTS 语言入门
  - `arkts-coding-style-guide.md` —— ArkTS 编码规范

#### 3. 应用结构与配置文件
- `quick-start/application-package-overview.md` 应用包概述
- `quick-start/application-package-structure-stage.md` Stage 模型包结构
- `quick-start/app-configuration-file.md`(app.json5)
- `quick-start/module-configuration-file.md`(module.json5)

#### 4. Stage 模型与 Ability(应用框架核心)
- `zh-cn/application-dev/application-models/Readme-CN.md`(官方目录)
- `application-models/application-models.md` 应用模型总览
- `application-models/abilitystage.md`、`application-context-stage.md`

#### 5. ArkUI 界面开发
- `zh-cn/application-dev/ui/Readme-CN.md`(官方目录)
- `ui/arkts-ui-development-overview.md` UI 开发总览
- `ui/state-management/` 状态管理(声明式 UI 核心概念)
- `ui/arkts-layout-development-overview.md` 布局开发总览

#### 6. 常用能力 Kit(按需查阅)
入口统一在 `application-dev/Readme-CN.md` 的"开发"章节,按分类索引到各 Kit 的 `Readme-CN.md`,常用的有:
- `database/Readme-CN.md` ArkData 数据管理
- `network/Readme-CN.md` 网络服务
- `file-management/Readme-CN.md` 文件服务
- `notification/Readme-CN.md` 通知服务
- `security/` 安全能力

#### 7. API 参考
- `zh-cn/application-dev/reference/Readme-CN.md`
- 各 Kit 对应 `reference/apis-*-kit/`,如 `reference/apis-arkui`、`reference/apis-ability-kit`

#### 8. 设备开发(可选,非当前学习重点)
- `zh-cn/device-dev/Readme-CN.md`

#### 9. 编码规范 / 贡献
- `zh-cn/contribute/OpenHarmony-Application-Typescript-JavaScript-coding-guide.md`
- `zh-cn/contribute/OpenHarmony-JavaScript-docs-guide.md`

## 使用约定

- 回答 HarmonyOS API 相关问题时,先查 `docs/harmonyos-guides/`,查不到再查 OpenHarmony 文档,不确定的 API 不要凭记忆编造。
- `docs/harmonyos-guides/` 只在本地保留,已通过 `.gitignore` 排除,不会推送到 GitHub remote(体积较大,属于本地参考语料);`~/Documents/HarmonyOSDocs`(OpenHarmony)同样不在任何 git 追踪范围内。两者都建议过一段时间重新抓取/拉取以保持最新。
