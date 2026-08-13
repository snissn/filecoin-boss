from pathlib import Path

path = Path("test/unit/BossStateView.t.sol")
text = path.read_text()

old = 'import {BossStateView} from "../../src/BossStateView.sol";\n'
new = 'import {BossAdapterRegistry} from "../../src/BossAdapterRegistry.sol";\nimport {BossStateView} from "../../src/BossStateView.sol";\n'
if text.count(old) != 1:
    raise SystemExit("unexpected import anchor")
text = text.replace(old, new)

old = '''    constructor(address owner_, address pay_) {
        owner = owner_;
        payer = owner_;
        filecoinPay = pay_;
    }
'''
new = '''    constructor(address owner_, address pay_) {
        owner = owner_;
        payer = owner_;
        filecoinPay = pay_;
    }

    function setAdapterRegistry(address adapterRegistry_) external {
        adapterRegistry = adapterRegistry_;
    }
'''
if text.count(old) != 1:
    raise SystemExit("unexpected mock account constructor")
text = text.replace(old, new)

old = '''        MockStatePricingAdapter pricingAdapter = new MockStatePricingAdapter();
        BossStateView stateView = new BossStateView();

        BossTypes.ResourceRef memory resource = BossTypes.ResourceRef({
'''
new = '''        MockStatePricingAdapter pricingAdapter = new MockStatePricingAdapter();
        BossAdapterRegistry registry = new BossAdapterRegistry(address(this));
        registry.registerAdapter(
            address(resourceAdapter), BossTypes.AdapterKind.RESOURCE, 1, "ipfs://mock-resource"
        );
        registry.registerAdapter(
            address(pricingAdapter), BossTypes.AdapterKind.PRICING, 1, "ipfs://mock-pricing"
        );
        account.setAdapterRegistry(address(registry));
        BossStateView stateView = new BossStateView();

        BossTypes.ResourceRef memory resource = BossTypes.ResourceRef({
'''
if text.count(old) != 1:
    raise SystemExit("unexpected quote fixture anchor")
path.write_text(text.replace(old, new))
