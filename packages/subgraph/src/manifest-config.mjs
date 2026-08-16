const ADDRESS = /^0x[0-9a-fA-F]{40}$/
const HASH = /^0x[0-9a-fA-F]{64}$/
const COMMIT = /^[0-9a-f]{40}$/
const ZERO_ADDRESS = `0x${'0'.repeat(40)}`
const SUPPORTED_NETWORKS = new Set(['filecoin', 'filecoin-testnet', 'localhost'])
const REQUIRED_CONTRACTS = ['BossFactory', 'BossServiceRegistry', 'BossAdapterRegistry', 'BossBundles', 'BossStateView']

export function buildSubgraphConfig(manifest, authority) {
  requireObject(manifest, 'manifest')
  requireObject(authority, 'authority')
  if (manifest.schemaVersion !== 1) throw new Error('Unsupported Boss deployment schema version')
  if (!SUPPORTED_NETWORKS.has(manifest.network)) throw new Error(`Unsupported Graph network: ${manifest.network}`)
  if (!Number.isSafeInteger(manifest.chainId) || manifest.chainId <= 0) throw new Error('chainId must be a positive safe integer')
  if (!COMMIT.test(manifest.protocolCommit) || manifest.protocolCommit !== authority.protocolCommit) {
    throw new Error('Boss protocol commit does not match packaged artifact authority')
  }
  if (!HASH.test(manifest.accountCreationCodeHash) || !equalHex(manifest.accountCreationCodeHash, authority.accountCreationCodeHash)) {
    throw new Error('Boss account creation-code hash does not match packaged artifact authority')
  }

  requireObject(manifest.contracts, 'manifest.contracts')
  for (const name of REQUIRED_CONTRACTS) validateDeployment(name, manifest.contracts[name])

  const deploymentBlocks = REQUIRED_CONTRACTS.map((name) => manifest.contracts[name].deploymentBlock)
  const manifestStartBlock = manifest.deploymentBlock ?? Math.min(...deploymentBlocks)
  if (!Number.isSafeInteger(manifestStartBlock) || manifestStartBlock < 0) throw new Error('deploymentBlock must be a non-negative safe integer')

  return {
    network: manifest.network,
    chainId: manifest.chainId,
    protocolCommit: manifest.protocolCommit,
    manifestStartBlock,
    bossFactoryAddress: manifest.contracts.BossFactory.address,
    bossFactoryStartBlock: manifest.contracts.BossFactory.deploymentBlock,
    bossServiceRegistryAddress: manifest.contracts.BossServiceRegistry.address,
    bossServiceRegistryStartBlock: manifest.contracts.BossServiceRegistry.deploymentBlock,
    bossAdapterRegistryAddress: manifest.contracts.BossAdapterRegistry.address,
    bossAdapterRegistryStartBlock: manifest.contracts.BossAdapterRegistry.deploymentBlock,
    bossBundlesAddress: manifest.contracts.BossBundles.address,
    bossBundlesStartBlock: manifest.contracts.BossBundles.deploymentBlock,
  }
}

export function renderSubgraphYaml(config) {
  requireObject(config, 'config')
  return `specVersion: 1.2.0
description: Manifest-driven Filecoin Boss event index
repository: https://github.com/snissn/filecoin-boss
indexerHints:
  prune: auto
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum
    name: BossFactory
    network: "${config.network}"
    source:
      abi: BossFactory
      address: "${config.bossFactoryAddress}"
      startBlock: ${config.bossFactoryStartBlock}
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      entities: [BossAccount, LifecycleEvent]
      abis:
        - name: BossFactory
          file: ../contracts/abi/BossFactory.json
      eventHandlers:
        - event: BossAccountCreated(indexed address,indexed address,indexed address,address,address,uint64,bytes32)
          handler: handleBossAccountCreated
      file: ./src/factory.ts
  - kind: ethereum
    name: BossServiceRegistry
    network: "${config.network}"
    source:
      abi: BossServiceRegistry
      address: "${config.bossServiceRegistryAddress}"
      startBlock: ${config.bossServiceRegistryStartBlock}
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      entities: [Provider, ProviderSigner, ProviderOfferNonce, BossService, LifecycleEvent]
      abis:
        - name: BossServiceRegistry
          file: ../contracts/abi/BossServiceRegistry.json
      eventHandlers:
        - event: ProviderRegistered(indexed address,indexed address,uint64,address,string)
          handler: handleProviderRegistered
        - event: ProviderMetadataUpdated(indexed address,uint64,address,string)
          handler: handleProviderMetadataUpdated
        - event: ProviderSigningKeyUpdated(indexed address,indexed address,bool,uint64)
          handler: handleProviderSigningKeyUpdated
        - event: ServicePublished(indexed address,indexed bytes32,bytes32,uint64,uint64,string)
          handler: handleServicePublished
        - event: OfferNonceRevoked(indexed address,indexed uint256,uint64)
          handler: handleOfferNonceRevoked
      file: ./src/service-registry.ts
  - kind: ethereum
    name: BossAdapterRegistry
    network: "${config.network}"
    source:
      abi: BossAdapterRegistry
      address: "${config.bossAdapterRegistryAddress}"
      startBlock: ${config.bossAdapterRegistryStartBlock}
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      entities: [Adapter, Governance, LifecycleEvent]
      abis:
        - name: BossAdapterRegistry
          file: ../contracts/abi/BossAdapterRegistry.json
      eventHandlers:
        - event: GovernanceTransferred(indexed address,indexed address)
          handler: handleGovernanceTransferred
        - event: AdapterRegistered(indexed address,uint8,uint64,bytes32,string)
          handler: handleAdapterRegistered
        - event: AdapterActivationChanged(indexed address,bool,bytes32)
          handler: handleAdapterActivationChanged
      file: ./src/adapter-registry.ts
  - kind: ethereum
    name: BossBundles
    network: "${config.network}"
    source:
      abi: BossBundles
      address: "${config.bossBundlesAddress}"
      startBlock: ${config.bossBundlesStartBlock}
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      entities: [Bundle, BundleComponent, LifecycleEvent]
      abis:
        - name: BossBundles
          file: ../contracts/abi/BossBundles.json
      eventHandlers:
        - event: BundleCreated(indexed bytes32,indexed address,indexed address,bytes32,bytes32,uint64,uint256)
          handler: handleBundleCreated
        - event: BundleComponentAdded(indexed bytes32,indexed bytes32,uint256)
          handler: handleBundleComponentAdded
      file: ./src/bundles.ts
templates:
  - kind: ethereum
    name: BossAccountTemplate
    network: "${config.network}"
    source:
      abi: BossAccount
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      entities: [Subscription, RailSubscription, ResourceSubscription, UsageClaim, RateUpdate, BudgetUpdate, LifecycleEvent]
      abis:
        - name: BossAccount
          file: ../contracts/abi/BossAccount.json
      eventHandlers:
        - event: SubscriptionAccepted(indexed bytes32,indexed address,indexed bytes32,bytes32,address,address,uint256,address,address,address,address,address,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)
          handler: handleSubscriptionAccepted
        - event: ProviderActivationAcknowledged(indexed bytes32,bytes32)
          handler: handleProviderActivationAcknowledged
        - event: SubscriptionActivated(indexed bytes32,uint64)
          handler: handleSubscriptionActivated
        - event: RateSynchronized(indexed bytes32,uint256,uint256,uint64,uint64,bytes32)
          handler: handleRateSynchronized
        - event: SubscriptionPaused(indexed bytes32,uint64)
          handler: handleSubscriptionPaused
        - event: PauseRateUpdateDeferred(indexed bytes32,bytes)
          handler: handlePauseRateUpdateDeferred
        - event: SubscriptionResumed(indexed bytes32,uint64)
          handler: handleSubscriptionResumed
        - event: SubscriptionTerminationRequested(indexed bytes32,uint64)
          handler: handleSubscriptionTerminationRequested
        - event: SubscriptionPayTerminationObserved(indexed bytes32,indexed uint256,uint256)
          handler: handleSubscriptionPayTerminationObserved
        - event: SubscriptionEnded(indexed bytes32,uint64)
          handler: handleSubscriptionEnded
        - event: AccessGrantCommitted(indexed bytes32,bytes32)
          handler: handleAccessGrantCommitted
        - event: UsageClaimCharged(indexed bytes32,indexed bytes32,bytes32,uint256,uint256,uint256,bytes32)
          handler: handleUsageClaimCharged
        - event: FixedBudgetToppedUp(indexed bytes32,uint256,uint256)
          handler: handleFixedBudgetToppedUp
      file: ./src/account.ts
`
}

function validateDeployment(name, deployment) {
  requireObject(deployment, `manifest.contracts.${name}`)
  if (!ADDRESS.test(deployment.address) || equalHex(deployment.address, ZERO_ADDRESS)) throw new Error(`${name} has an invalid address`)
  if (!HASH.test(deployment.runtimeCodeHash)) throw new Error(`${name} has an invalid runtimeCodeHash`)
  if (!HASH.test(deployment.deploymentTxHash)) throw new Error(`${name} has an invalid deploymentTxHash`)
  if (!Number.isSafeInteger(deployment.deploymentBlock) || deployment.deploymentBlock < 0) throw new Error(`${name} has an invalid deploymentBlock`)
}

function requireObject(value, name) {
  if (value == null || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${name} must be an object`)
}

function equalHex(left, right) {
  return typeof left === 'string' && typeof right === 'string' && left.toLowerCase() === right.toLowerCase()
}
