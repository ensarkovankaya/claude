import { expect, mock, test } from 'claude-code/testing'

import type { Pr } from '../types'
import { applyGhView, groupByTask, isCollapsed, isPrCreateCommand, newPr, parsePrUrls, summarizeChecks, taskOf, compilePattern, prCreatePatterns } from '../hooks/lib'

const PR_16 = 'https://github.com/acme/orders-api/pull/16'
const DOCS_PR = 'https://github.com/acme/api-docs/pull/1301'

const ghView = (title: string, base: string, extra: Record<string, unknown> = {}) =>
  JSON.stringify({
    title,
    state: 'OPEN',
    isDraft: false,
    reviewDecision: 'REVIEW_REQUIRED',
    baseRefName: base,
    headRefName: 'feature/x',
    statusCheckRollup: [{ name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }],
    ...extra,
  })

test('recognizes PR-creating commands', () => {
  expect(isPrCreateCommand('cd x && gh pr create --title "ABC-1: A" --body b')).toBe(true)
  expect(isPrCreateCommand('gh api repos/acme/x/pulls -X POST -f title=t')).toBe(true)
  expect(isPrCreateCommand('gh pr view 16 --json state')).toBe(false)
  expect(isPrCreateCommand('gh api repos/acme/x/pulls/16/comments -X POST')).toBe(false)
  const custom = prCreatePatterns(compilePattern('\\bopen-pr\\.sh\\b'))
  expect(isPrCreateCommand('./open-pr.sh --title "ABC-1: A"')).toBe(false)
  expect(isPrCreateCommand('./open-pr.sh --title "ABC-1: A"', custom)).toBe(true)
  expect(compilePattern('(')).toBeUndefined()
})

test('URL parsing dedupes and strips sub-paths', () => {
  const text = `${PR_16}\n"html_url": "${PR_16}", ${PR_16}/commits ${DOCS_PR}`
  expect(parsePrUrls(text)).toEqual([PR_16, DOCS_PR])
})

test('task from title, else from branch name', () => {
  expect(taskOf('ABC-12: Pending Orders', 'feature/ABC-1-x')).toBe('ABC-12')
  expect(taskOf('Fix typo', 'fix/OPS-7-config')).toBe('OPS-7')
  expect(taskOf('Fix typo', 'fix-typo')).toBe('Other')
})

test('an ignored pending check does not hold the CI state', () => {
  expect(
    summarizeChecks([
      { name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' },
      { context: 'review-bot-gate', state: 'PENDING' },
    ], compilePattern('review-bot-gate')),
  ).toBe('pass')
  expect(summarizeChecks([{ context: 'review-bot-gate', state: 'PENDING' }])).toBe('pending')
  expect(summarizeChecks([{ name: 'test', status: 'IN_PROGRESS' }])).toBe('pending')
  expect(summarizeChecks([{ name: 'test', status: 'COMPLETED', conclusion: 'FAILURE' }])).toBe('fail')
  expect(summarizeChecks([])).toBe('none')
})

test('groups: those with open work first, all-merged ones collapsed', () => {
  const merged: Pr = { ...applyGhView(newPr(DOCS_PR, 1), ghView('ABC-11: A', 'development', { state: 'MERGED' }), 2) }
  const open: Pr = applyGhView(newPr(PR_16, 0), ghView('ABC-12: B', 'feature/ABC-10-order-list'), 2)
  const groups = groupByTask([merged, open])
  expect(groups.map(group => group.task)).toEqual(['ABC-12', 'ABC-11'])
  expect(groups.map(group => isCollapsed(group, []))).toEqual([false, true])
  expect(groups.map(group => isCollapsed(group, ['ABC-11']))).toEqual([false, false])
})

test('a subagent gh pr create output lands in the pane and its state is fetched', { options: { jiraBaseUrl: 'https://example.atlassian.net/browse' } }, async ($, on) => {
  mock.store(on)
  const clock = mock.clock(on, { now: 1_000 })
  on('session.id', () => ({ value: 'test-session' }))
  const argvs: string[][] = []
  on('process.run', ($, e) => (argvs.push([...e.argv]), {
    value: {
    exitCode: 0,
    stdout: ghView('ABC-12: List Pending Orders', 'feature/ABC-10-order-list', {
      latestReviews: [
        { author: { login: 'alice' }, state: 'APPROVED' },
        { author: { login: 'bob' }, state: 'COMMENTED' },
      ],
    }),
    stderr: e.argv.includes(PR_16) ? '' : 'unexpected',
    isStdoutTruncated: false,
    isStderrTruncated: false,
    },
  }))
  on('tool.call', { tool: 'Bash' }, () => ({
    result: { stdout: `${PR_16}\n`, stderr: '', interrupted: false },
    text: `${PR_16}\n`,
  }))

  await $.tool.call({ tool: 'Bash', command: 'gh pr create --title "ABC-12: X" --body y' })
  await clock.advance(0)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({
      plugin: 'pr-tracker',
      surface,
      component: 'Pane',
      requestId: 'pr-tracker',
      props: { title: 'PRs', isFocused: false, bodyColumns: 48, placement: 'dock', scroll: { offset: 0, bodyRows: 30 }, view: {} },
    })
    const summary = JSON.stringify(await ui.drawn())
    expect(summary).toContain('orders-api#16')
    expect(summary).not.toContain('Pending Orders')

    await ui.press({ key: 'mode' })
    const drawn = JSON.stringify(await ui.drawn())
    expect(drawn).toContain('"✓ approved by: ","alice"')
    expect(drawn).not.toContain('bob')
    expect(drawn).toContain('orders-api#16')
    expect(drawn).toContain('ABC-12')
    expect(drawn).toContain('feature/ABC-10-order-list')
    expect(drawn).toContain('review')

    argvs.length = 0
    await ui.press({ key: `l:${PR_16}` })
    await ui.press({ key: 'j:ABC-12' })
    await clock.advance(0)
    expect(argvs).toEqual([
      ['open', PR_16],
      ['open', 'https://example.atlassian.net/browse/ABC-12'],
    ])

    await ui.press({ key: 'mode' })
    expect(JSON.stringify(await ui.drawn())).not.toContain('Pending Orders')
    await ui.unmount()
  }
})
