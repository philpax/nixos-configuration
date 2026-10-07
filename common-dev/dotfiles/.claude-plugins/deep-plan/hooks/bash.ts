// The plan facet's fast path for Bash: a command passes here only when every
// segment of it is a known read-only invocation. Anything else goes to the
// model judge, so a miss costs latency, never safety; keep this list strict.

const READ_ONLY_COMMANDS = new Set([
  'basename', 'cat', 'cd', 'cut', 'date', 'df', 'diff', 'dirname', 'du', 'echo', 'file', 'grep',
  'head', 'jq', 'ls', 'printenv', 'pwd', 'readlink', 'realpath', 'rg', 'sort', 'stat', 'tail', 'tr',
  'tree', 'uname', 'uniq', 'wc', 'which', 'whoami',
])

const READ_ONLY_GIT = new Set([
  'blame', 'cat-file', 'describe', 'diff', 'grep', 'log', 'ls-files', 'ls-tree', 'merge-base',
  'rev-parse', 'shortlog', 'show', 'status',
])

const READ_ONLY_GIT_BRANCH_FLAGS = new Set([
  '-a', '--all', '-r', '--remotes', '-v', '-vv', '--verbose', '--list', '--show-current',
])

const READ_ONLY_GH: Record<string, Set<string>> = {
  issue: new Set(['list', 'status', 'view']),
  pr: new Set(['checks', 'diff', 'list', 'status', 'view']),
  release: new Set(['list', 'view']),
  repo: new Set(['view']),
  run: new Set(['list', 'view']),
}

const READ_ONLY_NIX: Record<string, Set<string>> = {
  eval: new Set(['']),
  flake: new Set(['metadata', 'show']),
  'path-info': new Set(['']),
  search: new Set(['']),
}

const FIND_ACTIONS = /^-(delete|exec|execdir|ok|okdir|fprint|fprint0|fprintf|fls)$/

// Redirections that write nowhere; anything else with `>` falls to the judge.
const HARMLESS_REDIRECTS = /\s(2>&1|[12]?>\s*\/dev\/null)(?=\s|$)/g

export function isReadOnlyCommand(command: string): boolean {
  const stripped = ` ${command} `.replace(HARMLESS_REDIRECTS, ' ')
  if (/[`<>]|\$\(/.test(stripped)) return false

  const segments = stripped.split(/&&|\|\||[;|\n&]/)
  return segments.every(segment => isReadOnlySegment(segment.trim()))
}

function isReadOnlySegment(segment: string): boolean {
  if (segment === '') return true
  const words = segment.split(/\s+/).map(word => word.replace(/^['"]|['"]$/g, ''))
  const [head = '', ...args] = words

  switch (head) {
    case 'git':
      return isReadOnlyGit(args)
    case 'gh':
      return READ_ONLY_GH[args[0] ?? '']?.has(args[1] ?? '') ?? false
    case 'nix':
      return isReadOnlyNix(args)
    case 'find':
      return !args.some(arg => FIND_ACTIONS.test(arg))
    case 'sed':
      return args.includes('-n') && !args.some(arg => /^(-i|--in-place)/.test(arg))
    default:
      return READ_ONLY_COMMANDS.has(head)
  }
}

function isReadOnlyGit(args: readonly string[]): boolean {
  // Global options such as `-C dir` come before the subcommand.
  let index = 0
  while (args[index]?.startsWith('-')) index += args[index] === '-C' ? 2 : 1
  const [subcommand = '', ...rest] = args.slice(index)

  if (subcommand === 'branch') return rest.every(arg => READ_ONLY_GIT_BRANCH_FLAGS.has(arg))
  if (subcommand === 'remote') return rest.length === 0 || rest[0] === '-v' || rest[0] === 'get-url'
  return READ_ONLY_GIT.has(subcommand)
}

function isReadOnlyNix(args: readonly string[]): boolean {
  const [subcommand = '', action = ''] = args
  const allowed = READ_ONLY_NIX[subcommand]
  if (allowed === undefined) return false
  return allowed.has('') || allowed.has(action)
}
