// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BuilderKeyRegistry} from "../src/BuilderKeyRegistry.sol";

/// @dev A stand-in "V2" used only to prove that upgrades preserve state and are owner-gated.
contract BuilderKeyRegistryV2Mock is BuilderKeyRegistry {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

contract BuilderKeyRegistryTest is Test {
    BuilderKeyRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    address internal k1 = makeAddr("k1");
    address internal k2 = makeAddr("k2");
    address internal k3 = makeAddr("k3");
    address internal k4 = makeAddr("k4");
    address internal k5 = makeAddr("k5");

    uint256 internal constant DEFAULT_CAP = 4;

    // Re-declared so `vm.expectEmit` can reference them.
    event BuilderAdded(address indexed addr, string url, string name);
    event BuilderUpdated(address indexed addr, string url, string name);
    event BuilderRemoved(address indexed addr, string name);
    event DefaultMaxKeysUpdated(uint256 max);
    event MaxKeysUpdated(string name, uint256 max);

    function setUp() public {
        BuilderKeyRegistry impl = new BuilderKeyRegistry();
        bytes memory init = abi.encodeCall(BuilderKeyRegistry.initialize, (owner, DEFAULT_CAP));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        registry = BuilderKeyRegistry(address(proxy));
    }

    // ------------------------------------------------------------------
    // Initialization
    // ------------------------------------------------------------------

    function test_initialize_setsOwnerAndDefaultCap() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.defaultMaxKeys(), DEFAULT_CAP);
        assertEq(registry.builderCount(), 0);
    }

    function test_initialize_cannotRunTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(stranger, 1);
    }

    function test_initialize_rejectsZeroCap() public {
        BuilderKeyRegistry impl = new BuilderKeyRegistry();
        bytes memory init = abi.encodeCall(BuilderKeyRegistry.initialize, (owner, 0));
        vm.expectRevert(BuilderKeyRegistry.InvalidMaxKeys.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_implementation_cannotBeInitializedDirectly() public {
        BuilderKeyRegistry impl = new BuilderKeyRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(owner, 1);
    }

    // ------------------------------------------------------------------
    // addBuilder
    // ------------------------------------------------------------------

    function test_addBuilder_happyPath() public {
        vm.expectEmit(true, false, false, true);
        emit BuilderAdded(k1, "https://a.example", "alpha");

        vm.prank(owner);
        registry.addBuilder(k1, "https://a.example", "alpha");

        assertTrue(registry.isBuilder(k1));
        assertEq(registry.builderCount(), 1);
        assertEq(registry.keyCount("alpha"), 1);

        BuilderKeyRegistry.Builder memory b = registry.getBuilder(k1);
        assertEq(b.addr, k1);
        assertEq(b.url, "https://a.example");
        assertEq(b.name, "alpha");
    }

    function test_addBuilder_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        registry.addBuilder(k1, "https://a.example", "alpha");
    }

    function test_addBuilder_rejectsZeroAddress() public {
        vm.expectRevert(BuilderKeyRegistry.ZeroAddress.selector);
        vm.prank(owner);
        registry.addBuilder(address(0), "https://a.example", "alpha");
    }

    function test_addBuilder_rejectsEmptyUrl() public {
        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.EmptyField.selector, "url"));
        vm.prank(owner);
        registry.addBuilder(k1, "", "alpha");
    }

    function test_addBuilder_rejectsEmptyName() public {
        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.InvalidName.selector, ""));
        vm.prank(owner);
        registry.addBuilder(k1, "https://a.example", "");
    }

    function test_addBuilder_rejectsUppercaseName() public {
        // "BlockRazor" and "blockrazor" would otherwise be two separate counters.
        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.InvalidName.selector, "BlockRazor"));
        vm.prank(owner);
        registry.addBuilder(k1, "https://a.example", "BlockRazor");
    }

    function test_addBuilder_rejectsNameWithSpaceOrDot() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.InvalidName.selector, "block razor"));
        registry.addBuilder(k1, "https://a.example", "block razor");
        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.InvalidName.selector, "48.club"));
        registry.addBuilder(k1, "https://a.example", "48.club");
        vm.stopPrank();
    }

    function test_addBuilder_acceptsLowercaseDigitsDashUnderscore() public {
        vm.startPrank(owner);
        registry.addBuilder(k1, "https://a.example", "48club");
        registry.addBuilder(k2, "https://a.example", "flash_block-2");
        vm.stopPrank();
        assertEq(registry.keyCount("48club"), 1);
        assertEq(registry.keyCount("flash_block-2"), 1);
    }

    // ------------------------------------------------------------------
    // Cap enforcement
    // ------------------------------------------------------------------

    function test_cap_defaultBlocksFifthKey() public {
        _addN("alpha", 4);
        assertEq(registry.keyCount("alpha"), 4);

        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.KeyCapReached.selector, "alpha", DEFAULT_CAP));
        vm.prank(owner);
        registry.addBuilder(k5, "https://a5.example", "alpha");
    }

    function test_cap_isPerName() public {
        _addN("alpha", 4);
        // A different name is unaffected by alpha being full.
        vm.prank(owner);
        registry.addBuilder(k5, "https://b.example", "beta");
        assertEq(registry.keyCount("beta"), 1);
    }

    function test_cap_overrideLowerThanDefault() public {
        vm.expectEmit(false, false, false, true);
        emit MaxKeysUpdated("flash", 2);
        vm.prank(owner);
        registry.setMaxKeys("flash", 2);
        assertEq(registry.maxKeys("flash"), 2);

        vm.startPrank(owner);
        registry.addBuilder(k1, "https://f1.example", "flash");
        registry.addBuilder(k2, "https://f2.example", "flash");
        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.KeyCapReached.selector, "flash", 2));
        registry.addBuilder(k3, "https://f3.example", "flash");
        vm.stopPrank();
    }

    function test_cap_clearOverrideFallsBackToDefault() public {
        vm.startPrank(owner);
        registry.setMaxKeys("flash", 2);
        registry.setMaxKeys("flash", 0);
        vm.stopPrank();
        assertEq(registry.maxKeys("flash"), DEFAULT_CAP);
    }

    function test_cap_raisingDefaultUnblocks() public {
        _addN("alpha", 4);
        vm.startPrank(owner);
        registry.setDefaultMaxKeys(5);
        registry.addBuilder(k5, "https://a5.example", "alpha");
        vm.stopPrank();
        assertEq(registry.keyCount("alpha"), 5);
    }

    function test_cap_loweringDefaultKeepsExistingKeys() public {
        _addN("alpha", 4);
        vm.prank(owner);
        registry.setDefaultMaxKeys(1);
        // Existing keys stay; only further additions are blocked.
        assertEq(registry.keyCount("alpha"), 4);
        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.KeyCapReached.selector, "alpha", 1));
        vm.prank(owner);
        registry.addBuilder(k5, "https://a5.example", "alpha");
    }

    function test_setDefaultMaxKeys_rejectsZero() public {
        vm.expectRevert(BuilderKeyRegistry.InvalidMaxKeys.selector);
        vm.prank(owner);
        registry.setDefaultMaxKeys(0);
    }

    function test_setMaxKeys_rejectsEmptyName() public {
        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.InvalidName.selector, ""));
        vm.prank(owner);
        registry.setMaxKeys("", 2);
    }

    function test_setMaxKeys_rejectsUppercaseName() public {
        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.InvalidName.selector, "Flash"));
        vm.prank(owner);
        registry.setMaxKeys("Flash", 2);
    }

    // ------------------------------------------------------------------
    // Update semantics (idempotent add)
    // ------------------------------------------------------------------

    function test_update_urlOnlyDoesNotChangeCounts() public {
        vm.startPrank(owner);
        registry.addBuilder(k1, "https://old.example", "alpha");

        vm.expectEmit(true, false, false, true);
        emit BuilderUpdated(k1, "https://new.example", "alpha");
        registry.addBuilder(k1, "https://new.example", "alpha");
        vm.stopPrank();

        assertEq(registry.builderCount(), 1);
        assertEq(registry.keyCount("alpha"), 1);
        assertEq(registry.getBuilder(k1).url, "https://new.example");
    }

    function test_update_nameChangeMovesCount() public {
        vm.startPrank(owner);
        registry.addBuilder(k1, "https://a.example", "alpha");
        registry.addBuilder(k1, "https://a.example", "beta");
        vm.stopPrank();

        assertEq(registry.keyCount("alpha"), 0);
        assertEq(registry.keyCount("beta"), 1);
        assertEq(registry.getBuilder(k1).name, "beta");
    }

    function test_update_nameChangeRespectsCapOfNewName() public {
        _addN("alpha", 4);
        vm.startPrank(owner);
        registry.addBuilder(k5, "https://b.example", "beta");
        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.KeyCapReached.selector, "alpha", DEFAULT_CAP));
        registry.addBuilder(k5, "https://b.example", "alpha");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // addBuilders (batch)
    // ------------------------------------------------------------------

    function test_addBuilders_batch() public {
        BuilderKeyRegistry.Builder[] memory batch = new BuilderKeyRegistry.Builder[](3);
        batch[0] = BuilderKeyRegistry.Builder(k1, "https://a1.example", "alpha");
        batch[1] = BuilderKeyRegistry.Builder(k2, "https://a2.example", "alpha");
        batch[2] = BuilderKeyRegistry.Builder(k3, "https://b1.example", "beta");

        vm.prank(owner);
        registry.addBuilders(batch);

        assertEq(registry.builderCount(), 3);
        assertEq(registry.keyCount("alpha"), 2);
        assertEq(registry.keyCount("beta"), 1);
    }

    function test_addBuilders_revertsWholeBatchOnCap() public {
        BuilderKeyRegistry.Builder[] memory batch = new BuilderKeyRegistry.Builder[](5);
        batch[0] = BuilderKeyRegistry.Builder(k1, "u", "alpha");
        batch[1] = BuilderKeyRegistry.Builder(k2, "u", "alpha");
        batch[2] = BuilderKeyRegistry.Builder(k3, "u", "alpha");
        batch[3] = BuilderKeyRegistry.Builder(k4, "u", "alpha");
        batch[4] = BuilderKeyRegistry.Builder(k5, "u", "alpha");

        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.KeyCapReached.selector, "alpha", DEFAULT_CAP));
        vm.prank(owner);
        registry.addBuilders(batch);

        // Atomic: nothing from the batch landed.
        assertEq(registry.builderCount(), 0);
    }

    function test_addBuilders_onlyOwner() public {
        BuilderKeyRegistry.Builder[] memory batch = new BuilderKeyRegistry.Builder[](1);
        batch[0] = BuilderKeyRegistry.Builder(k1, "u", "alpha");
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        registry.addBuilders(batch);
    }

    // ------------------------------------------------------------------
    // removeBuilder
    // ------------------------------------------------------------------

    function test_removeBuilder_middleElementSwapAndPop() public {
        vm.startPrank(owner);
        registry.addBuilder(k1, "u1", "alpha");
        registry.addBuilder(k2, "u2", "alpha");
        registry.addBuilder(k3, "u3", "beta");

        vm.expectEmit(true, false, false, true);
        emit BuilderRemoved(k2, "alpha");
        registry.removeBuilder(k2);
        vm.stopPrank();

        assertFalse(registry.isBuilder(k2));
        assertTrue(registry.isBuilder(k1));
        assertTrue(registry.isBuilder(k3));
        assertEq(registry.builderCount(), 2);
        assertEq(registry.keyCount("alpha"), 1);

        // k3 was moved into k2's slot; its lookup must still resolve.
        assertEq(registry.getBuilder(k3).url, "u3");

        BuilderKeyRegistry.Builder[] memory all = registry.getBuilders();
        assertEq(all.length, 2);
        assertTrue((all[0].addr == k1 && all[1].addr == k3) || (all[0].addr == k3 && all[1].addr == k1));
    }

    function test_removeBuilder_lastElement() public {
        vm.startPrank(owner);
        registry.addBuilder(k1, "u1", "alpha");
        registry.addBuilder(k2, "u2", "alpha");
        registry.removeBuilder(k2);
        vm.stopPrank();
        assertEq(registry.builderCount(), 1);
        assertEq(registry.getBuilders()[0].addr, k1);
    }

    function test_removeBuilder_onlyElement() public {
        vm.startPrank(owner);
        registry.addBuilder(k1, "u1", "alpha");
        registry.removeBuilder(k1);
        vm.stopPrank();
        assertEq(registry.builderCount(), 0);
        assertEq(registry.keyCount("alpha"), 0);
    }

    function test_removeBuilder_unknownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.UnknownBuilder.selector, k1));
        vm.prank(owner);
        registry.removeBuilder(k1);
    }

    function test_removeBuilder_onlyOwner() public {
        vm.prank(owner);
        registry.addBuilder(k1, "u1", "alpha");
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        registry.removeBuilder(k1);
    }

    function test_removeBuilder_freesCapSlot() public {
        _addN("alpha", 4);
        vm.startPrank(owner);
        registry.removeBuilder(k1);
        registry.addBuilder(k5, "u5", "alpha");
        vm.stopPrank();
        assertEq(registry.keyCount("alpha"), 4);
    }

    function test_removeBuilder_isNeverBlockedByCap() public {
        _addN("alpha", 4);
        vm.startPrank(owner);
        registry.setDefaultMaxKeys(1); // alpha is now far above the cap
        registry.removeBuilder(k1); // must still succeed
        vm.stopPrank();
        assertEq(registry.keyCount("alpha"), 3);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function test_getBuilder_unknownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BuilderKeyRegistry.UnknownBuilder.selector, k1));
        registry.getBuilder(k1);
    }

    function test_getBuilders_returnsFullSet() public {
        _addN("alpha", 3);
        BuilderKeyRegistry.Builder[] memory all = registry.getBuilders();
        assertEq(all.length, 3);
        for (uint256 i = 0; i < all.length; ++i) {
            assertTrue(registry.isBuilder(all[i].addr));
            assertEq(all[i].name, "alpha");
        }
    }

    // ------------------------------------------------------------------
    // Ownership (two-step)
    // ------------------------------------------------------------------

    function test_ownership_twoStepTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        registry.transferOwnership(newOwner);
        // Not yet effective.
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), newOwner);

        vm.prank(newOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), newOwner);

        // Old owner has lost admin rights.
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        registry.addBuilder(k1, "u", "alpha");
    }

    function test_ownership_renounceIsDisabled() public {
        vm.expectRevert(BuilderKeyRegistry.RenounceDisabled.selector);
        vm.prank(owner);
        registry.renounceOwnership();
        // Owner is unchanged and still in control.
        assertEq(registry.owner(), owner);
    }

    function test_ownership_renounceByStrangerHitsOwnableCheckFirst() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        registry.renounceOwnership();
    }

    function test_ownership_onlyPendingCanAccept() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        registry.transferOwnership(newOwner);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        registry.acceptOwnership();
    }

    // ------------------------------------------------------------------
    // Upgrade (UUPS)
    // ------------------------------------------------------------------

    function test_upgrade_preservesStateAndAddsLogic() public {
        _addN("alpha", 2);
        vm.prank(owner);
        registry.setMaxKeys("flash", 2);

        BuilderKeyRegistryV2Mock v2Impl = new BuilderKeyRegistryV2Mock();
        vm.prank(owner);
        registry.upgradeToAndCall(address(v2Impl), "");

        BuilderKeyRegistryV2Mock upgraded = BuilderKeyRegistryV2Mock(address(registry));
        assertEq(upgraded.version(), "v2");
        // Storage survived the upgrade.
        assertEq(upgraded.builderCount(), 2);
        assertEq(upgraded.keyCount("alpha"), 2);
        assertEq(upgraded.maxKeys("flash"), 2);
        assertEq(upgraded.owner(), owner);
    }

    function test_upgrade_onlyOwner() public {
        BuilderKeyRegistryV2Mock v2Impl = new BuilderKeyRegistryV2Mock();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        registry.upgradeToAndCall(address(v2Impl), "");
    }

    // ------------------------------------------------------------------
    // Fuzz: index bookkeeping stays consistent under add/remove churn
    // ------------------------------------------------------------------

    function testFuzz_addRemove_keepsIndexConsistent(uint8 n, uint8 removeMask) public {
        vm.assume(n > 0 && n <= 16);
        address[] memory keys = new address[](n);

        vm.startPrank(owner);
        registry.setDefaultMaxKeys(256);
        for (uint256 i = 0; i < n; ++i) {
            keys[i] = address(uint160(0x1000 + i));
            registry.addBuilder(keys[i], "u", i % 2 == 0 ? "even" : "odd");
        }
        uint256 removed;
        for (uint256 i = 0; i < n; ++i) {
            if ((removeMask >> (i % 8)) & 1 == 1) {
                registry.removeBuilder(keys[i]);
                removed++;
            }
        }
        vm.stopPrank();

        assertEq(registry.builderCount(), n - removed);
        BuilderKeyRegistry.Builder[] memory all = registry.getBuilders();
        uint256 evens;
        uint256 odds;
        for (uint256 i = 0; i < all.length; ++i) {
            // Every listed key must be resolvable through the index and point back to itself.
            assertEq(registry.getBuilder(all[i].addr).addr, all[i].addr);
            if (keccak256(bytes(all[i].name)) == keccak256("even")) evens++;
            else odds++;
        }
        assertEq(registry.keyCount("even"), evens);
        assertEq(registry.keyCount("odd"), odds);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _addN(string memory name, uint256 n) internal {
        address[5] memory ks = [k1, k2, k3, k4, k5];
        vm.startPrank(owner);
        for (uint256 i = 0; i < n; ++i) {
            registry.addBuilder(ks[i], string.concat("https://", vm.toString(i), ".example"), name);
        }
        vm.stopPrank();
    }
}
