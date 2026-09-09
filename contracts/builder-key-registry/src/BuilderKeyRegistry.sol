// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @title BuilderKeyRegistry
/// @notice On-chain source of truth for the set of MEV builder signing keys accepted by BSC validators.
///         MEV-Sentry instances read `getBuilders()` periodically and replace their local allowlist.
///
/// @dev Deployed behind an ERC-1967 proxy using the UUPS pattern: the upgrade logic lives in this
///      contract and is restricted to the owner. The owner ("admin" in the design docs) is transferred
///      in two steps (propose + accept) to avoid handing control to a mistyped address.
///
///      Storage layout rule for future upgrades: only append new state variables after the last
///      existing one. Never reorder, remove, or change the type of an existing variable.
contract BuilderKeyRegistry is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice One builder signing key.
    /// @param addr Address recovered from the bid signature. This is the allowlist key.
    /// @param url  Builder endpoint used by validators / MEV-Sentry for `mev_reportIssue`.
    /// @param name Operator that controls the key (e.g. "blockrazor"). Keys sharing a name
    ///             are counted together against the per-builder key cap.
    struct Builder {
        address addr;
        string url;
        string name;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @dev Dense array of all registered keys. Order is not meaningful and changes on removal.
    Builder[] private _builders;

    /// @dev addr => (index in `_builders`) + 1. Zero means "not registered".
    mapping(address => uint256) private _indexPlusOne;

    /// @dev keccak256(name) => number of registered keys with that name.
    mapping(bytes32 => uint256) private _keyCount;

    /// @dev keccak256(name) => per-builder cap override. Zero means "use defaultMaxKeys".
    mapping(bytes32 => uint256) private _maxKeysOverride;

    /// @notice Maximum keys per builder name when no override is set.
    uint256 public defaultMaxKeys;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event BuilderAdded(address indexed addr, string url, string name);
    event BuilderUpdated(address indexed addr, string url, string name);
    event BuilderRemoved(address indexed addr, string name);
    event DefaultMaxKeysUpdated(uint256 max);
    event MaxKeysUpdated(string name, uint256 max);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error EmptyField(string field);
    /// @dev `name` must be non-empty and contain only [a-z0-9-_], so that "BlockRazor" and
    ///      "blockrazor" cannot be counted as two different builders.
    error InvalidName(string name);
    error KeyCapReached(string name, uint256 cap);
    error UnknownBuilder(address addr);
    error InvalidMaxKeys();
    /// @dev Renouncing ownership would leave the registry permanently without an admin or upgrader.
    error RenounceDisabled();

    // ---------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Lock the implementation contract itself so nobody can initialize it directly.
        _disableInitializers();
    }

    /// @notice Initializes the proxy. Called exactly once, atomically with proxy deployment.
    /// @param initialOwner Address that will hold the admin role.
    /// @param defaultMaxKeys_ Default per-builder key cap; must be non-zero.
    function initialize(address initialOwner, uint256 defaultMaxKeys_) external initializer {
        if (defaultMaxKeys_ == 0) revert InvalidMaxKeys();
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        defaultMaxKeys = defaultMaxKeys_;
        emit DefaultMaxKeysUpdated(defaultMaxKeys_);
    }

    // ---------------------------------------------------------------------
    // Admin: builder set
    // ---------------------------------------------------------------------

    /// @notice Adds a key, or updates `url` / `name` if `addr` is already registered.
    /// @dev Idempotent with respect to `addr`. Moving a key to a different `name` re-checks the cap
    ///      for the new name. Reverts if adding a new key would exceed the cap for `name`.
    function addBuilder(address addr, string calldata url, string calldata name) external onlyOwner {
        _addOrUpdate(addr, url, name);
    }

    /// @notice Batch variant of {addBuilder}, intended for the initial load.
    function addBuilders(Builder[] calldata builders) external onlyOwner {
        uint256 len = builders.length;
        for (uint256 i = 0; i < len; ++i) {
            _addOrUpdate(builders[i].addr, builders[i].url, builders[i].name);
        }
    }

    /// @notice Removes a key. Removal is never blocked by the cap.
    function removeBuilder(address addr) external onlyOwner {
        uint256 idxPlusOne = _indexPlusOne[addr];
        if (idxPlusOne == 0) revert UnknownBuilder(addr);

        uint256 idx = idxPlusOne - 1;
        uint256 last = _builders.length - 1;
        string memory name = _builders[idx].name;

        // Swap-and-pop keeps the array dense.
        if (idx != last) {
            Builder memory moved = _builders[last];
            _builders[idx] = moved;
            _indexPlusOne[moved.addr] = idxPlusOne;
        }
        _builders.pop();
        delete _indexPlusOne[addr];

        _keyCount[_nameKey(name)] -= 1;

        emit BuilderRemoved(addr, name);
    }

    // ---------------------------------------------------------------------
    // Admin: caps
    // ---------------------------------------------------------------------

    /// @notice Sets the default per-builder cap. Lowering it never removes existing keys;
    ///         it only blocks further additions for names already at or above the new cap.
    function setDefaultMaxKeys(uint256 max) external onlyOwner {
        if (max == 0) revert InvalidMaxKeys();
        defaultMaxKeys = max;
        emit DefaultMaxKeysUpdated(max);
    }

    /// @notice Sets a per-builder cap override. Pass 0 to clear the override and fall back to the default.
    function setMaxKeys(string calldata name, uint256 max) external onlyOwner {
        _validateName(name);
        _maxKeysOverride[_nameKey(name)] = max;
        emit MaxKeysUpdated(name, max);
    }

    // ---------------------------------------------------------------------
    // Admin: ownership
    // ---------------------------------------------------------------------

    /// @notice Disabled. Use the two-step {transferOwnership} / {acceptOwnership} instead.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Returns every registered key. MEV-Sentry reads this in full on each poll.
    function getBuilders() external view returns (Builder[] memory) {
        return _builders;
    }

    /// @notice Returns one key's record. Reverts if not registered.
    function getBuilder(address addr) external view returns (Builder memory) {
        uint256 idxPlusOne = _indexPlusOne[addr];
        if (idxPlusOne == 0) revert UnknownBuilder(addr);
        return _builders[idxPlusOne - 1];
    }

    /// @notice True if `addr` is currently an accepted builder key.
    function isBuilder(address addr) external view returns (bool) {
        return _indexPlusOne[addr] != 0;
    }

    /// @notice Total number of registered keys.
    function builderCount() external view returns (uint256) {
        return _builders.length;
    }

    /// @notice Number of keys registered under `name`.
    function keyCount(string calldata name) external view returns (uint256) {
        return _keyCount[_nameKey(name)];
    }

    /// @notice Effective cap for `name` (override if set, otherwise the default).
    function maxKeys(string calldata name) public view returns (uint256) {
        uint256 o = _maxKeysOverride[_nameKey(name)];
        return o == 0 ? defaultMaxKeys : o;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _addOrUpdate(address addr, string calldata url, string calldata name) internal {
        if (addr == address(0)) revert ZeroAddress();
        if (bytes(url).length == 0) revert EmptyField("url");
        _validateName(name);

        bytes32 newKey = _nameKey(name);
        uint256 idxPlusOne = _indexPlusOne[addr];

        if (idxPlusOne == 0) {
            _checkCap(name, newKey);
            _builders.push(Builder({addr: addr, url: url, name: name}));
            _indexPlusOne[addr] = _builders.length;
            _keyCount[newKey] += 1;
            emit BuilderAdded(addr, url, name);
            return;
        }

        Builder storage b = _builders[idxPlusOne - 1];
        bytes32 oldKey = _nameKey(b.name);
        if (oldKey != newKey) {
            _checkCap(name, newKey);
            _keyCount[oldKey] -= 1;
            _keyCount[newKey] += 1;
        }
        b.url = url;
        b.name = name;
        emit BuilderUpdated(addr, url, name);
    }

    function _checkCap(string calldata name, bytes32 key) internal view {
        uint256 cap = maxKeys(name);
        if (_keyCount[key] >= cap) revert KeyCapReached(name, cap);
    }

    function _nameKey(string memory name) internal pure returns (bytes32) {
        return keccak256(bytes(name));
    }

    /// @dev Accepts only non-empty strings of [a-z0-9-_]. Case is significant in `keccak256`, so
    ///      forbidding uppercase is what keeps one operator from being split across two counters.
    function _validateName(string calldata name) internal pure {
        bytes calldata b = bytes(name);
        uint256 len = b.length;
        if (len == 0) revert InvalidName(name);
        for (uint256 i = 0; i < len; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= 0x30 && c <= 0x39) // 0-9
                || (c >= 0x61 && c <= 0x7A) // a-z
                || c == 0x2D // -
                || c == 0x5F; // _
            if (!ok) revert InvalidName(name);
        }
    }

    // ---------------------------------------------------------------------
    // UUPS
    // ---------------------------------------------------------------------

    /// @dev Only the owner may upgrade the implementation.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
