// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Owned-devnet interface fixture. This is not the EastSea registry.
/// It exercises the pending public publish ABI with actual transactions while
/// the upstream AppRegistry implementation is unavailable.
contract PublishRegistryFixture {
    struct App {
        address publisher;
        address canceller;
        uint64 createdAt;
        uint32 seq;
        bytes32 manifestHash;
        bytes32 bundleHash;
        uint64 unlistedAt;
    }

    struct Pending {
        uint8 op;
        uint64 queuedAt;
        uint64 activatesAt;
        bool narrowing;
        bytes32 manifestHash;
        bytes32 bundleHash;
        address account;
    }

    mapping(bytes32 => App) private records;

    event Published(
        bytes32 indexed appId,
        address indexed publisher,
        string slug,
        bytes32 manifestHash,
        bytes32 bundleHash,
        address canceller,
        string hint
    );

    function appIdOf(address publisher, string memory slug) public pure returns (bytes32) {
        return keccak256(abi.encode(publisher, slug));
    }

    function publish(
        string calldata slug,
        bytes32 manifestHash,
        bytes32 bundleHash,
        address canceller,
        string calldata hint
    ) external returns (bytes32 appId) {
        require(bytes(slug).length != 0, "empty slug");
        require(manifestHash != bytes32(0) && bundleHash != bytes32(0), "zero hash");
        appId = appIdOf(msg.sender, slug);
        require(records[appId].publisher == address(0), "already published");
        records[appId] = App(msg.sender, canceller, uint64(block.timestamp), 1, manifestHash, bundleHash, 0);
        emit Published(appId, msg.sender, slug, manifestHash, bundleHash, canceller, hint);
    }

    function appOf(bytes32 appId) external view returns (App memory current, Pending memory pending) {
        current = records[appId];
    }

    function currentRelease(bytes32 appId) external view returns (uint32, bytes32, bytes32, bool) {
        App memory a = records[appId];
        return (a.seq, a.manifestHash, a.bundleHash, a.publisher != address(0) && a.unlistedAt == 0);
    }
}

/// @notice Owned-devnet names fixture for the pending subdomain ABI. It creates
/// one root belonging to the test account, enforces its ownership, and records
/// child names and app bindings onchain. It is not a production names service.
contract PublishNamesFixture {
    mapping(bytes32 => address) private owners;
    mapping(bytes32 => address) private addresses;
    mapping(bytes32 => mapping(string => string)) private texts;
    mapping(address => string) private reverses;

    event SubdomainCreated(string hostname, address owner);
    event TextSet(string hostname, string key, string value);

    constructor(string memory root, address owner) {
        require(bytes(root).length != 0 && owner != address(0), "invalid root");
        bytes32 node = nodeFor(root);
        owners[node] = owner;
        addresses[node] = owner;
        reverses[owner] = string.concat(root, ".sea");
    }

    function nodeFor(string memory hostname) public pure returns (bytes32) {
        bytes memory b = bytes(hostname);
        if (
            b.length > 4 && b[b.length - 4] == "." && b[b.length - 3] == "s" && b[b.length - 2] == "e"
                && b[b.length - 1] == "a"
        ) {
            bool child;
            for (uint256 i; i < b.length - 4; ++i) {
                if (b[i] == ".") child = true;
            }
            if (!child) {
                bytes memory root = new bytes(b.length - 4);
                for (uint256 i; i < root.length; ++i) {
                    root[i] = b[i];
                }
                return keccak256(root);
            }
        }
        return keccak256(b);
    }

    function ownerOf(bytes32 node) external view returns (address) {
        return owners[node];
    }

    function addrOf(bytes32 node) external view returns (address) {
        return addresses[node];
    }

    function textOf(bytes32 node, string calldata key) external view returns (string memory) {
        return texts[node][key];
    }

    function reverseOf(address account) external view returns (string memory) {
        return reverses[account];
    }

    function createSubdomain(string calldata hostname, address addressRecord) external {
        bytes memory b = bytes(hostname);
        uint256 dot;
        while (dot < b.length && b[dot] != ".") ++dot;
        require(dot > 0 && dot < b.length, "invalid child");
        bytes memory parent = new bytes(b.length - dot - 1);
        for (uint256 i; i < parent.length; ++i) {
            parent[i] = b[dot + 1 + i];
        }
        require(owners[nodeFor(string(parent))] == msg.sender, "not root owner");
        require(addressRecord != address(0), "zero address");
        bytes32 node = nodeFor(hostname);
        require(owners[node] == address(0) || owners[node] == msg.sender, "child owned");
        owners[node] = msg.sender;
        addresses[node] = addressRecord;
        emit SubdomainCreated(hostname, msg.sender);
    }

    function setText(string calldata hostname, string calldata key, string calldata value) external {
        bytes32 node = nodeFor(hostname);
        require(owners[node] == msg.sender, "not owner");
        texts[node][key] = value;
        emit TextSet(hostname, key, value);
    }
}
