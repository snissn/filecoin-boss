import assert from 'node:assert/strict'
import test from 'node:test'
import { applyBossEvent, createEmptyState } from '../src/replay-model.mjs'

const acceptance = {
  id: '0xaaa:0',
  kind: 'SubscriptionAccepted',
  account: '0x1111111111111111111111111111111111111111',
  subscriptionId: '0x' + '22'.repeat(32),
  railId: 7n,
  resourceKey: '0x' + '33'.repeat(32),
  provider: '0x4444444444444444444444444444444444444444',
  ratePerEpoch: 10n,
  fixedBudget: 50n,
}

test('replays the complete Boss lifecycle without double-counting duplicate logs', () => {
  let state = createEmptyState()
  const events = [
    acceptance,
    { id: '0xaaa:1', kind: 'SubscriptionActivated', subscriptionId: acceptance.subscriptionId, activatedEpoch: 100n },
    { id: '0xbbb:0', kind: 'RateSynchronized', subscriptionId: acceptance.subscriptionId, ratePerEpoch: 12n },
    { id: '0xbbb:1', kind: 'SubscriptionPaused', subscriptionId: acceptance.subscriptionId },
    { id: '0xbbb:2', kind: 'SubscriptionResumed', subscriptionId: acceptance.subscriptionId },
    {
      id: '0xccc:0',
      kind: 'UsageClaimCharged',
      subscriptionId: acceptance.subscriptionId,
      claimId: '0x' + '55'.repeat(32),
      rawGross: 5n,
      chargedGross: 3n,
    },
    { id: '0xccc:1', kind: 'FixedBudgetToppedUp', subscriptionId: acceptance.subscriptionId, newFixedBudget: 70n },
    { id: '0xddd:0', kind: 'SubscriptionTerminationRequested', subscriptionId: acceptance.subscriptionId },
    { id: '0xddd:1', kind: 'SubscriptionEnded', subscriptionId: acceptance.subscriptionId, finalSettledEpoch: 120n },
  ]

  for (const event of events) state = applyBossEvent(state, event)
  state = applyBossEvent(state, events[5])

  const subscription = state.subscriptions.get(acceptance.subscriptionId)
  assert.ok(subscription)
  assert.equal(subscription.state, 'ENDED')
  assert.equal(subscription.ratePerEpoch, 12n)
  assert.equal(subscription.fixedBudget, 70n)
  assert.equal(subscription.totalChargedGross, 3n)
  assert.equal(subscription.claimCount, 1)
  assert.equal(subscription.finalSettledEpoch, 120n)
  assert.equal(state.rails.get('7'), acceptance.subscriptionId)
  assert.equal(state.resources.get(acceptance.resourceKey), acceptance.subscriptionId)
  assert.equal(state.processedEventIds.size, events.length)
})
