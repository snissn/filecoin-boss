import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
  BossAccount,
  BudgetUpdate,
  RailSubscription,
  RateUpdate,
  ResourceSubscription,
  Subscription,
  UsageClaim,
} from "../generated/schema";
import {
  accountEntityId,
  boolLane,
  byteLane,
  chainId,
  eventEntityId,
  railSubscriptionEntityId,
  recordLifecycle,
  resourceSubscriptionEntityId,
  scopedEntityId,
  subscriptionEntityId,
  uint64Lane,
} from "./utils";

const MAX_UINT256 = BigInt.fromString(
  "115792089237316195423570985008687907853269984665640564039457584007913129639935",
);

function requireSubscription(account: Address, subscriptionId: Bytes): Subscription {
  const id = subscriptionEntityId(account, subscriptionId);
  const subscription = Subscription.load(id);
  assert(subscription != null, "Boss event references an unknown subscription: " + id);
  return subscription as Subscription;
}

function requireAccount(account: Address): BossAccount {
  const id = accountEntityId(account);
  const entity = BossAccount.load(id);
  assert(entity != null, "Boss event references an unknown account: " + id);
  return entity as BossAccount;
}

function lifetimeCapExhausted(subscription: Subscription): boolean {
  return !subscription.lifetimeCapGross.equals(MAX_UINT256) &&
    subscription.totalChargedGross.ge(subscription.lifetimeCapGross);
}

function streamingSettlementRequiresAccountRead(subscription: Subscription): boolean {
  return (
    (subscription.billingKind == 0 || subscription.billingKind == 1) &&
    !subscription.lifetimeCapGross.equals(MAX_UINT256) &&
    subscription.state == "ACTIVE"
  );
}

export function handleSubscriptionAccepted(event: ethereum.Event): void {
  const subscriptionId = event.parameters[0].value.toBytes();
  const accountAddress = event.parameters[1].value.toAddress();
  assert(accountAddress.equals(event.address), "SubscriptionAccepted account must equal the emitting BossAccount");
  const account = requireAccount(accountAddress);
  const id = subscriptionEntityId(accountAddress, subscriptionId);
  const policyWord = event.parameters[15].value.toBigInt();
  const billingKind = byteLane(policyWord, "1");
  const activationKind = byteLane(policyWord, "16777216");
  const capEpochs = event.parameters[21].value.toBigInt();
  const acceptanceEpochs = event.parameters[23].value.toBigInt();

  const subscription = new Subscription(id);
  subscription.chainId = chainId();
  subscription.account = account.id;
  subscription.accountAddress = accountAddress;
  subscription.subscriptionId = subscriptionId;
  subscription.offerHash = event.parameters[2].value.toBytes();
  subscription.resourceKey = event.parameters[3].value.toBytes();
  subscription.railId = event.parameters[4].value.toBigInt();
  subscription.beneficiary = event.parameters[5].value.toAddress();
  subscription.token = event.parameters[6].value.toAddress();
  subscription.currentFixedBudget = event.parameters[7].value.toBigInt();
  subscription.provider = event.parameters[8].value.toAddress();
  subscription.reporter = event.parameters[9].value.toAddress();
  subscription.resourceAdapter = event.parameters[10].value.toAddress();
  subscription.pricingAdapter = event.parameters[11].value.toAddress();
  subscription.resourceDataHash = event.parameters[12].value.toBytes();
  subscription.pricingDataHash = event.parameters[13].value.toBytes();
  subscription.accessGrantHash = event.parameters[14].value.toBytes();
  subscription.policyWord = policyWord;
  subscription.billingKind = billingKind;
  subscription.assuranceKind = byteLane(policyWord, "256");
  subscription.dependencyKind = byteLane(policyWord, "65536");
  subscription.activationKind = activationKind;
  subscription.terminationBillingKind = byteLane(policyWord, "4294967296");
  subscription.pauseAllowed = boolLane(policyWord, "1099511627776");
  subscription.maxRatePerEpoch = event.parameters[16].value.toBigInt();
  subscription.maxFixedLockup = event.parameters[17].value.toBigInt();
  subscription.maxSingleCharge = event.parameters[18].value.toBigInt();
  subscription.maxChargePerWindow = event.parameters[19].value.toBigInt();
  subscription.lifetimeCapGross = event.parameters[20].value.toBigInt();
  subscription.chargeWindowEpochs = uint64Lane(capEpochs, 0);
  subscription.notAfterEpoch = uint64Lane(capEpochs, 1);
  subscription.maxLockupPeriod = uint64Lane(capEpochs, 2);
  subscription.acceptedRatePerEpoch = event.parameters[22].value.toBigInt();
  subscription.acceptedEpoch = uint64Lane(acceptanceEpochs, 0);
  subscription.quoteValidThroughEpoch = uint64Lane(acceptanceEpochs, 1);
  subscription.quoteTtlEpochs = uint64Lane(acceptanceEpochs, 2);
  subscription.totalRawGross = BigInt.zero();
  subscription.totalChargedGross = BigInt.zero();
  subscription.claimCount = BigInt.zero();
  subscription.pauseRateUpdateDeferred = false;
  subscription.state = activationKind == 0 ? "ACTIVE" : "PENDING_ACTIVATION";
  subscription.requiresAccountRead = streamingSettlementRequiresAccountRead(subscription);
  subscription.createdBlock = event.block.number;
  subscription.createdTransaction = event.transaction.hash;
  subscription.save();

  const rail = new RailSubscription(railSubscriptionEntityId(account.filecoinPay, subscription.railId));
  rail.chainId = chainId();
  rail.filecoinPay = account.filecoinPay;
  rail.account = account.id;
  rail.bossAccount = accountAddress;
  rail.subscription = subscription.id;
  rail.subscriptionId = subscriptionId;
  rail.railId = subscription.railId;
  rail.payer = account.owner;
  rail.payee = subscription.beneficiary;
  rail.operator = accountAddress;
  rail.token = subscription.token;
  rail.active = true;
  rail.createdBlock = event.block.number;
  rail.createdTransaction = event.transaction.hash;
  rail.save();

  const resource = new ResourceSubscription(
    resourceSubscriptionEntityId(accountAddress, subscription.resourceKey, subscriptionId),
  );
  resource.chainId = chainId();
  resource.account = account.id;
  resource.bossAccount = accountAddress;
  resource.subscription = subscription.id;
  resource.subscriptionId = subscriptionId;
  resource.resourceKey = subscription.resourceKey;
  resource.active = true;
  resource.createdBlock = event.block.number;
  resource.createdTransaction = event.transaction.hash;
  resource.save();

  recordLifecycle(event, "SubscriptionAccepted", subscription.id);
}

export function handleProviderActivationAcknowledged(event: ethereum.Event): void {
  const subscription = requireSubscription(event.address, event.parameters[0].value.toBytes());
  subscription.provisioningHash = event.parameters[1].value.toBytes();
  subscription.save();
  recordLifecycle(event, "ProviderActivationAcknowledged", subscription.id);
}

export function handleSubscriptionActivated(event: ethereum.Event): void {
  const subscription = requireSubscription(event.address, event.parameters[0].value.toBytes());
  subscription.state = "ACTIVE";
  subscription.activatedEpoch = event.parameters[1].value.toBigInt();
  subscription.pauseRateUpdateDeferred = false;
  subscription.requiresAccountRead = streamingSettlementRequiresAccountRead(subscription);
  subscription.save();
  recordLifecycle(event, "SubscriptionActivated", subscription.id);
}

export function handleRateSynchronized(event: ethereum.Event): void {
  const subscriptionId = event.parameters[0].value.toBytes();
  const subscription = requireSubscription(event.address, subscriptionId);
  subscription.acceptedRatePerEpoch = event.parameters[2].value.toBigInt();
  subscription.quoteEpoch = event.parameters[3].value.toBigInt();
  subscription.quoteValidThroughEpoch = event.parameters[4].value.toBigInt();
  subscription.resourceStatusHash = event.parameters[5].value.toBytes();
  subscription.save();

  const update = new RateUpdate(eventEntityId(event));
  update.subscription = subscription.id;
  update.subscriptionId = subscriptionId;
  update.oldRate = event.parameters[1].value.toBigInt();
  update.newRate = event.parameters[2].value.toBigInt();
  update.quoteEpoch = event.parameters[3].value.toBigInt();
  update.validThroughEpoch = event.parameters[4].value.toBigInt();
  update.resourceStatusHash = event.parameters[5].value.toBytes();
  update.transactionHash = event.transaction.hash;
  update.blockNumber = event.block.number;
  update.logIndex = event.logIndex;
  update.save();
  recordLifecycle(event, "RateSynchronized", subscription.id);
}

export function handleSubscriptionPaused(event: ethereum.Event): void {
  const subscription = requireSubscription(event.address, event.parameters[0].value.toBytes());
  subscription.state = "PAUSED";
  subscription.pausedEpoch = event.parameters[1].value.toBigInt();
  subscription.pauseRateUpdateDeferred = false;
  subscription.requiresAccountRead = false;
  subscription.save();
  recordLifecycle(event, "SubscriptionPaused", subscription.id);
}

export function handlePauseRateUpdateDeferred(event: ethereum.Event): void {
  const subscription = requireSubscription(event.address, event.parameters[0].value.toBytes());
  subscription.pauseRateUpdateDeferred = true;
  subscription.save();
  recordLifecycle(event, "PauseRateUpdateDeferred", subscription.id);
}

export function handleSubscriptionResumed(event: ethereum.Event): void {
  const subscription = requireSubscription(event.address, event.parameters[0].value.toBytes());
  const resumedEpoch = event.parameters[1].value.toBigInt();
  subscription.state = "ACTIVE";
  subscription.activatedEpoch = resumedEpoch;
  subscription.pausedEpoch = BigInt.zero();
  subscription.resumedEpoch = resumedEpoch;
  subscription.pauseRateUpdateDeferred = false;
  subscription.requiresAccountRead = streamingSettlementRequiresAccountRead(subscription);
  subscription.save();
  recordLifecycle(event, "SubscriptionResumed", subscription.id);
}

export function handleSubscriptionTerminationRequested(event: ethereum.Event): void {
  const subscription = requireSubscription(event.address, event.parameters[0].value.toBytes());
  subscription.state = "TERMINATING";
  subscription.terminationRequestedEpoch = event.parameters[1].value.toBigInt();
  subscription.requiresAccountRead = false;
  subscription.save();
  recordLifecycle(event, "SubscriptionTerminationRequested", subscription.id);
}

export function handleSubscriptionPayTerminationObserved(event: ethereum.Event): void {
  const subscription = requireSubscription(event.address, event.parameters[0].value.toBytes());
  const account = requireAccount(event.address);
  const railId = event.parameters[1].value.toBigInt();
  assert(subscription.railId.equals(railId), "Pay termination rail does not match the Boss subscription");
  subscription.state = "TERMINATING";
  subscription.payEndEpoch = event.parameters[2].value.toBigInt();
  subscription.requiresAccountRead = false;
  subscription.save();

  const rail = RailSubscription.load(railSubscriptionEntityId(account.filecoinPay, railId));
  if (rail != null) {
    rail.active = false;
    rail.save();
  }
  recordLifecycle(event, "SubscriptionPayTerminationObserved", subscription.id);
}

export function handleSubscriptionEnded(event: ethereum.Event): void {
  const subscriptionId = event.parameters[0].value.toBytes();
  const subscription = requireSubscription(event.address, subscriptionId);
  const account = requireAccount(event.address);
  subscription.state = "ENDED";
  subscription.finalSettledEpoch = event.parameters[1].value.toBigInt();
  subscription.requiresAccountRead = false;
  subscription.save();

  const rail = RailSubscription.load(railSubscriptionEntityId(account.filecoinPay, subscription.railId));
  if (rail != null) {
    rail.active = false;
    rail.save();
  }
  const resource = ResourceSubscription.load(
    resourceSubscriptionEntityId(event.address, subscription.resourceKey, subscriptionId),
  );
  if (resource != null) {
    resource.active = false;
    resource.save();
  }
  recordLifecycle(event, "SubscriptionEnded", subscription.id);
}

export function handleAccessGrantCommitted(event: ethereum.Event): void {
  const subscription = requireSubscription(event.address, event.parameters[0].value.toBytes());
  subscription.accessGrantHash = event.parameters[1].value.toBytes();
  subscription.save();
  recordLifecycle(event, "AccessGrantCommitted", subscription.id);
}

export function handleUsageClaimCharged(event: ethereum.Event): void {
  const subscriptionId = event.parameters[0].value.toBytes();
  const claimId = event.parameters[1].value.toBytes();
  const id = scopedEntityId(
    event.address,
    "claim:" + subscriptionId.toHexString() + ":" + claimId.toHexString(),
  );
  if (UsageClaim.load(id) != null) return;

  const subscription = requireSubscription(event.address, subscriptionId);
  const rawGross = event.parameters[4].value.toBigInt();
  const chargedGross = event.parameters[5].value.toBigInt();
  const claim = new UsageClaim(id);
  claim.chainId = chainId();
  claim.bossAccount = event.address;
  claim.subscription = subscription.id;
  claim.subscriptionId = subscriptionId;
  claim.claimId = claimId;
  claim.claimHash = event.parameters[2].value.toBytes();
  claim.units = event.parameters[3].value.toBigInt();
  claim.rawGross = rawGross;
  claim.chargedGross = chargedGross;
  claim.evidenceHash = event.parameters[6].value.toBytes();
  claim.transactionHash = event.transaction.hash;
  claim.blockNumber = event.block.number;
  claim.logIndex = event.logIndex;
  claim.save();

  subscription.totalRawGross = subscription.totalRawGross.plus(rawGross);
  subscription.totalChargedGross = subscription.totalChargedGross.plus(chargedGross);
  subscription.claimCount = subscription.claimCount.plus(BigInt.fromI32(1));
  subscription.currentFixedBudget = subscription.currentFixedBudget.le(chargedGross)
    ? BigInt.zero()
    : subscription.currentFixedBudget.minus(chargedGross);
  if (subscription.currentFixedBudget.equals(BigInt.zero()) || lifetimeCapExhausted(subscription)) {
    subscription.state = "EXHAUSTED";
  }
  subscription.requiresAccountRead = streamingSettlementRequiresAccountRead(subscription);
  subscription.save();
  recordLifecycle(event, "UsageClaimCharged", subscription.id);
}

export function handleFixedBudgetToppedUp(event: ethereum.Event): void {
  const subscriptionId = event.parameters[0].value.toBytes();
  const subscription = requireSubscription(event.address, subscriptionId);
  const oldBudget = event.parameters[1].value.toBigInt();
  const newBudget = event.parameters[2].value.toBigInt();
  subscription.currentFixedBudget = newBudget;
  if (subscription.state == "EXHAUSTED" && newBudget.gt(BigInt.zero()) && !lifetimeCapExhausted(subscription)) {
    subscription.state = "ACTIVE";
  }
  subscription.requiresAccountRead = streamingSettlementRequiresAccountRead(subscription);
  subscription.save();

  const update = new BudgetUpdate(eventEntityId(event));
  update.subscription = subscription.id;
  update.subscriptionId = subscriptionId;
  update.oldBudget = oldBudget;
  update.newBudget = newBudget;
  update.transactionHash = event.transaction.hash;
  update.blockNumber = event.block.number;
  update.logIndex = event.logIndex;
  update.save();
  recordLifecycle(event, "FixedBudgetToppedUp", subscription.id);
}
