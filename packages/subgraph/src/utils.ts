import { Address, BigInt, Bytes, dataSource, ethereum } from "@graphprotocol/graph-ts";
import { LifecycleEvent } from "../generated/schema";

export function chainId(): BigInt {
  const network = dataSource.network();
  if (network == "filecoin") return BigInt.fromI32(314);
  if (network == "filecoin-testnet") return BigInt.fromI32(314159);
  return BigInt.fromI32(1337);
}

export function accountEntityId(account: Address): string {
  return chainId().toString() + ":" + account.toHexString();
}

export function scopedEntityId(contractAddress: Address, semanticId: string): string {
  return chainId().toString() + ":" + contractAddress.toHexString() + ":" + semanticId;
}

export function subscriptionEntityId(account: Address, subscriptionId: Bytes): string {
  return scopedEntityId(account, subscriptionId.toHexString());
}

export function railSubscriptionEntityId(account: Address, railId: BigInt): string {
  return scopedEntityId(account, "rail:" + railId.toString());
}

export function resourceSubscriptionEntityId(
  account: Address,
  resourceKey: Bytes,
  subscriptionId: Bytes,
): string {
  return scopedEntityId(account, "resource:" + resourceKey.toHexString() + ":" + subscriptionId.toHexString());
}

export function eventEntityId(event: ethereum.Event): string {
  return (
    chainId().toString() +
    ":" +
    event.address.toHexString() +
    ":" +
    event.transaction.hash.toHexString() +
    ":" +
    event.logIndex.toString()
  );
}

export function recordLifecycle(event: ethereum.Event, kind: string, subjectId: string): void {
  const entity = new LifecycleEvent(eventEntityId(event));
  entity.chainId = chainId();
  entity.contractAddress = event.address;
  entity.subjectId = subjectId;
  entity.kind = kind;
  entity.transactionHash = event.transaction.hash;
  entity.blockNumber = event.block.number;
  entity.logIndex = event.logIndex;
  entity.save();
}

export function byteLane(word: BigInt, divisor: string): i32 {
  return word.div(BigInt.fromString(divisor)).mod(BigInt.fromI32(256)).toI32();
}

export function boolLane(word: BigInt, divisor: string): boolean {
  return word.div(BigInt.fromString(divisor)).mod(BigInt.fromI32(2)).equals(BigInt.fromI32(1));
}

export function uint64Lane(word: BigInt, lane: i32): BigInt {
  const base = BigInt.fromString("18446744073709551616");
  if (lane == 0) return word.mod(base);
  if (lane == 1) return word.div(base).mod(base);
  return word.div(base.times(base)).mod(base);
}
