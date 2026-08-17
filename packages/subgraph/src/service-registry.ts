import { Address, BigInt, ethereum } from "@graphprotocol/graph-ts";
import { BossService, Provider, ProviderOfferNonce, ProviderSigner } from "../generated/schema";
import { chainId, recordLifecycle, scopedEntityId } from "./utils";

function providerEntityId(registry: Address, provider: Address): string {
  return scopedEntityId(registry, "provider:" + provider.toHexString());
}

function loadOrCreateProvider(event: ethereum.Event, providerAddress: Address): Provider {
  const id = providerEntityId(event.address, providerAddress);
  let provider = Provider.load(id);
  if (provider == null) {
    provider = new Provider(id);
    provider.chainId = chainId();
    provider.serviceRegistry = event.address;
    provider.address = providerAddress;
    provider.registered = false;
    provider.revision = BigInt.zero();
    provider.defaultBeneficiary = providerAddress;
    provider.metadataURI = "";
  }
  return provider as Provider;
}

export function handleProviderRegistered(event: ethereum.Event): void {
  const providerAddress = event.parameters[0].value.toAddress();
  const signingKey = event.parameters[1].value.toAddress();
  const revision = event.parameters[2].value.toBigInt();
  const beneficiary = event.parameters[3].value.toAddress();
  const metadataURI = event.parameters[4].value.toString();
  const provider = loadOrCreateProvider(event, providerAddress);

  provider.registered = true;
  provider.revision = revision;
  provider.defaultBeneficiary = beneficiary;
  provider.metadataURI = metadataURI;
  provider.save();

  const signerId = scopedEntityId(
    event.address,
    "provider-signer:" + providerAddress.toHexString() + ":" + signingKey.toHexString(),
  );
  const signer = new ProviderSigner(signerId);
  signer.provider = provider.id;
  signer.signingKey = signingKey;
  signer.active = true;
  signer.revision = revision;
  signer.updatedBlock = event.block.number;
  signer.updatedTransaction = event.transaction.hash;
  signer.save();

  recordLifecycle(event, "ProviderRegistered", provider.id);
}

export function handleProviderMetadataUpdated(event: ethereum.Event): void {
  const providerAddress = event.parameters[0].value.toAddress();
  const provider = loadOrCreateProvider(event, providerAddress);
  provider.registered = true;
  provider.revision = event.parameters[1].value.toBigInt();
  provider.defaultBeneficiary = event.parameters[2].value.toAddress();
  provider.metadataURI = event.parameters[3].value.toString();
  provider.save();
  recordLifecycle(event, "ProviderMetadataUpdated", provider.id);
}

export function handleProviderSigningKeyUpdated(event: ethereum.Event): void {
  const providerAddress = event.parameters[0].value.toAddress();
  const signingKey = event.parameters[1].value.toAddress();
  const provider = loadOrCreateProvider(event, providerAddress);
  const revision = event.parameters[3].value.toBigInt();
  provider.registered = true;
  provider.revision = revision;
  provider.save();

  const signerId = scopedEntityId(
    event.address,
    "provider-signer:" + providerAddress.toHexString() + ":" + signingKey.toHexString(),
  );
  let signer = ProviderSigner.load(signerId);
  if (signer == null) signer = new ProviderSigner(signerId);
  signer.provider = provider.id;
  signer.signingKey = signingKey;
  signer.active = event.parameters[2].value.toBoolean();
  signer.revision = revision;
  signer.updatedBlock = event.block.number;
  signer.updatedTransaction = event.transaction.hash;
  signer.save();

  recordLifecycle(event, "ProviderSigningKeyUpdated", signer.id);
}

export function handleServicePublished(event: ethereum.Event): void {
  const providerAddress = event.parameters[0].value.toAddress();
  const serviceId = event.parameters[1].value.toBytes();
  const provider = loadOrCreateProvider(event, providerAddress);
  const providerRevision = event.parameters[4].value.toBigInt();
  provider.registered = true;
  provider.revision = providerRevision;
  provider.save();

  const id = scopedEntityId(
    event.address,
    "service:" + providerAddress.toHexString() + ":" + serviceId.toHexString(),
  );
  let service = BossService.load(id);
  if (service == null) service = new BossService(id);
  service.chainId = chainId();
  service.serviceRegistry = event.address;
  service.provider = provider.id;
  service.providerAddress = providerAddress;
  service.serviceId = serviceId;
  service.serviceType = event.parameters[2].value.toBytes();
  service.version = event.parameters[3].value.toBigInt();
  service.providerRevision = providerRevision;
  service.metadataURI = event.parameters[5].value.toString();
  service.published = true;
  service.updatedBlock = event.block.number;
  service.updatedTransaction = event.transaction.hash;
  service.save();

  recordLifecycle(event, "ServicePublished", service.id);
}

export function handleOfferNonceRevoked(event: ethereum.Event): void {
  const providerAddress = event.parameters[0].value.toAddress();
  const nonce = event.parameters[1].value.toBigInt();
  const revision = event.parameters[2].value.toBigInt();
  const provider = loadOrCreateProvider(event, providerAddress);
  provider.registered = true;
  provider.revision = revision;
  provider.save();

  const id = scopedEntityId(
    event.address,
    "provider-nonce:" + providerAddress.toHexString() + ":" + nonce.toString(),
  );
  const revoked = new ProviderOfferNonce(id);
  revoked.provider = provider.id;
  revoked.nonce = nonce;
  revoked.revoked = true;
  revoked.revision = revision;
  revoked.updatedBlock = event.block.number;
  revoked.updatedTransaction = event.transaction.hash;
  revoked.save();

  recordLifecycle(event, "OfferNonceRevoked", revoked.id);
}
