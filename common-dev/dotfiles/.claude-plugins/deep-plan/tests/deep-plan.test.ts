import { describe, expect, test } from 'claude-code/testing'

import { enterPlanFacet, run, start, world } from './world'

const WRITE_PLAN = 'mcp__deep-plan__write_plan'
const EDIT_PLAN = 'mcp__deep-plan__edit_plan'
const HANDOFF_PLAN = 'mcp__deep-plan__handoff_plan'

describe('plan facet guards', () => {
  test('refuses file writes in plan facet and lets them through outside it', async ($, on) => {
    world(on)
    on('tool.call', { tool: 'Write' }, () => ({ result: { type: 'create', filePath: '/repo/x', content: 'x', structuredPatch: [], originalFile: null } }))
    await start($)

    const outside = await $.tool.call({ tool: 'Write', file_path: '/repo/x', content: 'x' })
    expect(outside.deny).toBeUndefined()

    await run($, 'deep-plan')
    const inside = await $.tool.call({ tool: 'Write', file_path: '/repo/x', content: 'x' })
    expect(inside.deny).toContain('plan facet')
  })

  test('runs read-only Bash without asking the judge', async ($, on) => {
    const w = world(on)
    on('tool.call', { tool: 'Bash' }, () => ({ result: { stdout: 'clean', stderr: '', interrupted: false } }))
    await enterPlanFacet($)

    const ran = await $.tool.call({ tool: 'Bash', command: 'git status' })
    expect(ran.deny).toBeUndefined()
    expect(w.judged).toEqual([])
  })

  test('asks the judge about other Bash commands and follows its verdict', async ($, on) => {
    const w = world(on)
    on('tool.call', { tool: 'Bash' }, () => ({ result: { stdout: '', stderr: '', interrupted: false } }))
    await enterPlanFacet($)

    w.verdict = 'DENY: it deletes files.'
    const refused = await $.tool.call({ tool: 'Bash', command: 'rm -rf build' })
    expect(refused.deny).toContain('it deletes files.')

    w.verdict = 'ALLOW'
    const allowed = await $.tool.call({ tool: 'Bash', command: 'npm ls' })
    expect(allowed.deny).toBeUndefined()
    expect(w.judged.length).toBe(2)
  })
})

describe('plan tools', () => {
  test('write_plan creates the plan under the config dir and edit_plan revises it in place', async ($, on) => {
    const w = world(on)
    await enterPlanFacet($)

    const written = await $.tool.call({ tool: WRITE_PLAN, title: 'Add the thing', content: '# Goal\n\nOld goal.' })
    const path = '/home/tester/.claude/plans/2026-10-04-add-the-thing.md'
    expect(String(written.result)).toContain(path)
    expect(w.files.get(path)).toBe('# Goal\n\nOld goal.')

    const edited = await $.tool.call({ tool: EDIT_PLAN, old_string: 'Old goal.', new_string: 'New goal.' })
    expect(edited.deny).toBeUndefined()
    expect(w.files.get(path)).toBe('# Goal\n\nNew goal.')

    const missing = await $.tool.call({ tool: EDIT_PLAN, old_string: 'nowhere', new_string: 'x' })
    expect(missing.deny).toContain('not found')
  })

  test('plan tools are refused outside plan facet', async ($, on) => {
    world(on)
    await start($)
    const refused = await $.tool.call({ tool: WRITE_PLAN, title: 't', content: 'c' })
    expect(refused.deny).toContain('/deep-plan')
  })

  test('handoff approval switches to execute facet', async ($, on) => {
    const w = world(on)
    await enterPlanFacet($)
    await $.tool.call({ tool: WRITE_PLAN, title: 'Plan', content: 'body' })

    w.answer = 'Approve, keep context'
    const handed = await $.tool.call({ tool: HANDOFF_PLAN, summary: 'Does the thing.' })
    expect(String(handed.result)).toContain('Execute facet is active')
    expect(w.asked[0]).toContain('has not reviewed this plan')

    const { text } = await run($, 'facet')
    expect(text).toContain('execute')
  })

  test('a dismissed handoff keeps plan facet', async ($, on) => {
    world(on)
    await enterPlanFacet($)
    await $.tool.call({ tool: WRITE_PLAN, title: 'Plan', content: 'body' })

    const handed = await $.tool.call({ tool: HANDOFF_PLAN, summary: 's' })
    expect(String(handed.result)).toContain('Do not implement')
    const { text } = await run($, 'facet')
    expect(text).toContain('Facet: plan')
  })
})

const COMPOSE = {
  model: 'claude-opus-5-5',
  promptModel: 'claude-opus-5-5',
  surfaces: ['terminal'],
  tools: ['Agent', 'Read'],
  outputStyle: null,
  traits: [],
} as const

describe('facet prompts', () => {
  test('adds the facet section to the system prompt only while a facet is on', async ($, on) => {
    world(on)
    on('prompt.compose', () => ({ sections: [{ id: 'intro', text: 'core', scope: 'shared' }] }))
    await start($)

    const off = await $.prompt.compose(COMPOSE)
    expect(off.sections.map(section => section.id)).toEqual(['intro'])

    await run($, 'deep-plan')
    const planning = await $.prompt.compose(COMPOSE)
    const section = planning.sections.find(one => one.id === 'deep-plan:facet')
    expect(section?.text).toContain('PLAN FACET')
    expect(section?.text).toContain('DEFAULT SPEC')
    expect(section?.scope).toBe('session')
  })

  test("a repository's .claude/plan-spec.md replaces the default spec", async ($, on) => {
    world(on, { '/repo/.claude/plan-spec.md': 'REPO SPEC' })
    on('prompt.compose', () => ({ sections: [] }))
    await enterPlanFacet($)

    const { sections } = await $.prompt.compose(COMPOSE)
    expect(sections[0]?.text).toContain('REPO SPEC')
    expect(sections[0]?.text).not.toContain('DEFAULT SPEC')
  })

  test('adds the facet compaction hint to the summarizer instructions', async ($, on) => {
    world(on)
    const told: (string | undefined)[] = []
    on('session.compact', ($, e) => {
      told.push(e.instructions)
      return { messages: e.messages }
    })
    await enterPlanFacet($)

    await $.session.compact({
      trigger: 'manual',
      instructions: 'keep the API notes',
      messages: [{ role: 'user', text: 'earlier', toolUses: [] }],
    })
    expect(told[0]).toContain('keep the API notes')
    expect(told[0]).toContain('read-only plan mode')
  })
})

describe('review and handoff', () => {
  test('handoff reports a review of the current revision, and a stale one after an edit', async ($, on) => {
    const w = world(on)
    on('tool.call', { tool: 'Agent' }, () => ({ result: { status: 'completed', content: [] } as never }))
    await enterPlanFacet($)
    await $.tool.call({ tool: WRITE_PLAN, title: 'Plan', content: 'one two' })
    await $.tool.call({ tool: 'Agent', subagent_type: 'deep-plan:plan-reviewer', description: 'review', prompt: 'review it' })

    w.answer = 'Revise'
    await $.tool.call({ tool: HANDOFF_PLAN, summary: 's' })
    expect(w.asked[0]).toContain('has reviewed this revision')

    await $.tool.call({ tool: EDIT_PLAN, old_string: 'two', new_string: 'three' })
    await $.tool.call({ tool: HANDOFF_PLAN, summary: 's' })
    expect(w.asked[1]).toContain('has not reviewed the latest revision')
  })

  test('approving with a clear swaps the transcript for the plan and starts execution', async ($, on) => {
    const w = world(on)
    let isCoreCompacted = false
    on('session.compact', ($, e) => {
      isCoreCompacted = true
      return { messages: e.messages }
    })
    on('prompt.compose', () => ({ sections: [] }))
    on('turn.complete', ($, e) => ({ text: e.answer }))
    // Core's /compact raises the compaction chain, where deep-plan answers.
    on('command.run', { command: 'compact' }, async $ => {
      await $.session.compact({ instructions: 'from /compact' })
      return { text: '' }
    })
    await enterPlanFacet($)
    await $.tool.call({ tool: WRITE_PLAN, title: 'Plan', content: 'THE PLAN' })

    w.answer = 'Approve, clear context'
    const handed = await $.tool.call({ tool: HANDOFF_PLAN, summary: 's' })
    expect(String(handed.result)).toContain('End your turn now')

    await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' } as never)
    await w.clock.advance(1)
    await w.clock.settle()

    expect(isCoreCompacted).toBe(false)
    expect(w.submitted.at(-1)).toContain('Implement the approved plan at /home/tester/.claude/plans/')
    const { sections } = await $.prompt.compose(COMPOSE)
    expect(sections[0]?.text).toContain('EXECUTE FACET /home/tester/.claude/plans/2026-10-04-plan.md')
  })
})
