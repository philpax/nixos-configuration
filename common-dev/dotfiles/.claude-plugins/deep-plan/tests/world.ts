// A small world beneath the plugin for its tests: files, registrations, the
// model judge and the operator's handoff answer, all from memory.

import type { On } from 'claude-code'
import { mock } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'

const PROMPTS: Record<string, string> = {
  'plan-facet.md': 'PLAN FACET\n{{PLAN_SPEC}}',
  'execute-facet.md': 'EXECUTE FACET {{PLAN_PATH}}',
  'plan-spec.md': 'DEFAULT SPEC',
  'plan-reviewer.md': 'REVIEWER\n{{PLAN_SPEC}}',
  'bash-judge.md': 'JUDGE',
}

export type World = {
  clock: MockClock
  files: Map<string, string>
  submitted: string[]
  judged: string[]
  asked: string[]
  agents: string[]
  // What the judge replies; ALLOW or DENY: reason.
  verdict: string
  // The label the operator picks at handoff; undefined dismisses the dialog.
  answer: string | undefined
}

export function world(on: On, files: Record<string, string> = {}): World {
  const state: World = {
    clock: undefined as unknown as MockClock,
    files: new Map(Object.entries(files)),
    submitted: [],
    judged: [],
    asked: [],
    agents: [],
    verdict: 'ALLOW',
    answer: undefined,
  }

  mock.env(on, { HOME: '/home/tester' })
  state.clock = mock.clock(on, { now: Date.UTC(2026, 9, 4) })

  on('session.start', () => ({ cwd: '/repo' }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('session.root', () => ({ value: '/repo' }))
  on('fs.exists', ($, e) => ({ value: state.files.has(e.path) || promptFor(e.path) !== undefined }))
  on('fs.read', ($, e) => {
    const text = state.files.get(e.path) ?? promptFor(e.path)
    return text === undefined ? { deny: `no file ${e.path}` } : { value: text }
  })
  on('fs.write', ($, e) => {
    state.files.set(e.path, e.text)
    return { value: undefined }
  })
  on('tool.register', ($, e) => ({ value: { tool: `mcp__deep-plan__${e.name}` } }))
  on('tool.list', () => ({
    value: ['Read', 'Bash', 'WebFetch'].map(name => ({ name, description: name, mcp: false })),
  }))
  on('agent.register', ($, e) => {
    state.agents.push(e.name)
    return { value: { agent: `deep-plan:${e.name}` } }
  })
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('ui.toast', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  on('prompt.submit', ($, e) => {
    state.submitted.push(e.text)
    return { text: e.text }
  })
  on('model.complete', ($, e) => {
    state.judged.push(e.prompt)
    return {
      value: {
        isAnswered: true,
        text: state.verdict,
        usage: { input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
      },
    }
  })
  on('tool.call', { tool: 'AskUserQuestion' }, ($, e) => {
    const question = e.questions[0]?.question ?? ''
    state.asked.push(question)
    if (state.answer === undefined) return { deny: 'dismissed' }
    return { result: { questions: e.questions, answers: { [question]: state.answer } } }
  })

  return state
}

function promptFor(path: string): string | undefined {
  const match = /\/prompts\/([a-z-]+\.md)$/.exec(path)
  return match ? PROMPTS[match[1] ?? ''] : undefined
}

export async function start($: Engine): Promise<void> {
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
}

// Runs a slash command as the person typing it would.
export function run($: Engine, command: string, args = '') {
  return $.command.run({
    command,
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 120 },
  })
}

export async function enterPlanFacet($: Engine): Promise<void> {
  await start($)
  await run($, 'deep-plan')
}
