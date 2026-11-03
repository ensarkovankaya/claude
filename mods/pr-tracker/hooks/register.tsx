import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Pr, PrChecks, PrReview, PrState } from '../types'
import {
  NO_TASK,
  applyGhView,
  compilePattern,
  groupByTask,
  isActive,
  isCollapsed,
  isPrCreateCommand,
  prCreatePatterns,
  isStackedBase,
  newPr,
  parsePrRef,
  parsePrUrls,
  shortTitle,
} from './lib'

const PANE = 'pr-tracker'
const TITLE = 'PRs'
const POLL_MS = 120_000
const STORE_TTL_MS = 30 * 24 * 3600 * 1000
const OPEN_CANDIDATES = ['open', '/usr/bin/open']
const GH_CANDIDATES = ['gh', '/opt/homebrew/bin/gh', '/usr/local/bin/gh']
const NODE_CANDIDATES = ['node', '/opt/homebrew/bin/node', '/usr/local/bin/node']
const GH_FIELDS = 'title,state,isDraft,reviewDecision,baseRefName,headRefName,statusCheckRollup,latestReviews'

const prs = atom({ plugin: 'pr-tracker', key: 'prs' } as const, [] as Pr[])
const isCompact = atom({ plugin: 'pr-tracker', key: 'isCompact' } as const, true)
const toggled = atom({ plugin: 'pr-tracker', key: 'toggled' } as const, [] as string[])

type Saved = { prs: Pr[]; savedAt: number; scannedAt?: number; dismissed?: string[] }
type Found = { url: string; at: number }

const STATE_LABEL: Record<PrState, [string, string]> = {
  OPEN: ['açık', 'success'],
  DRAFT: ['draft', 'inactive'],
  MERGED: ['merged', 'merged'],
  CLOSED: ['closed', 'error'],
  UNKNOWN: ['…', 'inactive'],
}
const REVIEW_LABEL: Record<PrReview, [string, string] | undefined> = {
  APPROVED: ['✓ onay', 'success'],
  CHANGES_REQUESTED: ['✗ değişiklik', 'error'],
  REVIEW_REQUIRED: ['⧗ review', 'warning'],
  NONE: undefined,
}
const CHECKS_LABEL: Record<PrChecks, [string, string] | undefined> = {
  pass: ['CI ✓', 'success'],
  fail: ['CI ✗', 'error'],
  pending: ['CI …', 'warning'],
  none: undefined,
}

const bins = new Map<string, string>()
let createPatterns = prCreatePatterns(undefined)
let ignoredPending: RegExp | undefined
let isPolling = false

async function storeKey($: EngineInterface): Promise<string> {
  return `session:${await $.session.id()}`
}

async function loadSaved($: EngineInterface): Promise<Saved | undefined> {
  return (await $.store.get(await storeKey($))) as Saved | undefined
}

async function persist($: EngineInterface, patch: Partial<Saved> = {}): Promise<void> {
  const old = await loadSaved($)
  const saved: Saved = { ...old, ...patch, prs: await read($, prs), savedAt: await $.clock.now() }
  await $.store.set(await storeKey($), saved)
}

async function restore($: EngineInterface): Promise<void> {
  const now = await $.clock.now()
  for (const key of await $.store.keys()) {
    const old = (await $.store.get(key)) as Saved | undefined
    if (key.startsWith('session:') && (old?.savedAt ?? 0) < now - STORE_TTL_MS) {
      const id = key.slice('session:'.length)
      await $.store.delete(key)
      await $.store.delete(`cwd:${id}`)
    }
  }
  const saved = await loadSaved($)
  if (saved !== undefined && (await read($, prs)).length === 0) {
    await update($, prs, () => saved.prs)
  }
}

async function runBin($: EngineInterface, candidates: readonly string[], args: string[], timeoutMs: number) {
  const name = candidates[0] ?? ''
  const known = bins.get(name)
  for (const bin of known === undefined ? candidates : [known]) {
    try {
      const ran = await $.process.run([bin, ...args], { timeoutMs })
      bins.set(name, bin)

      return ran
    } catch (error) {
      if (known !== undefined) {
        throw error
      }
    }
  }
  throw new Error(`${name} bulunamadı`)
}

async function refresh($: EngineInterface, only?: readonly string[]): Promise<void> {
  if (isPolling) {
    return
  }
  isPolling = true
  try {
    const targets = (await read($, prs)).filter(pr => (only === undefined ? pr.state !== 'MERGED' : only.includes(pr.url)))
    for (const target of targets) {
      let next: Pr
      try {
        const ran = await runBin($, GH_CANDIDATES, ['pr', 'view', target.url, '--json', GH_FIELDS], 20_000)
        next =
          ran.exitCode === 0
            ? applyGhView(target, ran.stdout, await $.clock.now(), ignoredPending)
            : { ...target, error: ran.stderr.trim().split('\n')[0] ?? 'gh hata' }
      } catch (error) {
        next = { ...target, error: String(error).slice(0, 120) }
      }
      await update($, prs, list => list.map(pr => (pr.url === next.url ? next : pr)))
    }
    await persist($)
  } finally {
    isPolling = false
  }
}

async function add($: EngineInterface, items: readonly (string | Found)[], patch: Partial<Saved> = {}): Promise<string[]> {
  const now = await $.clock.now()
  const found = items.map(item => (typeof item === 'string' ? { url: item, at: now } : item))
  const known = new Set((await read($, prs)).map(pr => pr.url))
  const fresh = found.filter(item => !known.has(item.url))
  if (fresh.length === 0) {
    await persist($, patch)

    return []
  }
  await update($, prs, list => {
    const urlsInList = new Set(list.map(pr => pr.url))

    return [...list, ...fresh.filter(item => !urlsInList.has(item.url)).map(item => newPr(item.url, item.at || now))]
  })
  await persist($, patch)
  const urls = fresh.map(item => item.url)
  $.clock.after(0, () => void refresh($, urls).catch(() => undefined))

  return urls
}

async function remove($: EngineInterface, ref: string): Promise<number> {
  const target = parsePrRef(ref)
  if (target === undefined) {
    return 0
  }
  const list = await read($, prs)
  const gone = list.filter(pr => pr.repo === target.repo && pr.number === target.number).map(pr => pr.url)
  const before = list.length
  await update($, prs, all => all.filter(pr => !gone.includes(pr.url)))
  await persist($, { dismissed: [...new Set([...((await loadSaved($))?.dismissed ?? []), ...gone])] })

  return before - (await read($, prs)).length
}

async function transcriptPath($: EngineInterface): Promise<string | undefined> {
  const id = await $.session.id()
  const home = await $.env.get('HOME')
  const configDir = (await $.env.get('CLAUDE_CONFIG_DIR')) ?? `${home ?? ''}/.claude`
  const cwd = ((await $.store.get(`cwd:${id}`)) as string | undefined) ?? ''
  const guess = `${configDir}/projects/${cwd.replace(/[^A-Za-z0-9]/g, '-')}/${id}.jsonl`

  return (await $.fs.exists(guess)) ? guess : undefined
}

async function scan($: EngineInterface): Promise<{ added: string[]; total: number } | { error: string }> {
  const path = await transcriptPath($)
  if (path === undefined) {
    return { error: 'transcript dosyası bulunamadı' }
  }
  const script = `${$.plugin.root}/scripts/scan-transcript.mjs`
  const ran = await runBin($, NODE_CANDIDATES, [script, path, JSON.stringify(createPatterns)], 120_000)
  if (ran.exitCode !== 0) {
    return { error: ran.stderr.trim().split('\n')[0] ?? 'scan hata' }
  }
  const result = JSON.parse(ran.stdout) as { prs: Found[] }
  const dismissed = new Set((await loadSaved($))?.dismissed ?? [])
  const found = result.prs.filter(item => !dismissed.has(item.url))
  const added = await add($, found, { scannedAt: await $.clock.now() })

  return { added, total: found.length }
}

async function autoScan($: EngineInterface): Promise<void> {
  const result = await scan($)
  if ('added' in result && result.added.length > 0) {
    $.ui.toast(`pr-tracker: transcript'ten ${result.added.length} PR eklendi`)
    void openPane($).catch(() => undefined)
  }
  await refresh($)
}

function jiraBrowseUrl(value: unknown): string {
  const trimmed = typeof value === 'string' ? value.trim() : ''

  return trimmed === '' || trimmed.endsWith('/') ? trimmed : `${trimmed}/`
}

function openUrl($: EngineInterface, url: string) {
  void runBin($, OPEN_CANDIDATES, [url], 5_000).catch(() => undefined)
}

async function openPane($: EngineInterface) {
  return $.ui.open({ id: PANE, title: TITLE })
}

export const register: Register = (on, options) => {
  const jiraBrowse = jiraBrowseUrl(options.jiraBaseUrl)
  createPatterns = prCreatePatterns(compilePattern(options.extraPrCommand))
  ignoredPending = compilePattern(options.ignoredPendingChecks)

  on('session.start', async ($, e, next) => {
    await $.store.set(`cwd:${await $.session.id()}`, e.cwd)
    await $.command.register({
      name: 'prs',
      description: "PR panelini aç/kapat; add <url…> | rm <repo#n> | scan | refresh | compact | clear",
      argumentHint: '[add <url…> | rm <repo#n> | scan | refresh | compact | close | clear]',
    })
    await restore($)
    $.clock.every(POLL_MS, () => void refresh($).catch(() => undefined))
    const isScanned = (await loadSaved($))?.scannedAt !== undefined
    $.clock.after(0, () => void (isScanned ? refresh($) : autoScan($)).catch(() => undefined))
    if ((await read($, prs)).length > 0) {
      void openPane($).catch(() => undefined)
    }

    return next(e)
  })

  on('command.run', { command: 'prs' }, async ($, e) => {
    const [verb = '', ...rest] = e.args.trim().split(/\s+/).filter(Boolean)
    switch (verb) {
      case '':
      case 'open': {
        const opened = await openPane($)

        return { text: opened.isPlaced ? 'PR paneli açık. Kapatmak: Esc veya /prs close' : `PR paneli açılamadı: ${opened.reason}` }
      }
      case 'close':
        await $.ui.close({ id: PANE })

        return { text: 'PR paneli kapatıldı. Tekrar açmak: /prs' }
      case 'add': {
        const fresh = await add($, parsePrUrls(rest.join(' ')))
        void openPane($).catch(() => undefined)

        return { text: fresh.length > 0 ? `Eklendi: ${fresh.join(', ')}` : 'Yeni PR URL yok (zaten listede ya da geçersiz)' }
      }
      case 'rm':
      case 'remove': {
        const removed = rest.length === 0 ? 0 : await remove($, rest.join(' '))

        return { text: removed > 0 ? `Silindi: ${rest.join(' ')}` : 'Eşleşen PR yok. Kullanım: /prs rm <repo#n | url>' }
      }
      case 'scan': {
        const result = await scan($)
        if ('error' in result) {
          return { text: `Scan başarısız: ${result.error}` }
        }
        void openPane($).catch(() => undefined)

        return { text: `Transcript'te ${result.total} PR bulundu, ${result.added.length} yeni eklendi` }
      }
      case 'refresh':
        await refresh($, (await read($, prs)).map(pr => pr.url))

        return { text: 'PR durumları yenilendi' }
      case 'compact':
        await update($, isCompact, value => !value)

        return { text: (await read($, isCompact)) ? 'Özet görünüm' : 'Detay görünüm' }
      case 'clear':
        await update($, prs, () => [])
        await persist($, { scannedAt: await $.clock.now() })

        return { text: 'PR listesi temizlendi' }
      default:
        return { text: 'Kullanım: /prs [open | close | add <url…> | rm <repo#n> | scan | refresh | compact | clear]' }
    }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny !== undefined || !isPrCreateCommand(e.command, createPatterns)) {
      return ran
    }
    const fresh = await add($, parsePrUrls(ran.text ?? ''))
    if (fresh.length > 0) {
      const where = e.agentId === undefined ? '' : ' (subagent)'
      $.ui.toast(`PR eklendi${where}: ${fresh.map(url => url.replace('https://github.com/', '')).join(', ')}`)
      void openPane($).catch(() => undefined)
    }

    return ran
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const list = await read($, prs)
    const compact = await read($, isCompact)
    const flipped = await read($, toggled)
    const groups = groupByTask(list)
    const active = list.filter(isActive).length
    const merged = list.filter(pr => pr.state === 'MERGED').length

    const toggle = (task: string) =>
      update($, toggled, keys => (keys.includes(task) ? keys.filter(key => key !== task) : [...keys, task]))

    const label = (pair: [string, string] | undefined, key: string) =>
      pair === undefined ? null : (
        <Text key={key} color={pair[1]}>
          {' '}
          {pair[0]}
        </Text>
      )

    const linkButton = (key: string, url: string, text: string) => (
      <Button key={key} plain label={text} onPress={() => openUrl($, url)} />
    )
    const prLink = (pr: Pr, key: string) => linkButton(key, pr.url, `${pr.repo}#${pr.number}`)

    return (
      <Box flexDirection="column">
        <Box flexDirection="row" justifyContent="space-between">
          <Text dimColor>
            {list.length === 0 ? 'Henüz PR yok' : `${active} açık · ${merged} merged`}
          </Text>
          <Box flexDirection="row" gap={1}>
            <Button key="refresh" plain label="⟳" onPress={() => void refresh($, list.map(pr => pr.url)).catch(() => undefined)} />
            <Button key="mode" plain label={compact ? '[detay]' : '[özet]'} onPress={() => update($, isCompact, value => !value)} />
          </Box>
        </Box>
        {list.length === 0 && (
          <Text dimColor wrap="wrap">
            `gh pr create` (ana session veya subagent) çıktısındaki PR'lar burada görünür. Elle: /prs add &lt;url&gt;
          </Text>
        )}
        {groups.map(group => {
          const isClosed = isCollapsed(group, flipped)
          const summary = [
            group.active > 0 ? `${group.active} açık` : '',
            group.merged > 0 ? `${group.merged} merged` : '',
            group.closed > 0 ? `${group.closed} closed` : '',
          ]
            .filter(Boolean)
            .join(', ')

          return (
            <Box key={`g:${group.task}`} flexDirection="column" marginTop={compact ? 0 : 1}>
              <Box flexDirection="row">
                <Button key={`t:${group.task}`} plain label={isClosed ? '▸' : '▾'} onPress={() => toggle(group.task)} />
                <Text> </Text>
                {group.task === NO_TASK || jiraBrowse === '' ? (
                  <Text bold>{group.task}</Text>
                ) : (
                  linkButton(`j:${group.task}`, jiraBrowse + group.task, group.task)
                )}
                <Text dimColor> {summary}</Text>
              </Box>
              {!isClosed && compact && (
                <Box flexDirection="row" flexWrap="wrap" paddingLeft={2}>
                  {group.prs.map(pr => (
                    <Box key={`c:${pr.url}`} flexDirection="row">
                      {prLink(pr, `l:${pr.url}`)}
                      <Text color={STATE_LABEL[pr.state][1]}> ● </Text>
                    </Box>
                  ))}
                </Box>
              )}
              {!isClosed &&
                !compact &&
                group.prs.map(pr => (
                  <Box key={`p:${pr.url}`} flexDirection="column" paddingLeft={2}>
                    <Box flexDirection="row">
                      {prLink(pr, `l:${pr.url}`)}
                      <Text wrap="truncate">
                        {label(STATE_LABEL[pr.state], 's')}
                        {isActive(pr) ? label(REVIEW_LABEL[pr.review], 'r') : null}
                        {isActive(pr) ? label(CHECKS_LABEL[pr.checks], 'c') : null}
                      </Text>
                    </Box>
                    <Text dimColor wrap="truncate">
                      {pr.error !== '' ? `! ${pr.error}` : shortTitle(pr)}
                    </Text>
                    {isActive(pr) && (pr.approvers ?? []).length > 0 && (
                      <Text color="success" wrap="truncate">
                        ✓ onaylayan: {(pr.approvers ?? []).join(', ')}
                      </Text>
                    )}
                    {isActive(pr) && isStackedBase(pr.base) && (
                      <Text dimColor wrap="truncate">
                        ↳ {pr.base}
                      </Text>
                    )}
                  </Box>
                ))}
            </Box>
          )
        })}
      </Box>
    )
  })
}
