// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAccount} from "../../src/BossAccount.sol";
import {BossAdapterRegistry} from "../../src/BossAdapterRegistry.sol";
import {BossServiceRegistry} from "../../src/BossServiceRegistry.sol";
import {CappedMeteredAdapter} from "../../src/adapters/pricing/CappedMeteredAdapter.sol";
import {IBossResourceAdapter} from "../../src/interfaces/IBossResourceAdapter.sol";
import {BossHashes} from "../../src/libraries/BossHashes.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";
import {FilecoinPayV1} from "filecoin-pay/FilecoinPayV1.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface VmExactMeteredPay {
    function addr(uint256 privateKey) external returns (address keyAddr);
    function prank(address sender) external;
    function roll(uint256 newHeight) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
}

contract ExactMeteredToken is ERC20 {
    constructor() ERC20("Boss Metered Token", "BMT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ExactMeteredResourceAdapter is IBossResourceAdapter {
    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function inspect(BossTypes.ResourceRef calldata resource, address expectedPayer, bytes calldata resourceData)
        external
        pure
        returns (BossTypes.ResourceStatus memory status)
    {
        return BossTypes.ResourceStatus({
            resourceKey: BossHashes.hashResource(resource),
            exists: true,
            attachable: true,
            billable: true,
            payer: expectedPayer,
            storageProvider: address(0xB0B),
            sizeInBytes: 1,
            statusHash: keccak256(resourceData)
        });
    }
}

contract FilecoinPayV1OneTimePaymentTest {
    VmExactMeteredPay private constant vm = VmExactMeteredPay(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant TIB = 1 << 40;
    uint256 private constant PROVIDER_KEY = 0xA11CE;
    uint256 private constant REPORTER_KEY = 0xC0FFEE;
    address private constant PROVIDER = address(0xB0B);
    address private constant BENEFICIARY = address(0xBEEF);
    bytes32 private constant SERVICE_ID = keccak256("exact-capped-egress");
    bytes32 private constant SERVICE_TYPE = keccak256("capped-egress");

    FilecoinPayV1 private pay;
    ExactMeteredToken private token;
    BossServiceRegistry private serviceRegistry;
    BossAdapterRegistry private adapterRegistry;
    ExactMeteredResourceAdapter private resourceAdapter;
    CappedMeteredAdapter private pricingAdapter;
    BossAccount private account;
    address private providerSigningKey;
    address private reporter;

    function setUp() public {
        vm.roll(100);
        pay = new FilecoinPayV1();
        token = new ExactMeteredToken();
        token.mint(address(this), 100 ether);
        token.approve(address(pay), type(uint256).max);
        pay.deposit(IERC20(address(token)), address(this), 100 ether);

        serviceRegistry = new BossServiceRegistry();
        adapterRegistry = new BossAdapterRegistry(address(this));
        resourceAdapter = new ExactMeteredResourceAdapter();
        pricingAdapter = new CappedMeteredAdapter();
        providerSigningKey = vm.addr(PROVIDER_KEY);
        reporter = vm.addr(REPORTER_KEY);

        vm.prank(PROVIDER);
        serviceRegistry.registerProvider("ipfs://provider", providerSigningKey);
        vm.prank(PROVIDER);
        serviceRegistry.publishService(SERVICE_ID, SERVICE_TYPE, "ipfs://service");
        adapterRegistry.registerAdapter(address(resourceAdapter), BossTypes.AdapterKind.RESOURCE, 1, "ipfs://resource");
        adapterRegistry.registerAdapter(address(pricingAdapter), BossTypes.AdapterKind.PRICING, 1, "ipfs://pricing");

        account = new BossAccount(
            address(this), address(pay), address(serviceRegistry), address(adapterRegistry), 1, address(this)
        );
        pay.setOperatorApproval(IERC20(address(token)), address(account), true, 0, 10 ether, 0);
    }

    function testExactOneTimePaymentConsumesBudgetAndRequiresExplicitAllowanceTopUp() public {
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(_input());
        FilecoinPayV1.RailView memory rail = pay.getRail(railId);
        require(rail.paymentRate == 0, "zero streaming rate");
        require(rail.lockupFixed == 10 ether, "initial fixed budget");

        vm.roll(110);
        BossTypes.UsageClaim memory claim = BossTypes.UsageClaim({
            claimId: keccak256("exact-claim"),
            fromEpoch: 100,
            toEpoch: 110,
            units: TIB,
            evidenceHash: keccak256("evidence"),
            evidenceURI: "ipfs://evidence",
            nonce: 1
        });
        uint256 charged = account.submitUsageClaim(subscriptionId, claim, _signClaim(subscriptionId, claim));
        require(charged == 2 ether, "single cap charged");
        rail = pay.getRail(railId);
        require(rail.lockupFixed == 8 ether, "Pay budget consumed");
        require(account.getSubscription(subscriptionId).currentFixedBudget == 8 ether, "Boss budget consumed");

        (bool topUpWithoutAllowance,) =
            address(account).call(abi.encodeCall(BossAccount.topUpFixedBudget, (subscriptionId, 10 ether)));
        require(!topUpWithoutAllowance, "top-up bypassed allowance");

        pay.increaseOperatorApproval(IERC20(address(token)), address(account), 0, 2 ether);
        account.topUpFixedBudget(subscriptionId, 10 ether);
        rail = pay.getRail(railId);
        require(rail.lockupFixed == 10 ether, "explicit top-up applied");
        require(account.getSubscription(subscriptionId).currentFixedBudget == 10 ether, "local top-up applied");
    }

    function _input() private returns (BossTypes.AcceptanceInput memory input) {
        bytes memory pricingData = abi.encode(CappedMeteredAdapter.MeteredTerms({grossPricePerTiB: 7 ether}));
        BossTypes.ServiceOffer memory offer;
        offer.serviceId = SERVICE_ID;
        offer.offerVersion = 1;
        offer.provider = PROVIDER;
        offer.signingKey = providerSigningKey;
        offer.beneficiary = BENEFICIARY;
        offer.reporter = reporter;
        offer.token = address(token);
        offer.resourceAdapter = address(resourceAdapter);
        offer.pricingAdapter = address(pricingAdapter);
        offer.serviceType = SERVICE_TYPE;
        offer.billingKind = BossTypes.BillingKind.METERED_FIXED_LOCKUP;
        offer.assuranceKind = BossTypes.AssuranceKind.TRUSTED_METERING;
        offer.dependencyKind = BossTypes.DependencyKind.NONE;
        offer.activationKind = BossTypes.ActivationKind.IMMEDIATE;
        offer.terminationBillingKind = BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST;
        offer.pricingDataHash = keccak256(pricingData);
        offer.termsHash = keccak256("metered-exact-v1");
        offer.validUntilEpoch = 1_000;
        offer.requiredLockupPeriod = 0;
        offer.pauseAllowed = true;
        offer.providerMaxRatePerEpoch = 0;
        offer.providerMaxFixedLockup = 10 ether;
        offer.nonce = 1;

        input = BossTypes.AcceptanceInput({
            offer: offer,
            providerSignature: bytes(""),
            resource: BossTypes.ResourceRef({
                kind: BossTypes.ResourceKind.FWSS_PDP_DATASET,
                chainId: uint64(block.chainid),
                anchor: address(0xA11CE),
                resourceId: 1,
                context: bytes32(0)
            }),
            resourceData: abi.encode("exact-metered-resource"),
            pricingData: pricingData,
            caps: BossTypes.CapPolicy({
                maxRatePerEpoch: 0,
                maxFixedLockup: 10 ether,
                maxSingleCharge: 2 ether,
                maxChargePerWindow: 5 ether,
                lifetimeCapGross: 20 ether,
                chargeWindowEpochs: 100,
                notAfterEpoch: 900,
                maxLockupPeriod: 0
            }),
            initialFixedBudget: 10 ether,
            accessGrantHash: bytes32(0)
        });
        input.providerSignature = _signOffer(offer);
    }

    function _signOffer(BossTypes.ServiceOffer memory offer) private returns (bytes memory) {
        bytes32 digest = BossHashes.hashTypedData(
            BossHashes.domainSeparator(block.chainid, address(account)), BossHashes.hashServiceOffer(offer)
        );
        return _sign(PROVIDER_KEY, digest);
    }

    function _signClaim(bytes32 subscriptionId, BossTypes.UsageClaim memory claim) private returns (bytes memory) {
        bytes32 digest = BossHashes.hashTypedData(
            BossHashes.domainSeparator(block.chainid, address(account)),
            BossHashes.hashUsageClaim(subscriptionId, claim)
        );
        return _sign(REPORTER_KEY, digest);
    }

    function _sign(uint256 key, bytes32 digest) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
