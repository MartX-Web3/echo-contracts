# echo-contracts

Smart contracts for Echo Protocol — the on-chain permission layer for AI agents on Ethereum.

> **Testnet only.** These contracts are deployed on Sepolia. Mainnet deployment requires a formal third-party audit.

---

## Overview

Echo Protocol allows users to grant AI agents bounded on-chain operation authority. Every operation an agent attempts is validated on-chain against a user-signed policy before execution. The agent never touches the user's private key. No operation outside the policy can execute, regardless of whether the agent, tool, or framework is compromised.

### Contracts

| Contract | Description |
|---|---|
| `PolicyRegistry` | Stores PolicyTemplates, PolicyInstances, SessionPolicies, and Execute Key hashes. The source of truth for all permission state. |
| `IntentRegistry` | Immutable calldata decoder. Maps Uniswap V3 function selectors to semantic parameter positions (tokenIn, tokenOut, amountIn, recipient). |
| `EchoPolicyValidator` | ERC-7579 type-1 validator module. Validates every UserOperation against MetaPolicy or SessionPolicy before execution. The final on-chain enforcer. |
| `EchoAccount` | Concrete OZ AccountERC7579 subclass. Adds `initialize(userWallet, validator, instanceId)` for clone deployment. Deployed once as implementation; each user gets an EIP-1167 clone. |
| `EchoAccountFactory` | Deploys an EchoAccount clone and registers a PolicyInstance in a single transaction. |

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
 ├─ EchoAccount / AccountERC7579 (on-chain, per user — EIP-1167 clone)
 │    └─ EchoPolicyValidator installed as ERC-7579 module
 │         └─ validateUserOp()
 │              ├─ Mode 0x01 (real-time): validate against PolicyInstance
 │              └─ Mode 0x02 (session):   validate against SessionPolicy
 │
 └─ EchoAccountFactory (on-chain)
      └─ createAccount(InstanceRegistration r, bytes32 salt)
           → register PolicyInstance + deploy EchoAccount clone + initialize in one tx
```

### Request lifecycle

**Real-time mode** (user present, immediate command):
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
  8.  recipient == account (the smart account)
  9.  amountIn ≤ tokenLimits[tokenOut].maxPerOp  OR  ≤ explorationPerTx
  10. token daily cap not exceeded
  11. globalDailySpent + amountIn ≤ globalMaxPerDay
  12. globalTotalSpent + amountIn ≤ globalTotalBudget
```

**Session mode** (user absent, autonomous task):
```
UserOperation.signature = [0x02][sessionId (32b)][pad(sessionKey, 32b)]

validateUserOp checks (in execution order):
  1.  sessionKey hash valid
  2.  session belongs to this account's instance
  3.  session.active == true
  4.  block.timestamp < session.sessionExpiry
  5.  target in allowedTargets
  6.  selector in allowedSelectors
  7.  tokenIn matches session
  8.  tokenOut matches session
  9.  recipient == account (the smart account)
  10. amountIn ≤ session.maxAmountPerOp
  11. session.totalSpent + amountIn ≤ session.totalBudget
  12. session daily ops limit not exceeded
  13. MetaPolicy: not paused, not expired, anti-replay, global daily cap, global total budget
  14. SessionPolicy ⊆ PolicyInstance re-verified at validation time (token-level subset check)
```

On `SIG_VALIDATION_SUCCESS`: `PolicyRegistry.recordSpend()` updates all spend counters atomically.

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
| S2 | `recipient` in every swap must equal `AccountERC7579` — assets cannot go to third-party addresses |
| S3 | `globalTotalSpent` and `session.totalSpent` are append-only — they can only increase |
| S4 | Only the instance owner can modify PolicyInstance — agents cannot expand their own permissions |

### Trust model

Echo operates on bounded trust, not complete trustlessness.

**Trustless (enforced on-chain by code):**
- Token limits, daily caps, total budget, allowed targets, allowed selectors, recipient enforcement

**Bounded trust (Echo team responsible):**
- The `allowedTargets` whitelist contains only audited, safe DeFi protocols that will not redirect assets to third parties

### Known limitations

- If the user's private key is stolen, an attacker can modify the PolicyInstance itself. Echo provides no protection at this level — it is equivalent to losing any smart wallet.
- Echo cannot prevent users from being socially engineered into approving a malicious policy update.
- Assets held outside the user's AccountERC7579 are unaffected by Echo policies.

---

## Deployed addresses (Sepolia)

| Contract | Address |
|---|---|
| PolicyRegistry | `TBD` |
| IntentRegistry | `TBD` |
| EchoPolicyValidator | `TBD` |
| EchoAccount (impl) | `TBD` |
| EchoAccountFactory | `TBD` |

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
# Fill in SEPOLIA_RPC_URL, PRIVATE_KEY, ETHERSCAN_API_KEY

forge script script/Deploy.s.sol \
  --rpc-url sepolia \
  --broadcast \
  --verify
```

### Environment variables

```
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
PRIVATE_KEY=0x...
ETHERSCAN_API_KEY=...
```

---

## External dependencies

| Dependency | Purpose |
|---|---|
| OpenZeppelin Contracts v5 | AccountERC7579, Ownable, Initializable, SignerECDSA |
| forge-std | Test utilities |

---

## Audit status

Internal security review by Dr. Jeff Ma (CTO). Formal third-party audit required before mainnet deployment.

**Checklist items:** ERC-7562 storage compliance, reentrancy analysis, integer overflow (Solidity 0.8.24 checked arithmetic), S1–S4 invariants, bounded approvals, IntentRegistry fuzz testing, onInstall ownership enforcement, session subset re-verification.

---

## License

MIT