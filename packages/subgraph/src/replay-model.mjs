const MAX_UINT256 = (1n << 256n) - 1n

export function createEmptyState() {
  return {
    accounts: new Map(),
    providers: new Map(),
    services: new Map(),
    adapters: new Map(),
    bundles: new Map(),
    subscriptions: new Map(),
    rails: new Map(),
    resources: new Map(),
    processedEventIds: new Set(),
  }
}

export function applyBossEvent(state, event) {
  if (state.processedEventIds.has(event.id)) return state
  state.processedEventIds.add(event.id)

  switch (event.kind) {
    case 'BossAccountCreated':
      state.accounts.set(event.account, {
        owner: event.owner,
        filecoinPay: event.filecoinPay,
        serviceRegistry: event.serviceRegistry,
        adapterRegistry: event.adapterRegistry,
        accountVersion: event.accountVersion,
      })
      break
    case 'ProviderRegistered':
    case 'ProviderMetadataUpdated':
      state.providers.set(event.provider, {
        ...(state.providers.get(event.provider) ?? {}),
        revision: event.revision,
        defaultBeneficiary: event.defaultBeneficiary,
        metadataURI: event.metadataURI,
        registered: true,
      })
      break
    case 'ServicePublished':
      state.services.set(`${event.provider}:${event.serviceId}`, {
        provider: event.provider,
        serviceId: event.serviceId,
        serviceType: event.serviceType,
        version: event.serviceVersion,
        metadataURI: event.metadataURI,
        published: true,
      })
      break
    case 'AdapterRegistered':
      state.adapters.set(event.adapter, {
        kind: event.adapterKind,
        interfaceVersion: event.interfaceVersion,
        codeHash: event.codeHash,
        observedCodeHash: event.codeHash,
        active: event.active ?? true,
        metadataURI: event.metadataURI,
      })
      break
    case 'AdapterActivationChanged': {
      const adapter = requireEntity(state.adapters, event.adapter, 'adapter')
      adapter.active = event.active
      adapter.observedCodeHash = event.observedCodeHash
      break
    }
    case 'BundleCreated':
      state.bundles.set(event.bundleId, {
        owner: event.owner,
        account: event.account,
        resourceKey: event.resourceKey,
        manifestHash: event.manifestHash,
        version: event.version,
        componentCount: event.componentCount,
        components: [],
      })
      break
    case 'BundleComponentAdded': {
      const bundle = requireEntity(state.bundles, event.bundleId, 'bundle')
      if (!bundle.components.includes(event.subscriptionId)) bundle.components.push(event.subscriptionId)
      break
    }
    case 'SubscriptionAccepted': {
      if (state.subscriptions.has(event.subscriptionId)) throw new Error(`duplicate subscription acceptance: ${event.subscriptionId}`)
      const subscription = {
        account: event.account,
        subscriptionId: event.subscriptionId,
        railId: event.railId,
        resourceKey: event.resourceKey,
        provider: event.provider,
        state: 'ACCEPTED',
        ratePerEpoch: event.ratePerEpoch,
        fixedBudget: event.fixedBudget,
        lifetimeCapGross: event.lifetimeCapGross,
        totalRawGross: 0n,
        totalChargedGross: 0n,
        claimCount: 0,
        claimIds: new Set(),
        finalSettledEpoch: 0n,
      }
      state.subscriptions.set(event.subscriptionId, subscription)
      state.rails.set(event.railId.toString(), event.subscriptionId)
      const resourceSubscriptions = state.resources.get(event.resourceKey) ?? new Set()
      resourceSubscriptions.add(event.subscriptionId)
      state.resources.set(event.resourceKey, resourceSubscriptions)
      break
    }
    case 'ProviderActivationAcknowledged':
      requireSubscription(state, event).provisioningHash = event.provisioningHash
      break
    case 'SubscriptionActivated': {
      const subscription = requireSubscription(state, event)
      subscription.state = 'ACTIVE'
      subscription.activatedEpoch = event.activatedEpoch
      break
    }
    case 'RateSynchronized': {
      const subscription = requireSubscription(state, event)
      subscription.ratePerEpoch = event.ratePerEpoch
      subscription.quoteEpoch = event.quoteEpoch ?? subscription.quoteEpoch
      subscription.quoteValidThroughEpoch = event.validThroughEpoch ?? subscription.quoteValidThroughEpoch
      subscription.resourceStatusHash = event.resourceStatusHash ?? subscription.resourceStatusHash
      break
    }
    case 'SubscriptionPaused': {
      const subscription = requireSubscription(state, event)
      subscription.state = 'PAUSED'
      subscription.pausedEpoch = event.pausedEpoch
      break
    }
    case 'PauseRateUpdateDeferred':
      requireSubscription(state, event).pauseRateUpdateDeferred = true
      break
    case 'SubscriptionResumed': {
      const subscription = requireSubscription(state, event)
      subscription.state = 'ACTIVE'
      subscription.resumedEpoch = event.resumedEpoch
      break
    }
    case 'SubscriptionTerminationRequested': {
      const subscription = requireSubscription(state, event)
      subscription.state = 'TERMINATING'
      subscription.terminationRequestedEpoch = event.requestEpoch
      break
    }
    case 'SubscriptionPayTerminationObserved': {
      const subscription = requireSubscription(state, event)
      subscription.state = 'TERMINATING'
      subscription.payEndEpoch = event.endEpoch
      break
    }
    case 'SubscriptionEnded': {
      const subscription = requireSubscription(state, event)
      subscription.state = 'ENDED'
      subscription.finalSettledEpoch = event.finalSettledEpoch
      break
    }
    case 'AccessGrantCommitted':
      requireSubscription(state, event).accessGrantHash = event.accessGrantHash
      break
    case 'UsageClaimCharged': {
      const subscription = requireSubscription(state, event)
      if (subscription.claimIds.has(event.claimId)) break
      subscription.claimIds.add(event.claimId)
      subscription.claimCount += 1
      subscription.totalRawGross += event.rawGross
      subscription.totalChargedGross += event.chargedGross
      subscription.fixedBudget = maxZero(subscription.fixedBudget - event.chargedGross)
      if (subscription.fixedBudget === 0n || lifetimeExhausted(subscription)) subscription.state = 'EXHAUSTED'
      break
    }
    case 'FixedBudgetToppedUp': {
      const subscription = requireSubscription(state, event)
      subscription.fixedBudget = event.newFixedBudget
      if (subscription.state === 'EXHAUSTED' && event.newFixedBudget > 0n && !lifetimeExhausted(subscription)) {
        subscription.state = 'ACTIVE'
      }
      break
    }
    default:
      throw new Error(`unsupported Boss event kind: ${event.kind}`)
  }

  return state
}

function requireSubscription(state, event) {
  return requireEntity(state.subscriptions, event.subscriptionId, 'subscription')
}

function requireEntity(map, id, name) {
  const value = map.get(id)
  if (!value) throw new Error(`unknown ${name}: ${id}`)
  return value
}

function lifetimeExhausted(subscription) {
  return (
    typeof subscription.lifetimeCapGross === 'bigint' &&
    subscription.lifetimeCapGross !== MAX_UINT256 &&
    subscription.totalChargedGross >= subscription.lifetimeCapGross
  )
}

function maxZero(value) {
  return value < 0n ? 0n : value
}
