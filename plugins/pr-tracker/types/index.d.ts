export type PrState = 'OPEN' | 'DRAFT' | 'MERGED' | 'CLOSED' | 'UNKNOWN'
export type PrReview = 'APPROVED' | 'CHANGES_REQUESTED' | 'REVIEW_REQUIRED' | 'NONE'
export type PrChecks = 'pass' | 'fail' | 'pending' | 'none'

export type Pr = {
  url: string
  repo: string
  number: number
  title: string
  task: string
  state: PrState
  review: PrReview
  approvers?: string[]
  checks: PrChecks
  base: string
  head: string
  addedAt: number
  checkedAt: number
  error: string
}

declare module 'claude-code' {
  interface PluginState {
    'pr-tracker': { prs: Pr[]; isCompact: boolean; toggled: string[] }
  }
}
