import { ethereum } from "@graphprotocol/graph-ts";
import { Bundle, BundleComponent } from "../generated/schema";
import { accountEntityId, chainId, recordLifecycle, scopedEntityId } from "./utils";

function bundleEntityId(event: ethereum.Event): string {
  return scopedEntityId(event.address, "bundle:" + event.parameters[0].value.toBytes().toHexString());
}

export function handleBundleCreated(event: ethereum.Event): void {
  const id = bundleEntityId(event);
  const accountAddress = event.parameters[2].value.toAddress();
  const bundle = new Bundle(id);
  bundle.chainId = chainId();
  bundle.bundleRegistry = event.address;
  bundle.bundleId = event.parameters[0].value.toBytes();
  bundle.owner = event.parameters[1].value.toAddress();
  bundle.account = accountEntityId(accountAddress);
  bundle.accountAddress = accountAddress;
  bundle.resourceKey = event.parameters[3].value.toBytes();
  bundle.manifestHash = event.parameters[4].value.toBytes();
  bundle.version = event.parameters[5].value.toBigInt();
  bundle.componentCount = event.parameters[6].value.toBigInt();
  bundle.createdBlock = event.block.number;
  bundle.createdTransaction = event.transaction.hash;
  bundle.save();
  recordLifecycle(event, "BundleCreated", bundle.id);
}

export function handleBundleComponentAdded(event: ethereum.Event): void {
  const bundleId = bundleEntityId(event);
  const index = event.parameters[2].value.toBigInt();
  const id = scopedEntityId(
    event.address,
    "bundle-component:" + event.parameters[0].value.toBytes().toHexString() + ":" + index.toString(),
  );
  const component = new BundleComponent(id);
  component.bundle = bundleId;
  component.subscriptionId = event.parameters[1].value.toBytes();
  component.index = index;
  component.createdBlock = event.block.number;
  component.createdTransaction = event.transaction.hash;
  component.save();
  recordLifecycle(event, "BundleComponentAdded", component.id);
}
