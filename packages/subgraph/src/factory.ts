import { ethereum } from "@graphprotocol/graph-ts";
import { BossAccount } from "../generated/schema";
import { BossAccountTemplate } from "../generated/templates";
import { accountEntityId, chainId, recordLifecycle } from "./utils";

export function handleBossAccountCreated(event: ethereum.Event): void {
  const owner = event.parameters[0].value.toAddress();
  const accountAddress = event.parameters[1].value.toAddress();
  const filecoinPay = event.parameters[2].value.toAddress();
  const serviceRegistry = event.parameters[3].value.toAddress();
  const adapterRegistry = event.parameters[4].value.toAddress();
  const accountVersion = event.parameters[5].value.toBigInt();
  const accountKey = event.parameters[6].value.toBytes();
  const id = accountEntityId(accountAddress);

  const account = new BossAccount(id);
  account.chainId = chainId();
  account.factory = event.address;
  account.address = accountAddress;
  account.owner = owner;
  account.filecoinPay = filecoinPay;
  account.serviceRegistry = serviceRegistry;
  account.adapterRegistry = adapterRegistry;
  account.accountVersion = accountVersion;
  account.accountKey = accountKey;
  account.createdBlock = event.block.number;
  account.createdTransaction = event.transaction.hash;
  account.save();

  BossAccountTemplate.create(accountAddress);
  recordLifecycle(event, "BossAccountCreated", id);
}
