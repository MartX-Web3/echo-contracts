# echo-contracts

Smart contracts for Echo Protocol — the on-chain permission layer for AI agents on Ethereum.

> **Testnet only.** These contracts are deployed on Sepolia. Mainnet deployment requires a formal third-party audit.

---

## Overview

Echo Protocol allows users to grant AI agents bounded on-chain operation authority. Every operation an agent attempts is validated on-chain against policy (and optional session limits) before execution. The **default product path** is **EIP-7702**: the ERC-4337 `sender` is the user’s **EOA**, so DeFi calls see `msg.sender` as that EOA — **no per-user smart-account clone** and **no requirement to pre-fund a separate account contract with swap tokens**.

### Design goals (default EIP-7702 path)

| Goal | How it is met |
|------|----------------|
| **No pre-funding a “SA” for swap principal** | Tokens and router approvals stay on the **EOA**; `EchoDelegationModule` runs as delegated code **at the EOA address**. |
| **EOA master key not given to AI** | User signs **EIP-7702 authorization** (and policy txs) in the wallet. Automation uses **ExecuteKey** (`0x03`) or **Session key** (`0x02`) — scoped credentials, not the EOA seed phrase / hardware key. |
| **Bounded AI / agent automation** | `EchoPolicyValidator` enforces targets, selectors, budgets, recipient, and (for `0x02`) session caps; `PolicyRegistry.recordSpend` updates counters on success only. |

Session mode (`0x02`) under EIP-7702 uses the **same** execution and funding model as realtime (`0x03`): **recipient must equal the EOA**, session budgets and ops limits apply; the agent may hold only the **session** material, within those caps until expiry or revoke.

### Contracts

| Contract | Description |
|---|---|
| `PolicyRegistry` | PolicyTemplates, PolicyInstances, SessionPolicies, Execute Key hashes. Optional **one-time** `setOnboarding` for `EchoOnboarding`; optional legacy `setFactory` for `registerInstanceForStruct` (unused in default `Deploy.s.sol`). |
| `IntentRegistry` | Immutable calldata decoder. Maps Uniswap V3 function selectors to semantic parameter positions (tokenIn, tokenOut, amountIn, recipient). |
| `EchoPolicyValidator` | **`validateFor7702`**: EIP-7702 entry — signature **`0x03`** (realtime ExecuteKey) or **`0x02`** (session). **`0x01`** rejected here. **`validateUserOp`**: ERC-7579 module path (e.g. tests / `MockAccount`) with `0x01` / `0x02`; **`0x03`** must use `validateFor7702`. |
| `EchoDelegationModule` | EIP-7702 **delegation implementation**. EntryPoint v0.7 calls `validateUserOp` → `validator.validateFor7702`; `execute` uses ERC-7579-style single-call encoding. |
| `EchoOnboarding` | One tx: `registerInstanceStructAsOnboarding` + `registerEip7702For`. Wired in `Deploy.s.sol` via `setOnboarding` + `setEip7702Onboarding`. |

### Legacy vs current stack

- **Removed from MVP:** `EchoAccount` (EIP-1167 clone) and `EchoAccountFactory` — they required swap liquidity on the **clone address** (`msg.sender` at the router).  
- **Current:** deploy only registry, intent, validator, `EchoDelegationModule`, `EchoOnboarding` (see `script/Deploy.s.sol`). Gateway must send **`eip7702Auth`** with UserOps where the bundler supports it (e.g. Pimlico on Sepolia). **Gateway integration notes:** [`docs/GATEWAY_7702_CHANGES.md`](docs/GATEWAY_7702_CHANGES.md).

### Where tokens live

**EOA + EIP-7702:** Balances and router **approvals** stay on the user EOA. Paymaster can sponsor **gas**; that is separate from swap principal.

---

## Architecture

```
User
 │
 ├─ PolicyRegistry (on-chain)
 │    ├─ PolicyTemplate      reusable parameter sets, created by Echo team
 │    ├─ PolicyInstance      per-user policy, references a template + overrides
 │    │    ├─ tokenLimits    per-token maxPerOp + maxPerDay (stored in separate mapping)
 │    │    ├─ explorationBudget  capped allowance for unlisted tokens
 │    │    └─ globalCaps     daily and lifetime total limits
 │    └─ SessionPolicy       task-scoped sub-policy for autonomous execution
 │
 ├─ IntentRegistry (on-chain, immutable)
 │    └─ decode(calldata) → (tokenIn, tokenOut, amountIn, recipient)
 │
 ├─ User EOA + EIP-7702 → EchoDelegationModule (bundler passes eip7702Auth)
 │    ├─ EchoOnboarding (optional): registerInstanceAndEip7702 — policy + EOA bind in 1 tx
 │    └─ EchoPolicyValidator.validateFor7702 (mode `0x03` realtime or `0x02` session) + execute → DeFi (msg.sender = EOA)
 │
 └─ PolicyRegistry.registerInstanceStruct — user EOA registers policy when not using EchoOnboarding
```

### Request lifecycle

**EIP-7702 (default product path)** — `sender` is the user EOA, delegation points to `EchoDelegationModule`:

```
Realtime:  UserOperation.signature = [0x03][pad(executeKey, 32)]
Session:   UserOperation.signature = [0x02][sessionId (32)][pad(sessionKey, 32)]
(+ eip7702Auth on the bundler / RPC per Pimlico etc.)

validateFor7702 → mode 0x03: same checks as real-time below; mode 0x02: same as session mode below (recipient == EOA, session caps, …)
Mode 0x01 is rejected here (use validateUserOp only on a contract account).
```

**Real-time mode** (ERC-7579 module on a contract account — e.g. tests / integrations):
```
UserOperation.signature = [0x01][pad(executeKey, 32)]

validateUserOp checks (in execution order):
  1.  executeKey hash valid and not revoked
  2.  instance not paused
  3.  block.timestamp < instance.expiry
  4.  block.timestamp > lastOpTimestamp      (anti-replay: reject same-second replays)
  5.  target in allowedTargets
  6.  selector in allowedSelectors
  7.  IntentRegistry.decode(innerCalldata) → tokenIn, tokenOut, amountIn, recipient
  8.  recipient == account (the 4337 sender: **EOA** under EIP-7702, or smart account in module tests)
  9.  amountIn ≤ tokenLimits[tokenOut].maxPerOp  OR  ≤ explorationPerTx
  10. token daily cap not exceeded
  11. globalDailySpent + amountIn ≤ globalMaxPerDay
  12. globalTotalSpent + amountIn ≤ globalTotalBudget
```

**Session mode** — same checks whether entered via **`validateUserOp`** (module on a contract account, tests) or **`validateFor7702`** (EIP-7702, `account` = user EOA):
```
UserOperation.signature = [0x02][sessionId (32b)][pad(sessionKey, 32b)]

Checks (in execution order):
  1.  sessionKey hash valid
  2.  session belongs to this account's instance
  3.  session.active == true
  4.  block.timestamp < session.sessionExpiry
  5.  target in allowedTargets
  6.  selector in allowedSelectors
  7.  tokenIn matches session
  8.  tokenOut matches session
  9.  recipient == account (the 4337 sender: **EOA** under EIP-7702, or smart account in module tests)
  10. amountIn ≤ session.maxAmountPerOp
  11. session.totalSpent + amountIn ≤ session.totalBudget
  12. session daily ops limit not exceeded
  13. MetaPolicy: not paused, not expired, anti-replay, global daily cap, global total budget
  14. SessionPolicy ⊆ PolicyInstance re-verified at validation time (token-level subset check)
```

On `SIG_VALIDATION_SUCCESS`: `PolicyRegistry.recordSpend()` updates all spend counters atomically.

### User onboarding (EIP-7702)

1. **Deploy** (Echo team): `forge script script/Deploy.s.sol --rpc-url … --broadcast --verify`. Sets `validator`, `onboarding`, `EchoDelegationModule`; does **not** call `setFactory`.
2. **Policy + bind (one tx, recommended):** user calls `EchoOnboarding.registerInstanceAndEip7702` with `InstanceRegistration.owner = msg.sender`.
3. **Alternative (two txs):** `PolicyRegistry.registerInstanceStruct` then `EchoPolicyValidator.registerEip7702(instanceId)`.
4. **Sessions:** instance **owner** (EOA) calls `PolicyRegistry.createSession(...)` when enabling unattended limits.
5. **Automation:** user signs EIP-7702 **authorization** (implementation = deployed `EchoDelegationModule` address). Gateway submits `UserOperation` with `sender = user EOA`, **`eip7702Auth`**, and signature **`0x03`** (ExecuteKey) or **`0x02`** (session). Paymaster for gas.

### Tests (high level)

| Suite | Focus |
|-------|--------|
| `EchoDelegationModule.t.sol` | EIP-7702 `vm.signAndAttachDelegation`, `validateUserOp` via EntryPoint, **`0x03` and `0x02`**, `0x01` rejected, execute + mock router |
| `EchoOnboarding.t.sol` | One-tx onboarding + wiring |
| `EchoPolicyValidator.t.sol` | Module path `0x01` / `0x02`, `0x03` rejected on module `validateUserOp` |
| `Integration.t.sol` | Mock account + policy flows (fork optional) |

---

## Permission model

### PolicyTemplate

Reusable parameter sets created by the Echo team. Three official templates ship with MVP:

| Template | maxPerOp | maxPerDay | explorationBudget | globalTotalBudget |
|---|---|---|---|---|
| Conservative | 50 USDC | 200 USDC | 20 USDC | 2,000 USDC |
| Standard | 100 USDC | 500 USDC | 50 USDC | 5,000 USDC |
| Active | 500 USDC | 2,000 USDC | 100 USDC | 20,000 USDC |

### PolicyInstance

Per-user policy that references a template and overrides specific fields.

```solidity
struct PolicyInstance {
    bytes32   templateId;
    address   owner;
    bytes32   executeKeyHash;    // keccak256 of raw key — never the raw key
    address[] allowedTargets;    // whitelisted protocol contracts
    bytes4[]  allowedSelectors;  // whitelisted function selectors
    address[] tokenList;         // enumeration of tokens with limits
    // per-token limits stored in: mapping(bytes32 instanceId => mapping(address token => TokenLimit))
    uint256   explorationBudget; // capped allowance for unlisted tokens
    uint256   explorationPerTx;
    uint256   explorationSpent;
    uint256   globalMaxPerDay;
    uint256   globalTotalBudget;
    uint256   globalTotalSpent;  // append-only
    uint256   globalDailySpent;
    uint256   lastOpDay;
    uint256   lastOpTimestamp;
    uint64    expiry;
    bool      paused;
}
```

### SessionPolicy

Task-scoped sub-policy for autonomous recurring strategies. Always a strict subset of its parent PolicyInstance, verified at both creation time and validation time.

```solidity
struct SessionPolicy {
    bytes32  instanceId;
    bytes32  sessionKeyHash;
    address  tokenIn;
    address  tokenOut;
    uint256  maxAmountPerOp;
    uint256  totalBudget;
    uint256  totalSpent;      // append-only
    uint256  maxOpsPerDay;
    uint256  dailyOps;
    uint256  lastOpDay;
    uint64   sessionExpiry;
    bool     active;
}
```

### Exploration Budget

The exploration budget provides a capped allowance for tokens not explicitly listed in `tokenLimits`. If a user wants their agent to occasionally buy a new or unlisted token, the agent uses the exploration budget. If exploited, the maximum loss is bounded to `explorationBudget`. Users can promote a token to the main `tokenLimits` with a single transaction.

---

## Security

### Non-negotiable properties

| Property | Description |
|---|---|
| S1 | No operation outside MetaPolicy or SessionPolicy can execute |
| S2 | `recipient` in every swap must equal the 4337 `sender` (EOA under EIP-7702) — assets cannot go to arbitrary third-party addresses |
| S3 | `globalTotalSpent` and `session.totalSpent` are append-only — they can only increase |
| S4 | Only the instance owner can modify PolicyInstance — agents cannot expand their own permissions |

### Trust model

Echo operates on bounded trust, not complete trustlessness.

**Trustless (enforced on-chain by code):**
- Token limits, daily caps, total budget, allowed targets, allowed selectors, recipient enforcement

**Bounded trust (Echo team responsible):**
- The `allowedTargets` whitelist contains only audited, safe DeFi protocols that will not redirect assets to third parties

### Known limitations

- If the user's **EOA master key** is stolen, an attacker can change the PolicyInstance or revoke protections — same class of risk as any self-custody wallet.
- **Session keys** (`0x02`): if disclosed, an attacker can spend **up to session + instance limits** until revoke or expiry. Scope session budgets and lifetimes accordingly.
- Echo cannot prevent users from being socially engineered into approving a malicious policy update.
- Assets held in unrelated wallets/contracts are unaffected by Echo policies.

---

## Deployed addresses (Sepolia)

| Contract | Address |
|---|---|
| PolicyRegistry | `TBD` |
| IntentRegistry | `TBD` |
| EchoPolicyValidator | `TBD` |
| EchoDelegationModule | `TBD` |
| EchoOnboarding | `TBD` |

---

## Development

### Prerequisites

- [Foundry](https://getfoundry.sh/)
- Node.js 20+

#### Foundry config (required)

`foundry.toml` must enable `via_ir` due to OZ v5 contract complexity:

```toml
[profile.default]
via_ir = true
```

### Install

```bash
git clone https://github.com/echo-protocol-lab/echo-contracts
cd echo-contracts
forge install
```

### Build

```bash
forge build
```

### Test

```bash
# All tests
forge test -vvv

# With Sepolia fork (requires SEPOLIA_RPC_URL in .env)
forge test --fork-url $SEPOLIA_RPC_URL -vvv

# Gas snapshot
forge snapshot
```

### Deploy to Sepolia

```bash
cp .env.example .env
# Required: DEPLOYER_PRIVATE_KEY, SEPOLIA_RPC_URL, ETHERSCAN_API_KEY (for verify)

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

### Environment variables

```
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
DEPLOYER_PRIVATE_KEY=0x...    # registry owner + deployer (see Deploy.s.sol)
ETHERSCAN_API_KEY=...
```

---

## External dependencies

| Dependency | Purpose |
|---|---|
| OpenZeppelin Contracts v5 | ERC-7579 utils, LowLevelCall, etc. (validator module pattern in tests) |
| forge-std | Test utilities |

---

## Audit status

Internal security review by Dr. Jeff Ma (CTO). Formal third-party audit required before mainnet deployment.

**Checklist items:** ERC-7562 storage compliance, reentrancy analysis, integer overflow (Solidity 0.8.x checked arithmetic), S1–S4 invariants, bounded approvals, IntentRegistry fuzz testing, EIP-7702 (`validateFor7702` **0x03 / 0x02**, `eip7702Auth` integration off-chain), `EchoOnboarding` + `setOnboarding` / `setEip7702Onboarding`, session subset re-verification.

---

## License

MIT