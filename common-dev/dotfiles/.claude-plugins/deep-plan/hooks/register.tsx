// deep-plan: Polytoken's plan and execute facets as a Claude Code mod.
//
// The facet lives in $.state and drives everything else: the system prompt
// section (prompt.compose), the read-only guards (tool.call), the plan tools
// (write_plan, edit_plan, handoff_plan), the compaction hint
// (session.compact), and the band above the prompt. Approving a plan with
// "clear context" swaps the transcript for the plan itself (a compaction this
// plugin answers) and starts the first execute turn.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { DeepPlanFacet, DeepPlanPlan } from '../types'
import { isReadOnlyCommand } from './bash'

type $ = EngineInterface

const facet = atom({ plugin: 'deep-plan', key: 'facet' } as const, 'off')
const plan = atom({ plugin: 'deep-plan', key: 'plan' } as const, null)
const isClearPending = atom({ plugin: 'deep-plan', key: 'isClearPending' } as const, false)
const isClearing = atom({ plugin: 'deep-plan', key: 'isClearing' } as const, false)

const WRITE_PLAN = 'mcp__deep-plan__write_plan' as const
const EDIT_PLAN = 'mcp__deep-plan__edit_plan' as const
const HANDOFF_PLAN = 'mcp__deep-plan__handoff_plan' as const
const PLAN_TOOLS = [WRITE_PLAN, EDIT_PLAN, HANDOFF_PLAN] as const
const REVIEWER = 'deep-plan:plan-reviewer'

// Polytoken's tools_deny for the plan facet, in Claude Code's tool names.
const DENIED_IN_PLAN = [
  'Write', 'Edit', 'NotebookEdit', 'Monitor', 'TodoWrite', 'TaskCreate', 'TaskUpdate',
  'EnterPlanMode', 'ExitPlanMode', 'EnterWorktree',
] as const

const COMPACTION_HINTS: Record<Exclude<DeepPlanFacet, 'off'>, string> = {
  plan: 'This session is in read-only plan mode. Focus the summary on investigation findings, design decisions, unresolved questions, and the state of any plan document under development. Preserve what has been discovered about the codebase, which options were considered and rejected, and the rationale for the planned approach. Do not describe investigation steps as completed implementation work.',
  execute: "This session is implementing a plan in execute mode. Focus the summary on implementation progress: which plan steps are complete, which are in progress, and which remain. Preserve decisions or blockers encountered during implementation, the current state of files under modification, and how the work maps to the plan's acceptance criteria.",
}

const APPROVE_CLEAR = 'Approve, clear context'
const APPROVE_KEEP = 'Approve, keep context'
const REVISE = 'Revise'
const STOP = 'Stop'

const FACET_COLOURS: Record<Exclude<DeepPlanFacet, 'off'>, string> = {
  plan: '#64beff',
  execute: '#ffb955',
}

type Prompts = { planFacet: string; executeFacet: string; reviewer: string; bashJudge: string }

export const register: Register = on => {
  // Loaded at session.start (and again on every reload, which fires it anew).
  let prompts: Prompts | undefined

  on('session.start', async ($, e, next) => {
    prompts = await loadPrompts($)

    await $.tool.register({
      name: 'write_plan',
      description: 'Plan facet only. Write the complete handoff plan document, following the plan specification. The first call creates the plan file; later calls replace it in place. Returns the plan file path.',
      inputSchema: {
        type: 'object',
        properties: {
          title: { type: 'string', description: 'A short title for the plan; names the file on the first write.' },
          content: { type: 'string', description: 'The whole plan document, in Markdown.' },
        },
        required: ['title', 'content'],
      },
    })
    await $.tool.register({
      name: 'edit_plan',
      description: 'Plan facet only. Replace an exact string in the current plan document, as the Edit tool does for files.',
      inputSchema: {
        type: 'object',
        properties: {
          old_string: { type: 'string', description: 'The exact text to replace; must be unique unless replace_all is set.' },
          new_string: { type: 'string', description: 'The text to replace it with.' },
          replace_all: { type: 'boolean', description: 'Replace every occurrence.' },
        },
        required: ['old_string', 'new_string'],
      },
    })
    await $.tool.register({
      name: 'handoff_plan',
      description: 'Plan facet only. Submit the current plan for operator approval. Call it by itself once the plan is written and the review loop is done, then follow the instruction in its result.',
      inputSchema: {
        type: 'object',
        properties: {
          summary: { type: 'string', description: 'Two or three sentences: what the plan does, and how review findings were resolved or rebutted.' },
        },
        required: ['summary'],
      },
    })

    const available = new Set((await $.tool.list()).map(tool => tool.name))
    await $.agent.register({
      name: 'plan-reviewer',
      description: 'Review a handoff plan written in plan facet before handoff_plan. Checks the plan shape, inspects relevant code and project context, and returns severity-classified findings that must be fixed or rebutted. The prompt must give the plan file path, the user\'s request, and the key files or systems already inspected.',
      prompt: prompts.reviewer,
      tools: ['Read', 'Grep', 'Glob', 'Bash', 'WebSearch', 'WebFetch'].filter(tool => available.has(tool)),
      model: 'opus',
    })

    for (const command of [
      { name: 'deep-plan', description: 'Enter plan facet (read-only planning, ported from Polytoken)', argumentHint: '[what to plan]' },
      { name: 'facet', description: 'Show or switch the deep-plan facet', argumentHint: '[plan|execute|off]', immediate: true as const },
    ]) {
      try {
        await $.command.register(command)
      } catch (error) {
        $.ui.log(`could not register /${command.name}: ${String(error)}`)
      }
    }

    return next(e)
  })

  on('command.run', { command: 'deep-plan' }, async ($, e) => {
    await setFacet($, 'plan')
    await update($, plan, () => null)
    await update($, isClearPending, () => false)

    const request = (e.args ?? '').trim()
    if (request === '') return { text: 'Plan facet on. Describe what to plan or investigate.' }
    void $.prompt.submit({ text: request, asUser: true })
    return { text: 'Plan facet on.' }
  })

  on('command.run', { command: 'facet' }, async ($, e) => {
    const wanted = (e.args ?? '').trim()
    if (wanted === '') {
      const current = await read($, facet)
      const currentPlan = await read($, plan)
      return { text: `Facet: ${current}${currentPlan ? ` (plan: ${currentPlan.path})` : ''}` }
    }
    if (wanted !== 'plan' && wanted !== 'execute' && wanted !== 'off') {
      return { text: 'Usage: /facet [plan|execute|off]' }
    }
    await setFacet($, wanted)
    return { text: `Facet: ${wanted}` }
  })

  // The facet's instructions ride in the system prompt, after the cache
  // boundary, so they hold for every request and survive compaction. A
  // subagent's prompt is its own; the Agent check keeps the facet text off
  // any loop that cannot spawn agents, should a subagent's prompt be composed.
  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    if (prompts === undefined || !e.tools.includes('Agent')) return composed

    const current = await read($, facet)
    if (current === 'off') return composed

    const currentPlan = await read($, plan)
    const text =
      current === 'plan'
        ? prompts.planFacet
        : prompts.executeFacet.replaceAll('{{PLAN_PATH}}', currentPlan?.path ?? '(no plan file recorded)')
    return { sections: [...composed.sections, { id: 'deep-plan:facet', text, scope: 'session' }] }
  })

  on('tool.call', { tool: DENIED_IN_PLAN }, async ($, e, next) => {
    if ((await read($, facet)) !== 'plan') return next(e)
    return {
      deny: `${e.tool} is not available in plan facet, which is read-only. Use write_plan and edit_plan for the plan document; if this action is genuinely needed, explain why and ask the operator.`,
    }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if ((await read($, facet)) !== 'plan') return next(e)
    if (isReadOnlyCommand(e.command)) return next(e)

    const refusal = await judgeCommand($, prompts, e.command)
    if (refusal === undefined) return next(e)
    return { deny: `Plan facet is read-only, and this command was refused: ${refusal} If it is genuinely needed, explain why and ask the operator.` }
  }).catch(() => ({ deny: 'The plan facet could not check this command, so it was not run.' }))

  on('tool.call', { tool: PLAN_TOOLS }, async ($, e) => {
    if ((await read($, facet)) !== 'plan') {
      return { deny: `${e.tool} is only available in plan facet. The operator enters it with /deep-plan.` }
    }
    const input = e as unknown as Record<string, unknown>
    if (e.tool === WRITE_PLAN) return writePlan($, String(input.title ?? 'plan'), String(input.content ?? ''))
    if (e.tool === EDIT_PLAN) {
      return editPlan($, String(input.old_string ?? ''), String(input.new_string ?? ''), input.replace_all === true)
    }
    return handoffPlan($, String(input.summary ?? ''))
  })

  // Records which plan revision plan-reviewer last looked at, for handoff.
  on('tool.call', { tool: 'Agent' }, async ($, e, next) => {
    const reviewing = e.subagent_type === REVIEWER ? (await read($, plan))?.version : undefined
    const ran = await next(e)
    if (reviewing !== undefined && ran.deny === undefined && ran.isError !== true) {
      await update($, plan, current =>
        current === null ? null : { ...current, reviewedVersion: Math.max(current.reviewedVersion, reviewing) },
      )
    }
    return ran
  })

  on('turn.complete', async ($, e, next) => {
    const completed = await next(e)
    if (e.agentId === undefined && (await read($, isClearPending))) {
      await update($, isClearPending, () => false)
      // Outside this dispatch: the turn has to be over before it is compacted.
      $.clock.after(0, () => void clearAndExecute($))
    }
    return completed
  })

  on('session.compact', async ($, e, next) => {
    if (e.agentId !== undefined) return next(e)

    if (await read($, isClearing)) {
      const currentPlan = await read($, plan)
      const planText = currentPlan === null ? '' : await $.fs.read(currentPlan.path)
      return {
        messages: [
          {
            role: 'user' as const,
            text: `The operator approved the plan at ${currentPlan?.path ?? '(unknown path)'} and cleared the planning conversation so that implementation starts with a fresh context. The approved plan:\n\n${planText}`,
            toolUses: [],
          },
          { role: 'assistant' as const, text: 'Understood. I will implement the approved plan in execute facet.', toolUses: [] },
        ],
      }
    }

    const current = await read($, facet)
    if (current === 'off') return next(e)
    const instructions = [e.instructions, COMPACTION_HINTS[current]].filter(Boolean).join('\n\n')
    return next({ ...e, instructions })
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const current = await read($, facet)
    if (current === 'off' || e.props.hasSurvey) return next(e)

    const currentPlan = await read($, plan)
    const { Box, Text } = $.ui.resolve(e)
    const review =
      currentPlan === null || current !== 'plan'
        ? ''
        : currentPlan.reviewedVersion === currentPlan.version
          ? ' · reviewed'
          : ' · not reviewed'

    return (
      <Box paddingX={1}>
        <Text color={FACET_COLOURS[current]} bold>
          {current} facet
        </Text>
        <Text dimColor>
          {currentPlan === null ? '' : ` · ${currentPlan.path}`}
          {review}
        </Text>
      </Box>
    )
  })
}

async function loadPrompts($: $): Promise<Prompts> {
  const root = `${$.plugin.root}/prompts`
  // A repository's own .claude/plan-spec.md overrides the default, as
  // Polytoken's plan_spec_override does.
  const override = `${await $.session.root()}/.claude/plan-spec.md`
  const spec = await $.fs.read((await $.fs.exists(override)) ? override : `${root}/plan-spec.md`)
  const withSpec = (text: string) => text.replaceAll('{{PLAN_SPEC}}', spec.trim())

  return {
    planFacet: withSpec(await $.fs.read(`${root}/plan-facet.md`)),
    executeFacet: await $.fs.read(`${root}/execute-facet.md`),
    reviewer: withSpec(await $.fs.read(`${root}/plan-reviewer.md`)),
    bashJudge: await $.fs.read(`${root}/bash-judge.md`),
  }
}

async function setFacet($: $, next: DeepPlanFacet): Promise<void> {
  const previous = await read($, facet)
  if (previous === next) return
  await update($, facet, () => next)
  $.ui.toast(next === 'off' ? 'Left the facets' : `${next} facet`)
}

// The autonomous_hint judge: undefined when the command may run, else why not.
async function judgeCommand($: $, prompts: Prompts | undefined, command: string): Promise<string | undefined> {
  if (prompts === undefined) return 'the read-only check is not loaded yet.'
  const reply = await $.model.complete({
    model: 'haiku',
    system: prompts.bashJudge,
    prompt: `Working directory: ${await $.session.cwd()}\nCommand:\n${command}`,
    maxTokens: 100,
    timeoutMs: 20_000,
  })
  if (!reply.isAnswered) return `the read-only check could not run (${reply.reason}).`

  const verdict = reply.text.trim()
  if (verdict === 'ALLOW') return undefined
  return verdict.replace(/^DENY:?\s*/, '') || 'it is not read-only.'
}

async function configDirectory($: $): Promise<string> {
  const home = (await $.env.get('HOME')) ?? ''
  const configured = await $.env.get('CLAUDE_CONFIG_DIR')
  if (configured === undefined || configured === '') return `${home}/.claude`
  return configured.replace(/^~(?=\/|$)/, home)
}

async function writePlan($: $, title: string, content: string) {
  if (content.trim() === '') return { deny: 'write_plan needs the whole plan document as content.' }

  const current = await read($, plan)
  const path = current?.path ?? (await newPlanPath($, title))
  await $.fs.write(path, content)

  const written = await update($, plan, previous => ({
    path,
    version: (previous?.version ?? 0) + 1,
    reviewedVersion: previous?.reviewedVersion ?? 0,
  }))
  const version = written?.version ?? 1
  return {
    result: `Plan written to ${path} (revision ${version}). Review it with the ${REVIEWER} subagent, fix or rebut its findings with edit_plan, then call handoff_plan.`,
  }
}

async function newPlanPath($: $, title: string): Promise<string> {
  const date = new Date(await $.clock.now()).toISOString().slice(0, 10)
  const slug =
    title
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 60) || 'plan'

  const directory = `${await configDirectory($)}/plans`
  let path = `${directory}/${date}-${slug}.md`
  for (let suffix = 2; await $.fs.exists(path); suffix += 1) path = `${directory}/${date}-${slug}-${suffix}.md`
  return path
}

async function editPlan($: $, oldString: string, newString: string, isReplaceAll: boolean) {
  const current = await read($, plan)
  if (current === null) return { deny: 'There is no plan yet; write it with write_plan first.' }
  if (oldString === '') return { deny: 'edit_plan needs a non-empty old_string.' }

  const text = await $.fs.read(current.path)
  const count = text.split(oldString).length - 1
  if (count === 0) return { deny: 'old_string was not found in the plan.' }
  if (count > 1 && !isReplaceAll) {
    return { deny: `old_string occurs ${count} times in the plan; give more context or set replace_all.` }
  }

  await $.fs.write(current.path, isReplaceAll ? text.replaceAll(oldString, newString) : text.replace(oldString, newString))
  const edited = await update($, plan, previous => (previous === null ? null : { ...previous, version: previous.version + 1 }))
  return { result: `Plan updated (revision ${edited?.version ?? current.version + 1}).` }
}

async function handoffPlan($: $, summary: string) {
  const current = await read($, plan)
  if (current === null) return { deny: 'There is no plan to hand off; write it with write_plan first.' }

  const review =
    current.reviewedVersion === current.version
      ? 'plan-reviewer has reviewed this revision.'
      : current.reviewedVersion > 0
        ? 'plan-reviewer has not reviewed the latest revision.'
        : 'plan-reviewer has not reviewed this plan.'

  let answer: string
  try {
    answer = await $.ui.ask(`Plan: ${current.path}\n\n${summary}\n\nReview: ${review}\n\nHow should we proceed?`, {
      header: 'Handoff',
      options: [APPROVE_CLEAR, APPROVE_KEEP, REVISE, STOP],
    })
  } catch {
    return { result: 'The operator dismissed the handoff without deciding. Do not implement; end your turn and wait for their message.' }
  }

  switch (answer) {
    case APPROVE_CLEAR:
      await setFacet($, 'execute')
      await update($, isClearPending, () => true)
      return {
        result: 'The operator approved the plan and asked for a fresh context. End your turn now with a one-line acknowledgement and no further tool calls. The deep-plan plugin will clear the context and start implementation in a new turn.',
      }
    case APPROVE_KEEP:
      await setFacet($, 'execute')
      return { result: `The operator approved the plan. Execute facet is active: implement the plan at ${current.path} now.` }
    case REVISE:
      return { result: 'The operator wants revisions before approving. Ask what to change unless they have already said; stay in plan facet.' }
    case STOP:
      return { result: 'The operator stopped here. Do not implement; end your turn.' }
    default:
      return { result: `The operator answered: "${answer}". Treat it as revision feedback and stay in plan facet.` }
  }
}

async function clearAndExecute($: $): Promise<void> {
  const current = await read($, plan)
  await update($, isClearing, () => true)
  // Through /compact rather than $.session.compact: a plugin's own call skips
  // its own session.compact hook, which is the one that answers this.
  try {
    await $.command.run({ command: 'compact', args: 'deep-plan: clear for execution' })
  } catch (error) {
    $.ui.toast(`Could not clear the context (${String(error)}); continuing with it.`)
  } finally {
    await update($, isClearing, () => false)
  }
  await $.prompt.submit({
    text: `Implement the approved plan at ${current?.path ?? 'the recorded path'}.`,
    asUser: true,
  })
}
