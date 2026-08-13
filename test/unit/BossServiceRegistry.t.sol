// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossServiceRegistry} from "../../src/BossServiceRegistry.sol";

interface VmRegistryLogs {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

contract RegistryActor {
    function execute(address target, bytes calldata callData) external returns (bool success, bytes memory result) {
        return target.call(callData);
    }
}

contract BossServiceRegistryTest {
    VmRegistryLogs internal constant vm =
        VmRegistryLogs(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 internal constant SERVICE_ID = keccak256("filone-managed-storage");
    bytes32 internal constant SERVICE_TYPE = keccak256("managed-storage");

    function testProviderRegistrationAndEventPayload() public {
        BossServiceRegistry registry = new BossServiceRegistry();
        RegistryActor provider = new RegistryActor();
        address signingKey = address(0xBEEF);

        vm.recordLogs();
        _mustExecute(
            provider,
            address(registry),
            abi.encodeCall(BossServiceRegistry.registerProvider, ("ipfs://provider-v1", signingKey))
        );
        VmRegistryLogs.Log[] memory logs = vm.getRecordedLogs();

        require(logs.length == 1, "registration log count");
        require(logs[0].emitter == address(registry), "registration emitter");
        require(logs[0].topics.length == 3, "registration topics");
        require(
            logs[0].topics[0] == keccak256("ProviderRegistered(address,address,uint64,address,string)"),
            "registration signature"
        );
        require(address(uint160(uint256(logs[0].topics[1]))) == address(provider), "registration provider");
        require(address(uint160(uint256(logs[0].topics[2]))) == signingKey, "registration signer");
        (uint64 revision, address beneficiary, string memory metadataURI) =
            abi.decode(logs[0].data, (uint64, address, string));
        require(revision == 1, "registration revision");
        require(beneficiary == address(provider), "registration beneficiary");
        require(keccak256(bytes(metadataURI)) == keccak256("ipfs://provider-v1"), "registration metadata");

        BossServiceRegistry.ProviderRecord memory record = registry.getProvider(address(provider));
        require(record.registered, "provider registered");
        require(record.revision == 1, "provider revision");
        require(record.defaultBeneficiary == address(provider), "default beneficiary");
        require(registry.isAuthorizedSigner(address(provider), signingKey), "initial signer");
    }

    function testDuplicateRegistrationAndUnregisteredMutationFailClosed() public {
        BossServiceRegistry registry = new BossServiceRegistry();
        RegistryActor provider = new RegistryActor();
        RegistryActor outsider = new RegistryActor();
        address signingKey = address(0xBEEF);

        _mustExecute(
            provider,
            address(registry),
            abi.encodeCall(BossServiceRegistry.registerProvider, ("ipfs://provider", signingKey))
        );

        _mustFail(
            provider,
            address(registry),
            abi.encodeCall(BossServiceRegistry.registerProvider, ("ipfs://duplicate", address(0xCAFE)))
        );
        _mustFail(
            outsider,
            address(registry),
            abi.encodeCall(BossServiceRegistry.setSigningKey, (address(0xCAFE), true))
        );
        require(registry.isAuthorizedSigner(address(provider), signingKey), "provider signer preserved");
        require(!registry.isAuthorizedSigner(address(provider), address(0xCAFE)), "outsider signer rejected");
    }

    function testSignerRotationRevokesSupersededKey() public {
        BossServiceRegistry registry = new BossServiceRegistry();
        RegistryActor provider = new RegistryActor();
        address oldKey = address(0xBEEF);
        address newKey = address(0xCAFE);

        _mustExecute(
            provider,
            address(registry),
            abi.encodeCall(BossServiceRegistry.registerProvider, ("ipfs://provider", oldKey))
        );
        _mustExecute(
            provider,
            address(registry),
            abi.encodeCall(BossServiceRegistry.setSigningKey, (oldKey, false))
        );
        _mustExecute(
            provider,
            address(registry),
            abi.encodeCall(BossServiceRegistry.setSigningKey, (newKey, true))
        );

        require(!registry.isAuthorizedSigner(address(provider), oldKey), "old signer revoked");
        require(registry.isAuthorizedSigner(address(provider), newKey), "new signer active");
        require(registry.getProvider(address(provider)).revision == 3, "rotation revision");

        _mustFail(
            provider,
            address(registry),
            abi.encodeCall(BossServiceRegistry.setSigningKey, (newKey, true))
        );
    }

    function testProviderMetadataBeneficiaryAndServiceVersionsAreMonotonic() public {
        BossServiceRegistry registry = new BossServiceRegistry();
        RegistryActor provider = new RegistryActor();
        address beneficiary = address(0xD00D);

        _mustExecute(
            provider,
            address(registry),
            abi.encodeCall(BossServiceRegistry.registerProvider, ("ipfs://provider-v1", address(0xBEEF)))
        );
        _mustExecute(
            provider,
            address(registry),
            abi.encodeCall(BossServiceRegistry.setProviderMetadata, ("ipfs://provider-v2", beneficiary))
        );
        _mustExecute(
            provider,
            address(registry),
            abi.encodeCall(
                BossServiceRegistry.publishService,
                (SERVICE_ID, SERVICE_TYPE, "ipfs://service-v1")
            )
        );
        _mustExecute(
            provider,
            address(registry),
            abi.encodeCall(
                BossServiceRegistry.publishService,
                (SERVICE_ID, SERVICE_TYPE, "ipfs://service-v2")
            )
        );

        BossServiceRegistry.ProviderRecord memory providerRecord = registry.getProvider(address(provider));
        BossServiceRegistry.ServiceRecord memory serviceRecord = registry.getService(address(provider), SERVICE_ID);
        require(providerRecord.revision == 4, "provider revision");
        require(providerRecord.defaultBeneficiary == beneficiary, "beneficiary update");
        require(keccak256(bytes(providerRecord.metadataURI)) == keccak256("ipfs://provider-v2"), "metadata update");
        require(serviceRecord.published, "service published");
        require(serviceRecord.version == 2, "service version");
        require(serviceRecord.serviceType == SERVICE_TYPE, "service type");
        require(keccak256(bytes(serviceRecord.metadataURI)) == keccak256("ipfs://service-v2"), "service metadata");
    }

    function testOfferNonceRevocationCannotReplay() public {
        BossServiceRegistry registry = new BossServiceRegistry();
        RegistryActor provider = new RegistryActor();

        _mustExecute(
            provider,
            address(registry),
            abi.encodeCall(BossServiceRegistry.registerProvider, ("ipfs://provider", address(0xBEEF)))
        );
        _mustExecute(
            provider,
            address(registry),
            abi.encodeCall(BossServiceRegistry.revokeOfferNonce, (uint256(77)))
        );

        require(registry.isOfferNonceRevoked(address(provider), 77), "nonce revoked");
        require(registry.getProvider(address(provider)).revision == 2, "nonce revision");
        _mustFail(
            provider,
            address(registry),
            abi.encodeCall(BossServiceRegistry.revokeOfferNonce, (uint256(77)))
        );
    }

    function _mustExecute(RegistryActor actor, address target, bytes memory callData) private {
        (bool success,) = actor.execute(target, callData);
        require(success, "expected success");
    }

    function _mustFail(RegistryActor actor, address target, bytes memory callData) private {
        (bool success,) = actor.execute(target, callData);
        require(!success, "expected failure");
    }
}
