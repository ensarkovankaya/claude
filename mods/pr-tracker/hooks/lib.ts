import type { Pr, PrChecks, PrReview, PrState } from '../types'

export const NO_TASK = 'Diğer'

const PR_URL = /https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/pull\/(\d+)/g
const TASK_KEY = /\b([A-Z][A-Z0-9]+-\d+)\b/
const DEFAULT_BASES = new Set(['development', 'develop', 'main', 'master'])
const FAILED = new Set(['FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE'])

// Her grup: içindeki tüm regex'ler eşleşirse komut PR açan sayılır. scripts/scan-transcript.mjs de bunu kullanır.
export const PR_CREATE_PATTERNS: readonly (readonly string[])[] = [
  ['\\bgh\\s+pr\\s+create\\b'],
  ['\\bgh\\s+api\\b', '/pulls\\b(?!/)', '(-X|--method)\\s+POST\\b|\\s-[fF]\\s+(title|head)='],
]

// Ayardaki regex geçersizse yok sayılır.
export function compilePattern(source: unknown): RegExp | undefined {
  if (typeof source !== 'string' || source.trim() === '') {
    return undefined
  }
  try {
    return new RegExp(source.trim(), 'i')
  } catch {
    return undefined
  }
}

export function prCreatePatterns(extra: RegExp | undefined): readonly (readonly string[])[] {
  return extra === undefined ? PR_CREATE_PATTERNS : [...PR_CREATE_PATTERNS, [extra.source]]
}

export function isPrCreateCommand(command: string, patterns: readonly (readonly string[])[] = PR_CREATE_PATTERNS): boolean {
  return patterns.some(group => group.every(source => new RegExp(source).test(command)))
}

export function parsePrUrls(text: string): string[] {
  const urls = new Set<string>()
  for (const match of text.matchAll(PR_URL)) {
    urls.add(`https://github.com/${match[1]}/${match[2]}/pull/${match[3]}`)
  }

  return [...urls]
}

export function parsePrRef(input: string): { repo: string; number: number } | undefined {
  const match = /github\.com\/[\w.-]+\/([\w.-]+)\/pull\/(\d+)/.exec(input) ?? /^([\w.-]+)#(\d+)$/.exec(input.trim())
  if (match === null || match[1] === undefined || match[2] === undefined) {
    return undefined
  }

  return { repo: match[1], number: Number(match[2]) }
}

export function taskOf(title: string, head: string): string {
  return TASK_KEY.exec(title)?.[1] ?? TASK_KEY.exec(head)?.[1] ?? NO_TASK
}

export function newPr(url: string, addedAt: number): Pr {
  const ref = parsePrRef(url)

  return {
    url,
    repo: ref?.repo ?? '?',
    number: ref?.number ?? 0,
    title: '',
    task: NO_TASK,
    state: 'UNKNOWN',
    review: 'NONE',
    checks: 'none',
    base: '',
    head: '',
    addedAt,
    checkedAt: 0,
    error: '',
  }
}

type CheckEntry = { name?: string; context?: string; status?: string; conclusion?: string; state?: string }

export function summarizeChecks(rollup: readonly CheckEntry[], ignoredPending?: RegExp): PrChecks {
  let hasPending = false
  for (const check of rollup) {
    const verdict = (check.conclusion || check.state || '').toUpperCase()
    if (FAILED.has(verdict)) {
      return 'fail'
    }
    const isDone = check.status === undefined ? verdict !== 'PENDING' && verdict !== 'EXPECTED' : check.status === 'COMPLETED'
    if (!isDone && ignoredPending?.test(check.name ?? check.context ?? '') !== true) {
      hasPending = true
    }
  }
  if (hasPending) {
    return 'pending'
  }

  return rollup.length > 0 ? 'pass' : 'none'
}

type GhPr = {
  title?: string
  state?: string
  isDraft?: boolean
  reviewDecision?: string
  baseRefName?: string
  headRefName?: string
  statusCheckRollup?: CheckEntry[]
  latestReviews?: { author?: { login?: string }; state?: string }[]
}

export function applyGhView(pr: Pr, json: string, checkedAt: number, ignoredPending?: RegExp): Pr {
  const view = JSON.parse(json) as GhPr
  const title = view.title ?? pr.title
  const head = view.headRefName ?? pr.head
  const raw = (view.state ?? 'UNKNOWN').toUpperCase()
  const state: PrState = raw === 'OPEN' && view.isDraft === true ? 'DRAFT' : raw === 'OPEN' || raw === 'MERGED' || raw === 'CLOSED' ? raw : 'UNKNOWN'
  const review: PrReview =
    view.reviewDecision === 'APPROVED' || view.reviewDecision === 'CHANGES_REQUESTED' || view.reviewDecision === 'REVIEW_REQUIRED'
      ? view.reviewDecision
      : 'NONE'

  return {
    ...pr,
    title,
    head,
    task: taskOf(title, head),
    state,
    review,
    approvers: (view.latestReviews ?? [])
      .filter(entry => entry.state === 'APPROVED' && entry.author?.login !== undefined)
      .map(entry => entry.author?.login ?? ''),
    checks: summarizeChecks(view.statusCheckRollup ?? [], ignoredPending),
    base: view.baseRefName ?? pr.base,
    checkedAt,
    error: '',
  }
}

export function isActive(pr: Pr): boolean {
  return pr.state === 'OPEN' || pr.state === 'DRAFT' || pr.state === 'UNKNOWN'
}

export function isStackedBase(base: string): boolean {
  return base !== '' && !DEFAULT_BASES.has(base)
}

export function shortTitle(pr: Pr): string {
  return pr.title.replace(/^\s*[A-Z][A-Z0-9]+-\d+\s*[:\-–]\s*/, '')
}

export type Group = { task: string; prs: Pr[]; active: number; merged: number; closed: number; lastAddedAt: number }

export function groupByTask(prs: readonly Pr[]): Group[] {
  const groups = new Map<string, Group>()
  for (const pr of prs) {
    const group = groups.get(pr.task) ?? { task: pr.task, prs: [], active: 0, merged: 0, closed: 0, lastAddedAt: 0 }
    group.prs.push(pr)
    group.lastAddedAt = Math.max(group.lastAddedAt, pr.addedAt)
    if (isActive(pr)) {
      group.active += 1
    } else if (pr.state === 'MERGED') {
      group.merged += 1
    } else {
      group.closed += 1
    }
    groups.set(pr.task, group)
  }
  for (const group of groups.values()) {
    group.prs.sort((a, b) => a.addedAt - b.addedAt)
  }

  return [...groups.values()].sort((a, b) => {
    if ((a.active > 0) !== (b.active > 0)) {
      return a.active > 0 ? -1 : 1
    }

    return b.lastAddedAt - a.lastAddedAt
  })
}

export function isCollapsed(group: Group, toggled: readonly string[]): boolean {
  const byDefault = group.active === 0

  return toggled.includes(group.task) ? !byDefault : byDefault
}
