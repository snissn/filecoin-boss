import { BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import { Adapter, Governance } from "../generated/schema";
import { chainId, recordLifecycle, scopedEntityId } from "./utils";

function adapterEntityId(event: ethereum.Event): string {
  return scopedEntityId(event.address, "adapter:" + event.parameters[0].value.toAddress().toHexString());
}

export function handleGovernanceTransferred(event: ethereum.Event): void {
  const id = scopedEntityId(event.address, "governance");
  let governance = Governance.load(id);
  if (governance == null) governance = new Governance(id);
  governance.chainId = chainId();
  governance.adapterRegistry = event.address;
  governance.previousGovernance = event.parameters[0].value.toAddress();
  governance.currentGovernance = event.parameters[1].value.toAddress();
  governance.updatedBlock = event.block.number;
  governance.updatedTransaction = event.transaction.hash;
  governance.save();
  recordLifecycle(event, "GovernanceTransferred", governance.id);
}

export function handleAdapterRegistered(event: ethereum.Event): void {
  const id = adapterEntityId(event);
  const adapter = new Adapter(id);
  adapter.chainId = chainId();
  adapter.adapterRegistry = event.address;
  adapter.address = event.parameters[0].value.toAddress();
  adapter.kind = event.parameters[1].value.toI32();
  adapter.interfaceVersion = event.parameters[2].value.toBigInt();
  adapter.codeHash = event.parameters[3].value.toBytes();
  adapter.observedCodeHash = event.parameters[3].value.toBytes();
  adapter.activeForNewSubscriptions = true;
  adapter.metadataURI = event.parameters[4].value.toString();
  adapter.updatedBlock = event.block.number;
  adapter.updatedTransaction = event.transaction.hash;
  adapter.save();
  recordLifecycle(event, "AdapterRegistered", adapter.id);
}

export function handleAdapterActivationChanged(event: ethereum.Event): void {
  const id = adapterEntityId(event);
  let adapter = Adapter.load(id);
  if (adapter == null) {
    adapter = new Adapter(id);
    adapter.chainId = chainId();
    adapter.adapterRegistry = event.address;
    adapter.address = event.parameters[0].value.toAddress();
    adapter.kind = 0;
    adapter.interfaceVersion = BigInt.zero();
    adapter.codeHash = Bytes.empty();
    adapter.metadataURI = "";
  }
  adapter.activeForNewSubscriptions = event.parameters[1].value.toBoolean();
  adapter.observedCodeHash = event.parameters[2].value.toBytes();
  adapter.updatedBlock = event.block.number;
  adapter.updatedTransaction = event.transaction.hash;
  adapter.save();
  recordLifecycle(event, "AdapterActivationChanged", adapter.id);
}
