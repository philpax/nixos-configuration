import { describe, expect, test } from 'claude-code/testing'

import { isReadOnlyCommand } from '../hooks/bash'

describe('isReadOnlyCommand', () => {
  test('passes read-only inspection commands', () => {
    for (const command of [
      'git status',
      'git -C /repo log --oneline -5',
      'git diff --stat HEAD~1 2>&1',
      'git branch --show-current',
      'gh pr view 12',
      'rg -n foo src | head -20',
      'ls -la && cat README.md',
      'nix eval .#foo 2>/dev/null',
      "sed -n '1,20p' file.txt",
      'find . -name "*.nix"',
    ]) {
      expect(isReadOnlyCommand(command)).toBe(true)
    }
  })

  test('sends anything else to the judge', () => {
    for (const command of [
      'rm -rf build',
      'git commit -m x',
      'git branch -D old',
      'git push',
      'echo hi > file.txt',
      'cat $(which foo)',
      'ls `pwd`',
      'sed -i s/a/b/ file',
      'find . -delete',
      'find . -exec rm {} ;',
      'FOO=1 ls',
      'gh pr merge 12',
      'nix build',
      'ls; make',
      'npm test',
    ]) {
      expect(isReadOnlyCommand(command)).toBe(false)
    }
  })
})
