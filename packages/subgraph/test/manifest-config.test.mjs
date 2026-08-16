import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import {
  buildSubgraphConfig,
  renderSubgraphYaml,
  SUBSCRIPTION_ACCEPTED_SIGNATURE,
} from '../src/manifest-config.mjs'

const authority = {
  protocolCommit: '4a7bd35801ea6bc0521f942f48a9b7a713172bc0',
  accountCreationCodeHash: '0x6ad8c166cdf9aa41ded2dd7be3fb38ab96b87265d1c4c7a5d0bf05307e7490bb',
}

const deployment = (digit, block) => ({
  address: `0x${digit.repeat(40)}`,
  runtimeCodeHash: `0x${digit.repeat(64)}`,
  deploymentTxHash: `0x${(Number(digit) + 1).toString(16).repeat(64)}`,
  deploymentBlock: block,
})

const manifest = {
  schemaVersion: 1,
  network: 'filecoin-testnet',
  chainId: 314159,
  protocolCommit: authority.protocolCommit,
  accountCreationCodeHash: authority.accountCreationCodeHash,
  deploymentBlock: 500,
  dependencies: {
    filecoinPay: '0x' + 'a'.repeat(40),
    pdpVerifier: '0x' + 'b'.repeat(40),
    fwssService: '0x' + 'c'.repeat(40),
    fwssStateView: '0x' + 'd'.repeat(40),
    token: '0x' + 'e'.repeat(40),
  },
  contracts: {
    BossFactory: deployment('1', 501),
    BossServiceRegistry: deployment('2', 502),
    BossAdapterRegistry: deployment('3', 503),
    BossBundles: deployment('4', 504),
    BossStateView: deployment('5', 505),
  },
}

test('derives every indexed address and its own deployment block from one verified manifest', () => {
  assert.deepEqual(buildSubgraphConfig(manifest, authority), {
    network: 'filecoin-testnet',
    chainId: 314159,
    protocolCommit: authority.protocolCommit,
    manifestStartBlock: 500,
    bossFactoryAddress: manifest.contracts.BossFactory.address,
    bossFactoryStartBlock: 501,
    bossServiceRegistryAddress: manifest.contracts.BossServiceRegistry.address,
    bossServiceRegistryStartBlock: 502,
    bossAdapterRegistryAddress: manifest.contracts.BossAdapterRegistry.address,
    bossAdapterRegistryStartBlock: 503,
    bossBundlesAddress: manifest.contracts.BossBundles.address,
    bossBundlesStartBlock: 504,
  })
})

test('binds SubscriptionAccepted to the exact packaged BossAccount ABI', () => {
  const abi = JSON.parse(readFileSync(new URL('../../contracts/abi/BossAccount.json', import.meta.url), 'utf8'))
  const event = abi.find((entry) => entry.type === 'event' && entry.name === 'SubscriptionAccepted')
  assert.ok(event)
  const signature = `${event.name}(${event.inputs
    .map((input) => `${input.indexed ? 'indexed ' : ''}${input.type}`)
    .join(',')})`
  assert.equal(SUBSCRIPTION_ACCEPTED_SIGNATURE, signature)
  assert.match(renderSubgraphYaml(buildSubgraphConfig(manifest, authority)), new RegExp(escapeRegex(signature)))
})

test('fails closed on source-authority drift, zero addresses, unsupported networks, or network/chain mismatches', () => {
  assert.throws(() => buildSubgraphConfig({ ...manifest, protocolCommit: '0'.repeat(40) }, authority))
  assert.throws(() =>
    buildSubgraphConfig(
      {
        ...manifest,
        contracts: {
          ...manifest.contracts,
          BossFactory: { ...manifest.contracts.BossFactory, address: '0x' + '0'.repeat(40) },
        },
      },
      authority
    )
  )
  assert.throws(() => buildSubgraphConfig({ ...manifest, network: 'unknown-network' }, authority))
  assert.throws(() => buildSubgraphConfig({ ...manifest, network: 'filecoin', chainId: 314159 }, authority))
  assert.throws(() => buildSubgraphConfig({ ...manifest, network: 'filecoin-testnet', chainId: 314 }, authority))
  assert.doesNotThrow(() => buildSubgraphConfig({ ...manifest, network: 'localhost', chainId: 1337 }, authority))
})

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}
