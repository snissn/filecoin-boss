// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAccount} from "../../src/BossAccount.sol";
import {BossAdapterRegistry} from "../../src/BossAdapterRegistry.sol";
import {BossServiceRegistry} from "../../src/BossServiceRegistry.sol";
import {FlatRateAdapter} from "../../src/adapters/pricing/FlatRateAdapter.sol";
import {IBossResourceAdapter} from "../../src/interfaces/IBossResourceAdapter.sol";
import {BossHashes} from "../../src/libraries/BossHashes.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";
import {FilecoinPayV1} from "filecoin-pay/FilecoinPayV1.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface VmExactPay {
    function addr(uint256 privateKey) external returns (address keyAddr);
    function prank(address sender) external;
    function roll(uint256 newHeight) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
}

contract ExactPayToken is ERC20 {
    constructor() ERC20("Boss Exact Pay Token", "BEPT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ExactFwssResourceAdapter is IBossResourceAdapter {
    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function inspect(BossTypes.ResourceRef calldata resource, address expectedPayer, bytes calldata resourceData)
        external
        pure
        returns (BossTypes.ResourceStatus memory status)
    {
        status = BossTypes.ResourceStatus({
            resourceKey: BossHashes.hashResource(resource),
            exists: true,
            attachable: true,
            billable: true,
            payer: expectedPayer,
            storageProvider: address(0xB0B),
            sizeInBytes: 1 << 30,
            statusHash: keccak256(resourceData)
        });
    }
}

/// @dev Executes the issue #6 exit gate against Filecoin Pay V1 pinned at
/// 04ded6af6c15c4b5d98545f393dc656004d4aede.
contract FilecoinPayV1AcceptanceTest {
    VmExactPay private constant vm = VmExactPay(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant PROVIDER_KEY = 0xA11CE;
    address private constant PROVIDER = address(0xB0B);
    address private constant BENEFICIARY = address(0xBEEF);
    address private constant BASE_BENEFICIARY = address(0xF55);
    bytes32 private constant SERVICE_ID = keccak256("flat-managed-storage");
    bytes32 private constant SERVICE_TYPE = keccak256("managed-storage");

    FilecoinPayV1 private pay;
    ExactPayToken private token;
    BossServiceRegistry private serviceRegistry;
    BossAdapterRegistry private adapterRegistry;
    ExactFwssResourceAdapter private resourceAdapter;
    FlatRateAdapter private pricingAdapter;
    BossAccount private account;
    address private signingKey;
    uint256 private baseRailId;

    function setUp() public {
        vm.roll(100);

        pay = new FilecoinPayV1();
        token = new ExactPayToken();
        token.mint(address(this), 1_000_000);
        token.approve(address(pay), type(uint256).max);
        pay.deposit(IERC20(address(token)), address(this), 100_000);

        serviceRegistry = new BossServiceRegistry();
        adapterRegistry = new BossAdapterRegistry(address(this));
        resourceAdapter = new ExactFwssResourceAdapter();
        pricingAdapter = new FlatRateAdapter();
        signingKey = vm.addr(PROVIDER_KEY);

        vm.prank(PROVIDER);
        serviceRegistry.registerProvider("ipfs://provider", signingKey);
        vm.prank(PROVIDER);
        serviceRegistry.publishService(SERVICE_ID, SERVICE_TYPE, "ipfs://service");

        adapterRegistry.registerAdapter(
            address(resourceAdapter), BossTypes.AdapterKind.RESOURCE, 1, "ipfs://resource-adapter"
        );
        adapterRegistry.registerAdapter(
            address(pricingAdapter), BossTypes.AdapterKind.PRICING, 1, "ipfs://flat-pricing"
        );

        account = new BossAccount(
            address(this), address(pay), address(serviceRegistry), address(adapterRegistry), 1, address(this)
        );

        IERC20 paymentToken = IERC20(address(token));
        pay.setOperatorApproval(paymentToken, address(account), true, 1_000, 1_000_000, 100);
        pay.setOperatorApproval(paymentToken, address(this), true, 1_000, 1_000_000, 100);

        baseRailId = pay.createRail(paymentToken, address(this), BASE_BENEFICIARY, address(0), 0, address(0));
        pay.modifyRailLockup(baseRailId, 20, 0);
        pay.modifyRailPayment(baseRailId, 7, 0);
    }

    function testExactPayLifecyclePausesAndTerminatesWhileUnderfunded() public {
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(_input(1));

        BossTypes.Subscription memory subscription = account.getSubscription(subscriptionId);
        FilecoinPayV1.RailView memory rail = pay.getRail(railId);
        require(subscription.state == BossTypes.SubscriptionState.ACTIVE, "active after acceptance");
        require(subscription.acceptedRatePerEpoch == 10, "accepted rate");
        require(address(rail.token) == address(token), "token preserved");
        require(rail.from == address(this), "payer preserved");
        require(rail.operator == address(account), "Boss is Pay operator");
        require(rail.validator == address(account), "Boss is Pay validator");
        require(rail.paymentRate == 10, "flat rate active");
        require(rail.lockupPeriod == 5, "lockup period");
        require(rail.lockupFixed == 20, "fixed lockup");
        _assertBaseRailUntouched();

        vm.roll(110);
        account.settle(subscriptionId, 110);
        require(account.getSubscription(subscriptionId).settledGross == 100, "initial settlement");

        _withdrawAvailable();
        vm.roll(111);
        _assertUnderfunded(17);

        account.pause(subscriptionId);
        subscription = account.getSubscription(subscriptionId);
        rail = pay.getRail(railId);
        require(subscription.state == BossTypes.SubscriptionState.PAUSED, "local pause");
        require(subscription.pausedEpoch == 111, "pause epoch");
        require(rail.paymentRate == 10, "underfunded Pay rate retained");

        pay.deposit(IERC20(address(token)), address(this), 1_000);
        account.settle(subscriptionId, 111);
        subscription = account.getSubscription(subscriptionId);
        rail = pay.getRail(railId);
        require(subscription.settledGross == 110, "pre-pause epoch settled");
        require(rail.settledUpTo == 111, "pause advances Pay cursor");

        account.resume(subscriptionId);
        require(account.getSubscription(subscriptionId).state == BossTypes.SubscriptionState.ACTIVE, "resumed");
        require(pay.getRail(railId).paymentRate == 10, "nominal rate unchanged");

        vm.roll(115);
        account.settle(subscriptionId, 115);
        require(account.getSubscription(subscriptionId).settledGross == 150, "resumed settlement");

        _withdrawAvailable();
        vm.roll(116);
        _assertUnderfunded(17);

        account.terminate(subscriptionId);
        subscription = account.getSubscription(subscriptionId);
        rail = pay.getRail(railId);
        require(subscription.state == BossTypes.SubscriptionState.TERMINATING, "terminating");
        require(subscription.payEndEpoch == 120, "locked Pay end observed");
        require(rail.endEpoch == 120, "operator termination accepted while underfunded");
        _assertBaseRailUntouched();

        pay.deposit(IERC20(address(token)), address(this), 1_000);
        vm.roll(120);
        account.settle(subscriptionId, 120);

        subscription = account.getSubscription(subscriptionId);
        require(subscription.state == BossTypes.SubscriptionState.ENDED, "ended after Pay finalization");
        require(subscription.settledGross == 200, "bounded final gross");

        (bool bossRailStillActive,) = address(pay).staticcall(abi.encodeCall(FilecoinPayV1.getRail, (railId)));
        require(!bossRailStillActive, "Boss rail finalized");
        _assertBaseRailUntouched();
    }

    function _withdrawAvailable() private {
        (,, uint256 availableFunds,) = pay.getAccountInfoIfSettled(IERC20(address(token)), address(this));
        require(availableFunds != 0, "expected available funds");
        pay.withdraw(IERC20(address(token)), availableFunds);

        (,, uint256 remainingAvailable,) = pay.getAccountInfoIfSettled(IERC20(address(token)), address(this));
        require(remainingAvailable == 0, "withdraw leaves only lockup");
    }

    function _assertUnderfunded(uint256 expectedRate) private view {
        (uint256 fundedUntilEpoch,, uint256 availableFunds, uint256 lockupRate) =
            pay.getAccountInfoIfSettled(IERC20(address(token)), address(this));
        require(fundedUntilEpoch < block.number, "payer should be underfunded");
        require(availableFunds == 0, "underfunded payer has no available funds");
        require(lockupRate == expectedRate, "aggregate lockup rate");
    }

    function _assertBaseRailUntouched() private view {
        FilecoinPayV1.RailView memory baseRail = pay.getRail(baseRailId);
        require(baseRail.from == address(this), "base payer");
        require(baseRail.to == BASE_BENEFICIARY, "base beneficiary");
        require(baseRail.operator == address(this), "base operator");
        require(baseRail.validator == address(0), "base validator");
        require(baseRail.paymentRate == 7, "base rate untouched");
        require(baseRail.lockupPeriod == 20, "base lockup untouched");
        require(baseRail.settledUpTo == 100, "base cursor untouched");
        require(baseRail.endEpoch == 0, "base rail not terminated");
    }

    function _input(uint256 nonce) private returns (BossTypes.AcceptanceInput memory input) {
        bytes memory pricingData =
            abi.encode(FlatRateAdapter.FlatRateTerms({grossPricePerPeriod: 300, periodEpochs: 30}));

        BossTypes.ServiceOffer memory offer;
        offer.serviceId = SERVICE_ID;
        offer.offerVersion = 1;
        offer.provider = PROVIDER;
        offer.signingKey = signingKey;
        offer.beneficiary = BENEFICIARY;
        offer.token = address(token);
        offer.resourceAdapter = address(resourceAdapter);
        offer.pricingAdapter = address(pricingAdapter);
        offer.serviceType = SERVICE_TYPE;
        offer.billingKind = BossTypes.BillingKind.STREAM_FLAT;
        offer.assuranceKind = BossTypes.AssuranceKind.CANCELLABLE_ONLY;
        offer.dependencyKind = BossTypes.DependencyKind.NONE;
        offer.activationKind = BossTypes.ActivationKind.IMMEDIATE;
        offer.terminationBillingKind = BossTypes.TerminationBillingKind.PAY_THROUGH_FILECOIN_PAY_END;
        offer.pricingDataHash = keccak256(pricingData);
        offer.termsHash = keccak256("flat-v1");
        offer.validUntilEpoch = uint64(block.number + 1_000);
        offer.requiredLockupPeriod = 5;
        offer.pauseAllowed = true;
        offer.providerMaxRatePerEpoch = 10;
        offer.providerMaxFixedLockup = 100;
        offer.nonce = nonce;

        BossTypes.ResourceRef memory resource = BossTypes.ResourceRef({
            kind: BossTypes.ResourceKind.FWSS_PDP_DATASET,
            chainId: uint64(block.chainid),
            anchor: address(0xA11CE),
            resourceId: 1,
            context: bytes32(0)
        });
        BossTypes.CapPolicy memory caps = BossTypes.CapPolicy({
            maxRatePerEpoch: 10,
            maxFixedLockup: 100,
            maxSingleCharge: type(uint256).max,
            maxChargePerWindow: type(uint256).max,
            lifetimeCapGross: 10_000,
            chargeWindowEpochs: 0,
            notAfterEpoch: uint64(block.number + 1_000),
            maxLockupPeriod: 5
        });

        input = BossTypes.AcceptanceInput({
            offer: offer,
            providerSignature: bytes(""),
            resource: resource,
            resourceData: abi.encode("exact-fwss-resource"),
            pricingData: pricingData,
            caps: caps,
            initialFixedBudget: 20,
            accessGrantHash: keccak256("access")
        });
        input.providerSignature = _signOffer(offer);
    }

    function _signOffer(BossTypes.ServiceOffer memory offer) private returns (bytes memory) {
        bytes32 digest = BossHashes.hashTypedData(
            BossHashes.domainSeparator(block.chainid, address(account)), BossHashes.hashServiceOffer(offer)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PROVIDER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }
}
