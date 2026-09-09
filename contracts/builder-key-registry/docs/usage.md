# Builder Key Registry: Usage Guide

The registry stores MEV builder signing addresses and their metadata. Anyone can read it; only the current owner can manage records, change key limits, or authorize upgrades.

This guide describes the current [contract source](../src/BuilderKeyRegistry.sol). Use the ABI matching the deployed implementation. Obtain the network, chain ID, proxy address, and deployment details from the registry administrator. Always interact with the **proxy address**.

## Records and limits

Each record is a Solidity tuple in the order `(address addr, string url, string name)`:

| Field | Meaning | Contract validation |
| --- | --- | --- |
| `addr` | Address recovered from a builder's bid signature | Nonzero; unique across the registry |
| `url` | Builder endpoint for issue reporting | 1–256 bytes; URL syntax and reachability are not checked |
| `name` | Operator label used to group keys | 1–64 bytes; lowercase ASCII letters, digits, `-`, and `_` only |

The key limit applies to the exact `name`, not to a verified operator identity. The effective limit is the per-name override, if nonzero, or `defaultMaxKeys()` otherwise. **Four is not hardcoded.** Lowering a limit does not remove existing keys. An override of zero restores the default; it does not disable an operator.

## Read the registry

The examples use Foundry's `cast`. Replace the placeholders before running them. Reads require no signing account.

```bash
export RPC_URL='<network RPC URL>'
export REGISTRY='<registry proxy address>'
export BUILDER='<builder signing address>'

cast chain-id --rpc-url "$RPC_URL"
cast call "$REGISTRY" 'owner()(address)' --rpc-url "$RPC_URL"
cast call "$REGISTRY" 'getBuilders()((address,string,string)[])' --rpc-url "$RPC_URL"
cast call "$REGISTRY" 'isBuilder(address)(bool)' "$BUILDER" --rpc-url "$RPC_URL"
cast call "$REGISTRY" 'getBuilder(address)((address,string,string))' "$BUILDER" --rpc-url "$RPC_URL"
```

| Read method | Result |
| --- | --- |
| `getBuilders()` | All records; order is not stable |
| `getBuildersRange(offset, limit)` | Up to `limit` records; empty for an out-of-range offset or zero limit |
| `getBuilder(addr)` | One record; reverts with `UnknownBuilder` if absent |
| `isBuilder(addr)` | Whether the address is registered |
| `builderCount()` | Total number of registered addresses |
| `keyCount(name)` | Number of keys under the exact name |
| `maxKeys(name)` | Effective limit for the name |
| `defaultMaxKeys()` | Default limit |
| `owner()`, `pendingOwner()` | Current owner and proposed successor |

For pagination, select a block according to your confirmation policy and use that **same block for every page and count query**. Removal reorders the array. For example:

```bash
export BLOCK='<confirmed block number>'
cast call "$REGISTRY" 'builderCount()(uint256)' \
  --block "$BLOCK" --rpc-url "$RPC_URL"
cast call "$REGISTRY" 'getBuildersRange(uint256,uint256)((address,string,string)[])' 0 50 \
  --block "$BLOCK" --rpc-url "$RPC_URL"
# Continue with offsets 50, 100, ... at the same block.
```

Consumers should validate a complete snapshot before replacing their registry-derived set. A failed read is not an empty registry. Local extra keys are a consumer policy and are not stored or merged by this contract. Registration alone does not configure downstream validators or guarantee immediate acceptance.

## Manage records

All methods below require the current `owner()`. Builders request changes from the administrator; there is no self-registration interface.

| Method | Behavior |
| --- | --- |
| `addBuilder(addr, url, name)` | Adds a new address; rejects existing addresses and additions at the name's limit |
| `addBuilders(builders)` | Adds tuples in `(addr, url, name)` order; any invalid or duplicate entry reverts the entire batch |
| `updateBuilder(addr, url, name)` | Updates an existing record; changing the name checks the destination limit |
| `replaceBuilder(oldAddr, newAddr, url)` | Atomically replaces an address, preserving its name; the new address must be nonzero, different, and unregistered |
| `removeBuilder(addr)` | Removes an existing address regardless of the limit |
| `setDefaultMaxKeys(max)` | Sets a nonzero default limit |
| `setMaxKeys(name, max)` | Sets an override; zero clears it |

Replacement works when the current count is **at or below** the effective limit. If a limit was reduced below the current count, replacement reverts and preserves the old record. Reduce the count or adjust the limit first. Replacement provides no overlap period; use separate addition and removal if both keys must remain valid temporarily.

Example for an owner using an encrypted keystore:

```bash
export OWNER_ACCOUNT='<local owner keystore name>'
cast send "$REGISTRY" 'addBuilder(address,string,string)' \
  "$BUILDER" 'https://builder.example' 'example-builder' \
  --rpc-url "$RPC_URL" --account "$OWNER_ACCOUNT"
```

For a contract wallet or multisig owner, execute the equivalent call through that wallet; a signer account is not itself the owner. After a successful transaction, confirm the record and counts through the proxy.

## Ownership and upgrades

Ownership transfer requires two transactions: the current owner calls `transferOwnership(newOwner)`, then the pending owner calls `acceptOwnership()`. The old owner retains control until acceptance. Proposing the zero address cancels a pending transfer. `renounceOwnership()` is disabled.

The proxy uses UUPS upgrades. The owner can call `upgradeToAndCall(newImplementation, data)` with reviewed upgrade code and any required initialization data. For an upgrade requiring no initialization call, use `0x`. This operation can change registry behavior; clients must use a compatible ABI. `initialize(initialOwner, defaultMaxKeys)` is for initial proxy setup only.

## Events and errors

Record changes emit `BuilderAdded`, `BuilderUpdated`, and `BuilderRemoved`. Replacement emits `BuilderRemoved` followed by `BuilderAdded` in one transaction. Limit changes emit `DefaultMaxKeysUpdated` and `MaxKeysUpdated`; a `MaxKeysUpdated` value of zero means the override was cleared. Ownership and implementation changes emit the inherited `OwnershipTransferStarted`, `OwnershipTransferred`, and `Upgraded` events. Event consumers must handle chain reorganizations.

| Error | Meaning |
| --- | --- |
| `OwnableUnauthorizedAccount` | Caller lacks the required owner or pending-owner role |
| `BuilderExists` / `UnknownBuilder` | Address already exists / required record is absent |
| `KeyCapReached` | The operation would exceed the effective name limit |
| `ZeroAddress` / `SameAddress` | Invalid new key / identical replacement addresses |
| `EmptyField` / `InvalidName` / `FieldTooLong` | Metadata violates field rules |
| `InvalidMaxKeys` | Default limit is zero |
| `RenounceDisabled` | Ownership cannot be renounced |
| `InvalidInitialization` | Initialization is not allowed in the current state |

To generate the ABI from the checked-out source, run `forge inspect BuilderKeyRegistry abi --json` from `contracts/builder-key-registry` after installing its dependencies.
