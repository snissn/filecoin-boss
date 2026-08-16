import assert from 'node:assert/strict'
import { performance } from 'node:perf_hooks'
import { applyBossEvent, createEmptyState } from '../src/replay-model.mjs'

const subscriptions = 1_000
const updatesPerSubscription = 99
const totalEvents = subscriptions * (updatesPerSubscription + 1)
const blocks = 1_000
let state = createEmptyState()
const started = performance.now()

for (let index = 0; index < subscriptions; index += 1) {
  const subscriptionId = `0x${index.toString(16).padStart(64, '0')}`
  const account = `0x${(index + 1).toString(16).padStart(40, '0')}`
  const resourceKey = `0x${(index + 2_000).toString(16).padStart(64, '0')}`
  state = applyBossEvent(state, {
    id: `${index % blocks}:0:${index}`,
    kind: 'SubscriptionAccepted',
    account,
    subscriptionId,
    railId: BigInt(index + 1),
    resourceKey,
    provider: '0x4444444444444444444444444444444444444444',
    ratePerEpoch: 1n,
    fixedBudget: 100n,
  })

  for (let update = 0; update < updatesPerSubscription; update += 1) {
    state = applyBossEvent(state, {
      id: `${(index + update + 1) % blocks}:${update + 1}:${index}`,
      kind: 'RateSynchronized',
      subscriptionId,
      ratePerEpoch: BigInt(update + 2),
    })
  }
}

const elapsedMs = performance.now() - started
assert.equal(state.processedEventIds.size, totalEvents)
assert.equal(state.subscriptions.size, subscriptions)
assert.equal(state.rails.size, subscriptions)
assert.equal(state.resources.size, subscriptions)
assert.ok(elapsedMs < 10_000, `100k-event replay exceeded 10 seconds: ${elapsedMs.toFixed(2)}ms`)

console.log(
  JSON.stringify({
    events: totalEvents,
    blocks,
    subscriptions,
    elapsedMs: Number(elapsedMs.toFixed(2)),
    eventsPerSecond: Number((totalEvents / (elapsedMs / 1_000)).toFixed(2)),
  })
)
