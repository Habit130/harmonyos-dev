# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

本仓库的第一因(见 [`docs/adr/0001-founding-rationale-and-division-of-labor.md`](docs/adr/0001-founding-rationale-and-division-of-labor.md)):**不是让人类学会手写 HarmonyOS/ArkTS 代码,而是构建并打磨一套 vibe coding 式的人机协作开发流程——以 AI 为实现者产出真实可运行的 HarmonyOS 应用,人类精进的是驾驭这套协作流程(全局约束设定、设计讨论、GitHub Flow)的能力。** 当前仓库的核心资产是本地沉淀的官方文档语料(`docs/harmonyos-guides/`),为 AI 实现提供准确的 API 依据;目前仓库内还没有任何应用代码或构建工程。

## Documentation architecture

仓库同时对应两套文档源,定位不同,查资料时先判断查哪套(完整说明见 `docs/README.md`):

- **`docs/harmonyos-guides/`**(纳入本 git 仓库)—— 华为商用 HarmonyOS 开发文档,抓取自 `developer.huawei.com/consumer/cn/doc/harmonyos-guides/application-dev-guide`,按官网左侧导航的分类层级组织目录(`分类/子分类/.../页面标题.md`),页面配图已本地化到同名 `.assets/` 目录。规模约 5500 页 / 2.0G,涵盖入门指南、应用框架、系统能力、各 Kit 概念说明以及全量 API 参考。**涉及具体 API、DevEco Studio 操作、Kit 用法时优先查这里**——和本机实际安装的 DevEco Studio / SDK 版本对应。
  - `docs/harmonyos-guides/sitemap.json` —— 抓取时生成的完整目录树 + 页面列表(含每页落盘路径),重新抓取/增量更新时复用它可跳过展开导航树的步骤。
  - `docs/harmonyos-guides/crawl.log` —— 抓取过程日志。
- **OpenHarmony 开源文档**(不在本仓库内)—— 来自 `gitee.com/openharmony/docs`,本地路径在 `~/Documents/HarmonyOSDocs`(约 4.6G,浅克隆,未纳入本仓库),作架构原理、开源实现细节的补充参考,商用文档没覆盖到的概念可以来这里找。

**回答 HarmonyOS API 相关问题时,先查 `docs/harmonyos-guides/`,查不到再查 OpenHarmony 文档;不确定的 API 不要凭记忆编造。**

> 注意:`docs/harmonyos-guides/` 只在本地保留,已通过 `.gitignore` 排除,不会推送到 GitHub remote(体积约 2G,属于本地参考语料,不是团队协作的源码)。不要因为 `git push` 看不到这些文件就尝试取消忽略它们。

## Project conventions

- 练手/应用工程按独立子目录组织,各自使用自己的 DevEco Studio / hvigor 构建配置;仓库根目录不提供统一的构建/测试命令,不要假设存在根级构建脚本。构建、运行、测试命令以具体工程子目录内的说明为准。

## Development workflow

本仓库(以及后续在此基础上开发的应用工程)遵循 **GitHub Flow**,人机分工细则见 [`docs/adr/0002-github-flow-collaboration-mechanics.md`](docs/adr/0002-github-flow-collaboration-mechanics.md):

- `main` 分支始终保持可运行/可部署状态,不直接在 `main` 上开发。**`main` 已配置分支保护:禁止直接推送,必须走 PR**;没有配置"必须 approval"(单账号自审无法自我批准,配了会死锁)——review 实质发生在强 agent/`advisor` 层,不是 GitHub 原生多人 review,见 ADR-0002。
- 主干:人类给方向 → grilling 讨论定设计/约束 → 写入 PRD/issue → 人类手动把 issue 分派给"弱 session"实现并开 PR → "强 agent"(主 session)验收。issue 粒度与分支/PR 不强制一一对应。
- **Dispatch 默认人工**:强 agent 不自动派发 subagent 完成 issue,除非人类显式批准(如 "ultracode" 模式)。
- **合并默认 AI 自主**:强 agent 验收通过即可直接合并、关闭 PR,无需人类点头;只有 PR 触及「仓库自身运行机制文件(`CLAUDE.md`/`docs/adr/*`/`docs/agents/*`/workflow 定义)」或「安全/不可逆内容」这两类之一时,才打 `ready-for-human` 交给人类合并。
- **证据优先级**:`docs/harmonyos-guides/` 等官方文档 > 人类与 AI 讨论出的 issue/PRD > AI 自主细粒度补充。issue 与官方文档冲突时以文档为准,并在 PR 中显式标注偏离,不悄悄照做也不悄悄改写 issue。**一级证据只在本机**(该语料 gitignore、不推送),弱/强 session 必须在同步过这份语料的机器上运行。
- 合并后删除该功能分支。
- **有意推迟、非遗漏**:commit message 规范、PR 描述模板、CI/自动化检查、weak session 的 handoff prompt 格式,留到第一个真实 issue 出现时再定(`to-prd`/`to-issues` 已自带 PRD/issue 模板可直接复用)。ADR 修订机制本身就是处理这类后续问题的入口,不代表现在没想清楚。

## Agent skills

### Issue tracker

Issues 用 GitHub Issues(`gh` CLI),仓库 `github.com/Habit130/harmonyos-dev` 为 **public**(免费版 private 仓库不支持分支保护,为了让"禁止直推 main"技术强制而非只靠约定,改为公开);不把外部 PR 当作 triage 入口(个人学习仓库,无外部协作者)。见 `docs/agents/issue-tracker.md`。

### Triage labels

沿用标准的 2 个分类角色(`bug` / `enhancement`)+ 5 个状态角色(`needs-triage` / `needs-info` / `ready-for-agent` / `ready-for-human` / `wontfix`)默认标签字符串,尚未做仓库特定的改名映射。见 `docs/agents/triage-labels.md`。

### Domain docs

单一上下文(single-context)布局。`CONTEXT.md` 已建立,收录序拼(XùPīn,仓库第一个应用工程)的领域术语;`docs/adr/` 已有 `0001`(第一因与人机分工总纲)、`0002`(GitHub Flow 协作机制细则)——两者适用于仓库里几乎所有工作,动手前先读——以及 `0003`(输入法应用架构与安全模式)、`0004`(词典数据来源与协议),适用于序拼应用的具体实现。见 `docs/agents/domain.md`。
