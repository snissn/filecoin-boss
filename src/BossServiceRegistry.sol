// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

/// @notice Provider-controlled discovery, signing-key, service, and offer-nonce state.
/// @dev Registration is not a quality endorsement. Every provider controls only its own namespace.
contract BossServiceRegistry {
    struct ProviderRecord {
        bool registered;
        uint64 revision;
        address defaultBeneficiary;
        string metadataURI;
    }

    struct ServiceRecord {
        bool published;
        uint64 version;
        bytes32 serviceType;
        string metadataURI;
    }

    error ProviderAlreadyRegistered(address provider);
    error ProviderNotRegistered(address provider);
    error InvalidSigningKey();
    error InvalidBeneficiary();
    error SigningKeyStateUnchanged(address signingKey, bool active);
    error InvalidServiceId();
    error InvalidServiceType();
    error ServiceTypeChanged(bytes32 serviceId, bytes32 expected, bytes32 supplied);
    error OfferNonceAlreadyRevoked(uint256 nonce);

    event ProviderRegistered(
        address indexed provider,
        address indexed initialSigningKey,
        uint64 revision,
        address defaultBeneficiary,
        string metadataURI
    );
    event ProviderMetadataUpdated(
        address indexed provider, uint64 revision, address defaultBeneficiary, string metadataURI
    );
    event ProviderSigningKeyUpdated(
        address indexed provider, address indexed signingKey, bool active, uint64 revision
    );
    event ServicePublished(
        address indexed provider,
        bytes32 indexed serviceId,
        bytes32 serviceType,
        uint64 serviceVersion,
        uint64 providerRevision,
        string metadataURI
    );
    event OfferNonceRevoked(address indexed provider, uint256 indexed nonce, uint64 revision);

    mapping(address provider => ProviderRecord record) private _providers;
    mapping(address provider => mapping(address signingKey => bool active)) private _signingKeys;
    mapping(address provider => mapping(bytes32 serviceId => ServiceRecord record)) private _services;
    mapping(address provider => mapping(uint256 nonce => bool revoked)) private _revokedOfferNonces;

    modifier onlyRegisteredProvider() {
        if (!_providers[msg.sender].registered) revert ProviderNotRegistered(msg.sender);
        _;
    }

    function registerProvider(string calldata metadataURI, address initialSigningKey) external {
        ProviderRecord storage record = _providers[msg.sender];
        if (record.registered) revert ProviderAlreadyRegistered(msg.sender);
        if (initialSigningKey == address(0)) revert InvalidSigningKey();

        record.registered = true;
        record.revision = 1;
        record.defaultBeneficiary = msg.sender;
        record.metadataURI = metadataURI;
        _signingKeys[msg.sender][initialSigningKey] = true;

        emit ProviderRegistered(msg.sender, initialSigningKey, 1, msg.sender, metadataURI);
    }

    function setProviderMetadata(string calldata metadataURI, address defaultBeneficiary)
        external
        onlyRegisteredProvider
    {
        if (defaultBeneficiary == address(0)) revert InvalidBeneficiary();

        ProviderRecord storage record = _providers[msg.sender];
        uint64 revision = ++record.revision;
        record.defaultBeneficiary = defaultBeneficiary;
        record.metadataURI = metadataURI;

        emit ProviderMetadataUpdated(msg.sender, revision, defaultBeneficiary, metadataURI);
    }

    function setSigningKey(address signingKey, bool active) external onlyRegisteredProvider {
        if (signingKey == address(0)) revert InvalidSigningKey();
        if (_signingKeys[msg.sender][signingKey] == active) {
            revert SigningKeyStateUnchanged(signingKey, active);
        }

        _signingKeys[msg.sender][signingKey] = active;
        uint64 revision = ++_providers[msg.sender].revision;
        emit ProviderSigningKeyUpdated(msg.sender, signingKey, active, revision);
    }

    function publishService(bytes32 serviceId, bytes32 serviceType, string calldata metadataURI)
        external
        onlyRegisteredProvider
    {
        if (serviceId == bytes32(0)) revert InvalidServiceId();
        if (serviceType == bytes32(0)) revert InvalidServiceType();

        ServiceRecord storage service = _services[msg.sender][serviceId];
        if (service.published && service.serviceType != serviceType) {
            revert ServiceTypeChanged(serviceId, service.serviceType, serviceType);
        }

        service.published = true;
        service.serviceType = serviceType;
        service.metadataURI = metadataURI;
        uint64 serviceVersion = ++service.version;
        uint64 providerRevision = ++_providers[msg.sender].revision;

        emit ServicePublished(
            msg.sender, serviceId, serviceType, serviceVersion, providerRevision, metadataURI
        );
    }

    function revokeOfferNonce(uint256 nonce) external onlyRegisteredProvider {
        if (_revokedOfferNonces[msg.sender][nonce]) revert OfferNonceAlreadyRevoked(nonce);

        _revokedOfferNonces[msg.sender][nonce] = true;
        uint64 revision = ++_providers[msg.sender].revision;
        emit OfferNonceRevoked(msg.sender, nonce, revision);
    }

    function getProvider(address provider) external view returns (ProviderRecord memory record) {
        return _providers[provider];
    }

    function getService(address provider, bytes32 serviceId)
        external
        view
        returns (ServiceRecord memory record)
    {
        return _services[provider][serviceId];
    }

    function isAuthorizedSigner(address provider, address signer) external view returns (bool) {
        return _providers[provider].registered && _signingKeys[provider][signer];
    }

    function isOfferNonceRevoked(address provider, uint256 nonce) external view returns (bool) {
        return _revokedOfferNonces[provider][nonce];
    }
}
