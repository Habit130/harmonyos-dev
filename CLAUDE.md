# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

HarmonyOS(鸿蒙)应用开发学习与实践仓库。当前仓库的核心资产是本地沉淀的官方文档语料(`docs/harmonyos-guides/`),供后续在此基础上构建实际的 HarmonyOS/ArkTS 应用工程。目前仓库内还没有任何应用代码或构建工程。

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

本仓库(以及后续在此基础上开发的应用工程)遵循 **GitHub Flow**:

- `main` 分支始终保持可运行/可部署状态,不直接在 `main` 上开发。
- 新功能或修复从 `main` 切出一个描述性命名的分支(如 `feature/xxx`、`fix/xxx`)。
- 在分支上提交并推送;需要讨论或反馈时尽早开 PR(可以是 draft PR)。
- 通过评审(以及适用的检查)后合并回 `main`,合并方式不强制,以仓库当时的约定为准。
- 合并后删除该功能分支。

## Agent skills

### Issue tracker

Issues 用 GitHub Issues(`gh` CLI),仓库 `github.com/Habit130/harmonyos-dev` 为 **private**;不把外部 PR 当作 triage 入口(个人学习仓库,无外部协作者)。见 `docs/agents/issue-tracker.md`。

### Triage labels

沿用五个标准 triage 角色的默认标签字符串(`needs-triage` / `needs-info` / `ready-for-agent` / `ready-for-human` / `wontfix`),尚未做仓库特定的改名映射。见 `docs/agents/triage-labels.md`。

### Domain docs

单一上下文(single-context)布局:`CONTEXT.md` + `docs/adr/` 计划放在仓库根目录,目前尚未创建,由 `/domain-modeling` 在术语或架构决策实际出现时按需生成。见 `docs/agents/domain.md`。
