# AGENTS.md

本仓库的 OpenCode 指令文件。跨项目通用规则(禁令、GitHub Flow 基础约定)在 `~/.config/opencode/AGENTS.md`,本文件只记仓库特有内容。原 `CLAUDE.md` 已降级为指向本文件的指针。

## 仓库是什么

- 第一因(ADR-0001):**不是学手写 HarmonyOS/ArkTS,而是打磨 vibe coding 式人机协作流程**——AI 是实现者,人类练的是驾驭流程。提流程/工具/机制改动前必须先读 `docs/adr/0001`、`docs/adr/0002`。
- 唯一应用工程:`xupin/` —— 序拼(XùPīn),HarmonyOS 本地输入法(核心能力:序列预测)。动手前读 `CONTEXT.md` 领域术语表,**输出中使用它的词汇,避开它明确列出的同义词**;`docs/adr/0003`(IME 架构/安全模式)、`0004`(词典数据来源/协议)适用于该工程。

## 查 HarmonyOS API:本地语料优先,不凭记忆编造

- **首选 `docs/harmonyos-guides/`**(约 5500 页商用文档,与本机 DevEco Studio/SDK 版本对应;用 `sitemap.json` 检索落盘路径)。查不到再查 `~/Documents/HarmonyOSDocs`(OpenHarmony 开源文档,不在本仓库)。详见 `docs/README.md`。
- `docs/harmonyos-guides/` 被 `.gitignore` 排除(~2G 本地参考语料,非协作源码),**不要因为它没推送到远端就尝试取消忽略**。
- 该语料只在本机 → 它是排名第一的证据来源(见 ADR-0002),session 必须在同步过这份语料的机器上运行;没有语料的机器上先补齐再实现,不要退化成"文档缺失就跳过"。

## 构建与测试(仅 `xupin/`,仓库根目录无统一构建脚本)

DevEco Studio 自带的命令行工具链已验证可脱离 GUI 使用:

```bash
cd xupin
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw test
```

- **坑(已实测)**:`hvigorw test` 输出 `BUILD SUCCESSFUL` ≠ 测试全过——hypium 断言失败只打 `ERROR: ...` 行,构建任务仍成功收尾。**每次必须 grep 输出里的 `ERROR:`,不能只看最后一行。**
- `hdc` 已在 PATH;真机运行日志:`hdc shell hilog | grep XupinIME`。
- **真机操作人工专属**(ADR-0002):部署、切换系统默认输入法、点按/输入实测一律由人类执行,agent 只给"改哪里/为什么"和"预期看到什么"。`hvigorw test` 纯逻辑单测不在此限。

## 协作流程(细则以 ADR-0002 为准,与本文件冲突时以 ADR 为准)

- `main` 受分支保护:必须走 PR、禁直推/强推,对 admin 同样生效。仓库为 **public**——免费 private 仓库无分支保护,这是刻意的取舍,不是疏忽。
- **Dispatch 默认人工**:不自动派发 subagent 实现 issue,除非人类显式批准。
- **合并默认 AI 自主**(覆盖全局"人类在网页合并"的默认,本仓库特例):验收通过即可合并;仅当 PR 触及 ① 机制文件(`AGENTS.md`/`CLAUDE.md`/`docs/adr/*`/`docs/agents/*`)或 ② 安全/不可逆内容时,打 `ready-for-human` 交人类合并。
- **证据优先级**:`docs/harmonyos-guides/` 等官方文档 > issue/PRD > AI 自主补充。issue 与官方文档冲突时以文档为准,并在 PR 中**显式标注偏离**,不悄悄照做也不悄悄改写 issue。

## Issue 与标签

- Issue tracker = GitHub Issues,一律用 `gh` CLI,约定见 `docs/agents/issue-tracker.md`。
- 标签用默认的 2 分类(`bug`/`enhancement`)+ 5 状态(`needs-triage`/`needs-info`/`ready-for-agent`/`ready-for-human`/`wontfix`),见 `docs/agents/triage-labels.md`。
- 领域文档单上下文布局:`CONTEXT.md` + `docs/adr/`,索引见 `docs/agents/domain.md`;输出与 ADR 冲突时显式提出,不静默覆盖。
