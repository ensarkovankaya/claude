// Usage: node scan-transcript.mjs <transcript.jsonl> <patterns-json>
// Ana transcript + <id>/subagents/*.jsonl içinde PR açan Bash komutlarının sonuçlarındaki PR URL'lerini çıkarır.
// patterns-json: [[regexSource, ...], ...] — bir grup içindeki tüm regex'ler eşleşirse komut PR açan sayılır.
import { createReadStream, existsSync, readdirSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { createInterface } from 'node:readline'

const [transcript, patternsJson] = process.argv.slice(2)
const groups = JSON.parse(patternsJson).map(group => group.map(source => new RegExp(source)))
const isPrCreate = command => groups.some(group => group.every(re => re.test(command)))
const PR_URL = /https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/pull\/(\d+)/g

const textOf = content =>
  typeof content === 'string' ? content : Array.isArray(content) ? content.map(block => block?.text ?? '').join('\n') : ''

async function scanFile(path, found) {
  const pending = new Set()
  const lines = createInterface({ input: createReadStream(path), crlfDelay: Infinity })
  for await (const line of lines) {
    if (!line.includes('"tool_use"') && !line.includes('"tool_result"')) {
      continue
    }
    let row
    try {
      row = JSON.parse(line)
    } catch {
      continue
    }
    const blocks = row?.message?.content
    if (!Array.isArray(blocks)) {
      continue
    }
    const at = Date.parse(row.timestamp ?? '') || 0
    for (const block of blocks) {
      if (block?.type === 'tool_use' && block.name === 'Bash' && isPrCreate(String(block.input?.command ?? ''))) {
        pending.add(block.id)
      } else if (block?.type === 'tool_result' && pending.has(block.tool_use_id)) {
        pending.delete(block.tool_use_id)
        for (const m of textOf(block.content).matchAll(PR_URL)) {
          const url = `https://github.com/${m[1]}/${m[2]}/pull/${m[3]}`
          if (!found.has(url) || found.get(url) > at) {
            found.set(url, at)
          }
        }
      }
    }
  }
}

const found = new Map()
const files = [transcript]
const subagents = join(dirname(transcript), basename(transcript, '.jsonl'), 'subagents')
if (existsSync(subagents)) {
  for (const name of readdirSync(subagents)) {
    if (name.endsWith('.jsonl')) {
      files.push(join(subagents, name))
    }
  }
}
for (const file of files) {
  await scanFile(file, found)
}
process.stdout.write(JSON.stringify({ files: files.length, prs: [...found].map(([url, at]) => ({ url, at })) }))
