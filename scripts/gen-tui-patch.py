# gen-tui-patch.py -- emit scripts/patch-tui-zh.mjs from the pairs we already
# shipped plus this round's additions.
#
# Why a generator instead of hand-writing the table: the 75 keybinding strings
# were extracted by diffing the live Chinese bundle against the pristine one
# (see zh-pairs.json), and replaying them by hand through a console that mangles
# CJK is how a table gets silently corrupted. This reads them from the file, and
# bakes each entry's occurrence count in the pristine bundle into the emitted
# script, so a future upstream rename fails loudly instead of half-applying.
#
# Run:  python gen-tui-patch.py

import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                      # 仓库根
PRISTINE = os.environ.get('DSH_TUI_PRISTINE', '') # 原包：pnpm 装着的那份 lib/index.js
PAIRS = os.path.join(HERE, 'tui-zh-pairs.json')   # 已上机的 75 条，从 bundle diff 反推
OUT = os.path.join(HERE, 'patch-tui-zh.mjs')

# This round's additions, on top of the extracted pairs.
BATCH_B = [
    # slash-command descriptions (visible in /help and in autocomplete)
    ('description: "Clear the transcript view (session history is unchanged)"', 'description: "清屏（会话历史不变）"'),
    ('description: "Select tool-card, reasoning, and context display"', 'description: "设置工具卡片 / 思考 / 上下文的显示"'),
    ('description: "Toggle conversation-only view and restore the prior details"', 'description: "只看对话，再按一次恢复"'),
    ('description: "Browse full tool-card details without changing the transcript"', 'description: "浏览完整工具卡片（不改动记录）"'),
    ('description: "Browse direct child agents and read-only transcripts"', 'description: "浏览子代理与只读记录"'),
    ('description: "Show every color and attribute role this terminal renders"', 'description: "显示终端能渲染的颜色与属性"'),
    ('description: "EXPERIMENTAL (dev): re-read loader config files and apply the diff (idle only)"', 'description: "实验：重读加载器配置并应用（仅空闲时）"'),
    ('description: "Show session diagnostics, system prompt, and registered tools"', 'description: "显示会话诊断、系统提示词、已注册工具"'),

    # /status card
    ('["Session", displayText(agent.session.id)]', '["会话", displayText(agent.session.id)]'),
    ('["Title", displayText(sessionTitle ?? "untitled")]', '["标题", displayText(sessionTitle ?? "未命名")]'),
    ('["Directory", displayText(cwd)]', '["目录", displayText(cwd)]'),
    ('["Permission", displayText(permissionController.current())]', '["权限", displayText(permissionController.current())]'),
    ('[["Agent", [', '[["代理", ['),
    ('formatDiagnosticCount(events.length, "event")', 'formatDiagnosticCount(events.length, "事件")'),
    ('formatDiagnosticCount(turns, "turn")', 'formatDiagnosticCount(turns, "回合")'),
    ('formatDiagnosticCount(steps, "step")', 'formatDiagnosticCount(steps, "步")'),
    ('formatDiagnosticCount(toolCalls, "tool call")', 'formatDiagnosticCount(toolCalls, "工具调用")'),
    ('["Tokens", ', '["令牌", '),
    ('} input + ${formatDiagnosticNumber(tokens.output)} output`', '} 输入 + ${formatDiagnosticNumber(tokens.output)} 输出`'),
    ('["KV cache", ', '["KV 缓存", '),
    (' read + ${formatDiagnosticNumber(tokens.cacheWrite)} write', ' 读 + ${formatDiagnosticNumber(tokens.cacheWrite)} 写'),
    ('% hit (', '% 命中 ('),
    (' used \u00b7 capacity unknown', ' 已用 \u00b7 容量未知'),
    ('}% used (${', '}% 已用 (${'),
    ('["Created", formatDiagnosticTime(agent.session.header.createdAt)]', '["创建于", formatDiagnosticTime(agent.session.header.createdAt)]'),
    ('["Active", formatDiagnosticTime(latestActivity)]', '["最近活动", formatDiagnosticTime(latestActivity)]'),
    ('palette.accent("System prompt")', 'palette.accent("系统提示词")'),
    ('palette.accent("Registered tools")', 'palette.accent("已注册工具")'),
    ('["Model", `${model} ${palette.dim(', '["模型", `${model} ${palette.dim('),
    ('(effort ${effort}; reasoning ${reasoningFold})', '(档位 ${effort} \u00b7 思考 ${reasoningFold})'),
    ('target.current === void 0 ? "unset" : displayText(targetLabel(target.current))', 'target.current === void 0 ? "未设置" : displayText(targetLabel(target.current))'),
    ('target.current.reasoningEffort === void 0 ? "default" :', 'target.current.reasoningEffort === void 0 ? "默认" :'),

    # prompt line / status line
    ('"Enter submit"', '"回车发送"'),
    ('"Esc interrupt"', '"Esc 打断"'),
    ('"Runtime Dashboard"', '"运行面板"'),
    ('"Context compacted"', '"上下文已压缩"'),
    ('Context being compacted ${formatStatusDuration(', '正在压缩上下文 ${formatStatusDuration('),

    # notices
    ('"No tool cards in this session."', '"本会话没有工具卡片。"'),
    ('"No matching sessions."', '"没有匹配的会话。"'),
    ('"No child agents to view."', '"没有可查看的子代理。"'),
    ('"Child transcript could not be loaded."', '"子代理记录读取失败。"'),
    ('"Copy failed"', '"复制失败"'),
    ('"Permission change failed."', '"权限切换失败。"'),
    ('"No matches"', '"无匹配"'),
    ('"Keyboard shortcuts"', '"快捷键"'),
    ('"Reasoning text"', '"思考内容"'),
]

# The /preset command. Kept as text so the emitted script carries it verbatim.
INSERT_BEFORE = '\t\tconst exitHandler = () => {'
INSERT_CODE = '''\t\t// /preset -- list presets or switch this session onto one.
\t\t//
\t\t// @deepseek-ai/dsh-agent-presets allows a session to change preset only
\t\t// while it is blank: once a turn has started the composition is mounted
\t\t// (its docs: "A session may still change preset while it is blank, and the
\t\t// effect of that change outlives the blank window"), and `select` then
\t\t// throws `agent-preset/locked`. So a locked session degrades to writing a
\t\t// marker file the launcher honours at the next start -- a preset change
\t\t// outliving the process is the only thing left that can work, and it beats
\t\t// telling the user to reinstall or to ask me to re-patch a file.
\t\tconst currentAgentPreset = () => {
\t\t\ttry {
\t\t\t\treturn ctx.get("sessionProjections")?.snapshot(agent.session)?.values?.agentPreset ?? null;
\t\t\t} catch {
\t\t\t\treturn null;
\t\t\t}
\t\t};
\t\tconst presetFiber = agent.ctx.inject(["agentPresets", "commands"], (presetCtx) => {
\t\t\tpresetCtx.commands.register({
\t\t\t\tname: "preset",
\t\t\t\tdescription: "查看或切换预设（未开跑的会话可原地切换）",
\t\t\t\tinput: {
\t\t\t\t\thint: "[id]"
\t\t\t\t},
\t\t\t\thandler: async ({ rawInput }) => {
\t\t\t\t\tconst service = presetCtx.agentPresets;
\t\t\t\t\tconst wanted = (rawInput ?? "").trim();
\t\t\t\t\tif (wanted === "") {
\t\t\t\t\t\tconst roster = await service.list();
\t\t\t\t\t\tconst current = currentAgentPreset();
\t\t\t\t\t\tconst rows = roster.map((preset) => {
\t\t\t\t\t\t\tconst marks = [];
\t\t\t\t\t\t\tif (preset.id === current) marks.push("当前");
\t\t\t\t\t\t\tif (preset.id === service.defaultId) marks.push("默认");
\t\t\t\t\t\t\tif (preset.broken !== void 0) marks.push("不可用");
\t\t\t\t\t\t\tconst name = preset.name === void 0 ? "" : `（${preset.name}）`;
\t\t\t\t\t\t\treturn `  ${preset.id}${name}${marks.length === 0 ? "" : `  [${marks.join(" / ")}]`}`;
\t\t\t\t\t\t});
\t\t\t\t\t\tappendNotice(`预设：\\n${rows.join("\\n")}\\n用法：/preset <id>`, "info");
\t\t\t\t\t\treturn { kind: "success" };
\t\t\t\t\t}
\t\t\t\t\ttry {
\t\t\t\t\t\tconst id = await service.select(agent, wanted);
\t\t\t\t\t\tappendNotice(`预设已切换为 ${id}，本轮起生效。`, "info");
\t\t\t\t\t\treturn { kind: "success" };
\t\t\t\t\t} catch (error) {
\t\t\t\t\t\tconst text = String(error?.message ?? error);
\t\t\t\t\t\tif (text.includes("already started") || text.includes("locked")) {
\t\t\t\t\t\t\ttry {
\t\t\t\t\t\t\t\twriteFileSync(dshHomePath(".pending-preset"), `${wanted}\\n`);
\t\t\t\t\t\t\t\tappendNotice(`本会话已开跑，预设已锁定。已记为下次启动生效：${wanted}\\n输入 /exit，重启后即以该预设开新会话。`, "warning");
\t\t\t\t\t\t\t} catch (writeError) {
\t\t\t\t\t\t\t\tappendNotice(`切换预设失败：${text}`, "error");
\t\t\t\t\t\t\t}
\t\t\t\t\t\t\treturn { kind: "success" };
\t\t\t\t\t\t}
\t\t\t\t\t\tappendNotice(`切换预设失败：${text}`, "error");
\t\t\t\t\t\treturn { kind: "success" };
\t\t\t\t\t}
\t\t\t\t}
\t\t\t});
\t\t});
'''

DISPOSAL_FROM = 'commandFiber.dispose(), fileReferencePromptFiber.dispose()'
DISPOSAL_TO = 'commandFiber.dispose(), fileReferencePromptFiber.dispose(), presetFiber.dispose()'


def occurrences(haystack, needle):
    return haystack.count(needle)


def js(value):
    return json.dumps(value, ensure_ascii=False)


def main():
    pristine = open(PRISTINE, encoding='utf-8').read()
    pairs = json.load(open(PAIRS, encoding='utf-8'))

    entries = []
    missing = []
    seen = set()

    def add(batch, old, new):
        """One entry per source text.
        /exit and /quit share a description, so the line diff lists that pair
        twice -- and the second copy would then match nothing, because the first
        one already rewrote both occurrences. Deduplicating here is what keeps
        the baked-in count honest; the patcher reports the conflict otherwise."""
        if old in seen:
            return
        n = occurrences(pristine, old)
        if n == 0:
            missing.append((batch, old))
            return
        seen.add(old)
        entries.append((old, new, n))

    # Batch A: the pairs already live on the device, counted, not retyped.
    for old, new in pairs:
        add('A', old, new)

    # Batch B: this round's additions.
    for old, new in BATCH_B:
        add('B', old, new)

    if missing:
        print('!! %d 条锚点在原包里找不到，已跳过（需要修正）:' % len(missing))
        for batch, text in missing:
            print('   [%s] %s' % (batch, text[:120]))
    else:
        print('全部锚点命中')

    if occurrences(pristine, INSERT_BEFORE) != 1:
        raise SystemExit('插入锚点不是唯一的: %r' % INSERT_BEFORE)
    if occurrences(pristine, DISPOSAL_FROM) != 2:
        raise SystemExit('dispose 锚点数量不是 2')

    body = []
    for old, new, n in entries:
        body.append('\t{ from: %s, to: %s, expect: %d },' % (js(old), js(new), n))

    text = TEMPLATE
    for token, value in (
        ('@@TABLE@@', '\n'.join(body)),
        ('@@INSERT_ANCHOR@@', js(INSERT_BEFORE)),
        ('@@INSERT_CODE@@', js(INSERT_CODE)),
        ('@@DISPOSAL_FROM@@', js(DISPOSAL_FROM)),
        ('@@DISPOSAL_TO@@', js(DISPOSAL_TO)),
    ):
        text = text.replace(token, value)
    if '@@' in text:
        raise SystemExit('模板里还有未替换的 token')
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, 'w', encoding='utf-8', newline='\n').write(text)
    print('已写出 %s（%d 条替换）' % (OUT, len(entries)))


TEMPLATE = '''#!/usr/bin/env node
// patch-tui-zh.mjs -- make @brianynwu/dsh-tui's bundle Chinese, and add /preset.
//
// The TUI ships no i18n at all (no locale table, no zh- entries): its strings
// are literals inside the bundle, so translating it means rewriting those
// literals. This script is the single source of truth for that rewrite. It is
// generated by phone-diag/gen-tui-patch.py and committed, so the transformation
// is reviewable and repeatable instead of being an ad-hoc console command that
// nobody can replay.
//
// Two rules it enforces, because a half-applied table is worse than none:
//   * every entry names how many times its source text must appear, and any
//     mismatch fails the run (that is how an upstream rename shows up);
//   * nothing is written unless the whole table applies.
//
// Usage:
//   node scripts/patch-tui-zh.mjs <pristine lib/index.js> <output lib/index.js>
//
// Verify afterwards with `node --check <output>`.

import { readFileSync, writeFileSync } from "node:fs";

/** Every string this rewrite replaces, with the count it must match. */
const TABLE = [
@@TABLE@@
];

/** The /preset command, inserted before the exit handler that follows it. */
const INSERT_ANCHOR = @@INSERT_ANCHOR@@;
const INSERT_CODE = @@INSERT_CODE@@;

/** Both disposal sites dispose the TUI's fibers together. */
const DISPOSAL_FROM = @@DISPOSAL_FROM@@;
const DISPOSAL_TO = @@DISPOSAL_TO@@;

const [input, output] = process.argv.slice(2);
if (input === undefined || output === undefined) {
	process.stderr.write("usage: patch-tui-zh.mjs <input index.js> <output index.js>\\n");
	process.exit(2);
}

let source = readFileSync(input, "utf8");
const failures = [];
let applied = 0;

for (const entry of TABLE) {
	const count = source.split(entry.from).length - 1;
	if (count !== entry.expect) {
		failures.push(`  ${JSON.stringify(entry.from.slice(0, 90))}: 期望 ${entry.expect} 处，实际 ${count} 处`);
		continue;
	}
	source = source.split(entry.from).join(entry.to);
	applied += 1;
}

for (const { id, from, to, expect } of [
	{ id: "insert /preset", from: INSERT_ANCHOR, to: null, expect: 1 },
	{ id: "dispose presetFiber", from: DISPOSAL_FROM, to: DISPOSAL_TO, expect: 2 }
]) {
	const count = source.split(from).length - 1;
	if (count !== expect) {
		failures.push(`  ${id}: 期望 ${expect} 处，实际 ${count} 处`);
		continue;
	}
	if (to === null) {
		source = source.replace(from, `${INSERT_CODE}${from}`);
	} else {
		source = source.split(from).join(to);
	}
	applied += 1;
}

if (failures.length > 0) {
	process.stderr.write(`patch-tui-zh: ${failures.length} 项未命中，未写出任何文件：\\n${failures.join("\\n")}\\n`);
	process.exit(1);
}

writeFileSync(output, source);
process.stdout.write(`patch-tui-zh: 已应用 ${applied} 项（替换 ${TABLE.length} + 插入 2），写出 ${output}\\n`);
'''


if __name__ == '__main__':
    main()
