import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import { afterEach, assert, clearStore, describe, newMockEvent, test } from "matchstick-as";
import {
  handleFixedBudgetToppedUp,
  handleSubscriptionActivated,
  handleSubscriptionAccepted,
  handleSubscriptionEnded,
  handleSubscriptionTerminationRequested,
  handleUsageClaimCharged,
} from "../src/account";
import { handleBossAccountCreated } from "../src/factory";

class Fixtures {
  static FACTORY: Address = Address.fromString("0x1111111111111111111111111111111111111111");
  static ACCOUNT: Address = Address.fromString("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
  static OWNER: Address = Address.fromString("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
  static PAY: Address = Address.fromString("0xcccccccccccccccccccccccccccccccccccccccc");
  static SERVICE_REGISTRY: Address = Address.fromString("0x2222222222222222222222222222222222222222");
  static ADAPTER_REGISTRY: Address = Address.fromString("0x3333333333333333333333333333333333333333");
  static BENEFICIARY: Address = Address.fromString("0xdddddddddddddddddddddddddddddddddddddddd");
  static TOKEN: Address = Address.fromString("0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");
  static PROVIDER: Address = Address.fromString("0x9999999999999999999999999999999999999999");
  static REPORTER: Address = Address.fromString("0x8888888888888888888888888888888888888888");
  static RESOURCE_ADAPTER: Address = Address.fromString("0x7777777777777777777777777777777777777777");
  static PRICING_ADAPTER: Address = Address.fromString("0x6666666666666666666666666666666666666666");
  static ACCOUNT_KEY: Bytes = Bytes.fromHexString(
    "0x0101010101010101010101010101010101010101010101010101010101010101",
  ) as Bytes;
  static SUBSCRIPTION: Bytes = Bytes.fromHexString(
    "0x0202020202020202020202020202020202020202020202020202020202020202",
  ) as Bytes;
  static OFFER: Bytes = Bytes.fromHexString(
    "0x0303030303030303030303030303030303030303030303030303030303030303",
  ) as Bytes;
  static RESOURCE: Bytes = Bytes.fromHexString(
    "0x0404040404040404040404040404040404040404040404040404040404040404",
  ) as Bytes;
  static RESOURCE_DATA: Bytes = Bytes.fromHexString(
    "0x0505050505050505050505050505050505050505050505050505050505050505",
  ) as Bytes;
  static PRICING_DATA: Bytes = Bytes.fromHexString(
    "0x0606060606060606060606060606060606060606060606060606060606060606",
  ) as Bytes;
  static ACCESS_GRANT: Bytes = Bytes.fromHexString(
    "0x0707070707070707070707070707070707070707070707070707070707070707",
  ) as Bytes;
  static CLAIM_ID: Bytes = Bytes.fromHexString(
    "0x0808080808080808080808080808080808080808080808080808080808080808",
  ) as Bytes;
  static CLAIM_HASH: Bytes = Bytes.fromHexString(
    "0x0909090909090909090909090909090909090909090909090909090909090909",
  ) as Bytes;
  static EVIDENCE_HASH: Bytes = Bytes.fromHexString(
    "0x1010101010101010101010101010101010101010101010101010101010101010",
  ) as Bytes;
}

function mockEvent(address: Address, blockNumber: i32, logIndex: i32): ethereum.Event {
  const event = newMockEvent();
  event.address = address;
  event.block.number = BigInt.fromI32(blockNumber);
  event.logIndex = BigInt.fromI32(logIndex);
  return event;
}

function fixedBytes(name: string, value: Bytes): ethereum.EventParam {
  return new ethereum.EventParam(name, ethereum.Value.fromFixedBytes(value));
}

function unsigned(name: string, value: BigInt): ethereum.EventParam {
  return new ethereum.EventParam(name, ethereum.Value.fromUnsignedBigInt(value));
}

function createAccount(): void {
  const event = mockEvent(Fixtures.FACTORY, 1, 0);
  event.parameters.push(new ethereum.EventParam("owner", ethereum.Value.fromAddress(Fixtures.OWNER)));
  event.parameters.push(new ethereum.EventParam("account", ethereum.Value.fromAddress(Fixtures.ACCOUNT)));
  event.parameters.push(new ethereum.EventParam("filecoinPay", ethereum.Value.fromAddress(Fixtures.PAY)));
  event.parameters.push(
    new ethereum.EventParam("serviceRegistry", ethereum.Value.fromAddress(Fixtures.SERVICE_REGISTRY)),
  );
  event.parameters.push(
    new ethereum.EventParam("adapterRegistry", ethereum.Value.fromAddress(Fixtures.ADAPTER_REGISTRY)),
  );
  event.parameters.push(unsigned("accountVersion", BigInt.fromI32(1)));
  event.parameters.push(fixedBytes("accountKey", Fixtures.ACCOUNT_KEY));
  handleBossAccountCreated(event);
}

function acceptMeteredSubscription(): void {
  const event = mockEvent(Fixtures.ACCOUNT, 2, 0);
  event.parameters.push(fixedBytes("subscriptionId", Fixtures.SUBSCRIPTION));
  event.parameters.push(new ethereum.EventParam("account", ethereum.Value.fromAddress(Fixtures.ACCOUNT)));
  event.parameters.push(fixedBytes("offerHash", Fixtures.OFFER));
  event.parameters.push(fixedBytes("resourceKey", Fixtures.RESOURCE));
  event.parameters.push(unsigned("railId", BigInt.fromI32(7)));
  event.parameters.push(new ethereum.EventParam("beneficiary", ethereum.Value.fromAddress(Fixtures.BENEFICIARY)));
  event.parameters.push(new ethereum.EventParam("token", ethereum.Value.fromAddress(Fixtures.TOKEN)));
  event.parameters.push(unsigned("initialFixedBudget", BigInt.fromI32(100)));
  event.parameters.push(new ethereum.EventParam("provider", ethereum.Value.fromAddress(Fixtures.PROVIDER)));
  event.parameters.push(new ethereum.EventParam("reporter", ethereum.Value.fromAddress(Fixtures.REPORTER)));
  event.parameters.push(
    new ethereum.EventParam("resourceAdapter", ethereum.Value.fromAddress(Fixtures.RESOURCE_ADAPTER)),
  );
  event.parameters.push(
    new ethereum.EventParam("pricingAdapter", ethereum.Value.fromAddress(Fixtures.PRICING_ADAPTER)),
  );
  event.parameters.push(fixedBytes("resourceDataHash", Fixtures.RESOURCE_DATA));
  event.parameters.push(fixedBytes("pricingDataHash", Fixtures.PRICING_DATA));
  event.parameters.push(fixedBytes("accessGrantHash", Fixtures.ACCESS_GRANT));
  event.parameters.push(unsigned("policyWord", BigInt.fromString("1103806726658")));
  event.parameters.push(unsigned("maxRatePerEpoch", BigInt.fromI32(0)));
  event.parameters.push(unsigned("maxFixedLockup", BigInt.fromI32(100)));
  event.parameters.push(unsigned("maxSingleCharge", BigInt.fromI32(100)));
  event.parameters.push(unsigned("maxChargePerWindow", BigInt.fromI32(1000)));
  event.parameters.push(unsigned("lifetimeCapGross", BigInt.fromI32(1000)));
  event.parameters.push(unsigned("capEpochs", BigInt.fromString("34028236692093846364784204816886372761610")));
  event.parameters.push(unsigned("acceptedRatePerEpoch", BigInt.zero()));
  event.parameters.push(
    unsigned("acceptanceEpochs", BigInt.fromString("17014118346046923176858079186330320896100")),
  );
  handleSubscriptionAccepted(event);
}

function activateSubscription(): void {
  const event = mockEvent(Fixtures.ACCOUNT, 3, 0);
  event.parameters.push(fixedBytes("subscriptionId", Fixtures.SUBSCRIPTION));
  event.parameters.push(unsigned("activatedEpoch", BigInt.fromI32(100)));
  handleSubscriptionActivated(event);
}

function chargeCompleteBudget(): void {
  const event = mockEvent(Fixtures.ACCOUNT, 4, 0);
  event.parameters.push(fixedBytes("subscriptionId", Fixtures.SUBSCRIPTION));
  event.parameters.push(fixedBytes("claimId", Fixtures.CLAIM_ID));
  event.parameters.push(fixedBytes("claimHash", Fixtures.CLAIM_HASH));
  event.parameters.push(unsigned("units", BigInt.fromI32(5)));
  event.parameters.push(unsigned("rawGross", BigInt.fromI32(120)));
  event.parameters.push(unsigned("chargedGross", BigInt.fromI32(100)));
  event.parameters.push(fixedBytes("evidenceHash", Fixtures.EVIDENCE_HASH));
  handleUsageClaimCharged(event);
}

describe("A10 Boss Graph mappings", () => {
  afterEach(() => {
    clearStore();
  });

  test("creates one chain-scoped account from the authenticated factory event", () => {
    createAccount();
    const accountId = "1337:" + Fixtures.ACCOUNT.toHexString();
    assert.entityCount("BossAccount", 1);
    assert.fieldEquals("BossAccount", accountId, "owner", Fixtures.OWNER.toHexString());
    assert.fieldEquals("BossAccount", accountId, "filecoinPay", Fixtures.PAY.toHexString());
    assert.fieldEquals("BossAccount", accountId, "accountVersion", "1");
  });

  test("reconstructs metered acceptance, rail/resource joins, claims, recovery, and termination", () => {
    createAccount();
    acceptMeteredSubscription();
    activateSubscription();

    const accountId = "1337:" + Fixtures.ACCOUNT.toHexString();
    const subscriptionId = accountId + ":" + Fixtures.SUBSCRIPTION.toHexString();
    const railId = accountId + ":rail:7";
    const resourceId =
      accountId + ":resource:" + Fixtures.RESOURCE.toHexString() + ":" + Fixtures.SUBSCRIPTION.toHexString();

    assert.fieldEquals("Subscription", subscriptionId, "billingKind", "2");
    assert.fieldEquals("Subscription", subscriptionId, "assuranceKind", "2");
    assert.fieldEquals("Subscription", subscriptionId, "pauseAllowed", "true");
    assert.fieldEquals("Subscription", subscriptionId, "chargeWindowEpochs", "10");
    assert.fieldEquals("Subscription", subscriptionId, "notAfterEpoch", "1000");
    assert.fieldEquals("Subscription", subscriptionId, "maxLockupPeriod", "100");
    assert.fieldEquals("Subscription", subscriptionId, "state", "ACTIVE");
    assert.fieldEquals("RailSubscription", railId, "subscriptionId", Fixtures.SUBSCRIPTION.toHexString());
    assert.fieldEquals("ResourceSubscription", resourceId, "active", "true");

    chargeCompleteBudget();
    assert.fieldEquals("Subscription", subscriptionId, "totalRawGross", "120");
    assert.fieldEquals("Subscription", subscriptionId, "totalChargedGross", "100");
    assert.fieldEquals("Subscription", subscriptionId, "claimCount", "1");
    assert.fieldEquals("Subscription", subscriptionId, "currentFixedBudget", "0");
    assert.fieldEquals("Subscription", subscriptionId, "state", "EXHAUSTED");

    const topUp = mockEvent(Fixtures.ACCOUNT, 5, 0);
    topUp.parameters.push(fixedBytes("subscriptionId", Fixtures.SUBSCRIPTION));
    topUp.parameters.push(unsigned("oldBudget", BigInt.zero()));
    topUp.parameters.push(unsigned("newBudget", BigInt.fromI32(200)));
    handleFixedBudgetToppedUp(topUp);
    assert.fieldEquals("Subscription", subscriptionId, "currentFixedBudget", "200");
    assert.fieldEquals("Subscription", subscriptionId, "state", "ACTIVE");

    const terminate = mockEvent(Fixtures.ACCOUNT, 6, 0);
    terminate.parameters.push(fixedBytes("subscriptionId", Fixtures.SUBSCRIPTION));
    terminate.parameters.push(unsigned("requestEpoch", BigInt.fromI32(150)));
    handleSubscriptionTerminationRequested(terminate);

    const ended = mockEvent(Fixtures.ACCOUNT, 7, 0);
    ended.parameters.push(fixedBytes("subscriptionId", Fixtures.SUBSCRIPTION));
    ended.parameters.push(unsigned("endedEpoch", BigInt.fromI32(160)));
    handleSubscriptionEnded(ended);
    assert.fieldEquals("Subscription", subscriptionId, "state", "ENDED");
    assert.fieldEquals("RailSubscription", railId, "active", "false");
    assert.fieldEquals("ResourceSubscription", resourceId, "active", "false");
  });
});
