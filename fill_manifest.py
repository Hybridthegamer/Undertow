#!/usr/bin/env python3
"""Populate submissions/undertow/submission.json (schema 1.3.0) for the Undertow LVR-recapture hook."""
import json, io

P = "submissions/undertow/submission.json"
d = json.load(io.open(P, encoding="utf-8"))
d["stage"] = "prototype"

# ---- model ----
d["model"]["name"] = "Undertow"
d["model"]["summary"] = ("Undertow is a Uniswap v4 launch pool that recaptures loss-versus-rebalancing (LVR) for its "
    "own liquidity providers by pricing pool staleness into a dynamic LP fee, oracle-free and keeper-free, while "
    "enforcing the mandatory Programmable 10 bps volume fee non-bypassably.")
d["model"]["userOutcome"] = ("Liquidity providers earn back value that would otherwise leak to arbitrageurs: the "
    "first swap after a quiet gap (the arbitrage that realigns price) pays a higher LP fee that the v4 core routes to "
    "in-range LPs; ordinary flow pays the base fee. Traders and issuers get a normal single-canonical-pool market "
    "with transparent, bounded fees.")
d["model"]["category"] = "other"
d["model"]["whyV4"] = ("Only a v4 hook can (a) return a per-swap dynamic LP-fee override computed from on-chain "
    "staleness with no oracle or keeper, and (b) collect the mandatory 10 bps on the quote side via "
    "quadrant-dependent before/after return deltas atomically within the same swap. Neither is expressible as a "
    "router charge, a static LP fee, or a token transfer tax.")

# ---- builder ----
d["builder"]["github"] = "Hybridthegamer"
d["builder"]["contact"] = "https://github.com/Hybridthegamer"
d["builder"]["licenseDeclaration"] = "MIT; builder authored all model source and holds the right to submit it."

# ---- publicMetadata ----
d["publicMetadata"]["project"] = {"name": "Undertow",
    "description": "A Uniswap v4 launch model that recaptures loss-versus-rebalancing for the pool's own LPs via an "
    "oracle-free, staleness-priced dynamic LP fee.",
    "projectUri": "https://github.com/Hybridthegamer/Undertow", "logoUri": None, "logoContentHash": None,
    "metadataMutable": False, "metadataOwner": None}
d["publicMetadata"]["token"] = {"name": "Undertow", "symbol": "TOW", "metadataUri": None, "metadataContentHash": None,
    "logoUri": None, "logoContentHash": None, "metadataMutable": False, "metadataOwner": None}

# ---- assets ----
d["assets"][1]["initialSupply"] = "1000000000000000000000000000"

# ---- launch lifecycle ----
def phase(applicable, actor, vf, custody, failure, event, na=None):
    return {"applicable": applicable, "actor": actor, "valueFlow": vf, "custody": custody, "failure": failure,
            "event": event, "notApplicableReason": na}
ll = d["launchLifecycle"]
ll["tokenCreation"] = phase(True, "Programmable launch flow via the official UERC20 factory",
    "Fixed 1,000,000,000 supply minted once to the launch flow; no further minting.",
    "No party retains mint, pause, freeze, or blacklist authority.",
    "Creation reverts atomically on any factory or parameter error.", "UERC20 factory creation event")
ll["poolInitialization"] = phase(True, "Launch flow initializes one canonical dynamic-fee PoolKey",
    "No value moves at initialization.", "Hook binds the pool one-shot in afterInitialize.",
    "Reverts if the pool is not dynamic-fee or lacks the quote asset (NotDynamicFee / NotQuotePool).",
    "PoolBound(poolId, quote)")
ll["liquidityFormation"] = phase(True, "Launch flow adds the full allocation as one permanently locked position",
    "Entire launch allocation enters one one-sided, permanently locked v4 position.",
    "Position custody is permanent per the Programmable launch standard.",
    "Reverts atomically if the liquidity add fails.", "PoolManager ModifyLiquidity event")
ll["initialTransaction"] = phase(True, "Creator initial buy routed through the canonical pool",
    "Creator's initial ETH buy executes through the hooked pool and pays the mandatory fee like any swap.",
    "No special custody.", "Reverts atomically with the launch transaction.", "Swap event")
ll["trading"] = phase(True, "Any trader swaps on the canonical pool",
    "Each swap pays base LP fee + LVR surcharge (to in-range LPs via core) and the 10 bps platform fee (owner liability).",
    "Hook holds only the owner-claimable platform liability as ERC-6909 quote claims.",
    "A swap reverts atomically on any settlement or bound violation; the fee is never partially applied.",
    "LvrSurcharge and ProgrammableFeeCollected")
ll["feesAndClaims"] = phase(True, "Programmable owner claims the accrued platform liability",
    "10 bps accrues per pool as an owner-only claimable liability; the LVR surcharge is an LP fee, never part of this liability.",
    "Only 0x4957...376c may claim, to itself or a per-claim destination.",
    "Claim of zero returns zero; no other party can claim, redirect, or reduce the liability.",
    "ProgrammableFeeClaimed(poolId, quote, to, amount)")
ll["dependencyFailure"] = phase(True, "PoolManager is the only trusted dependency",
    "No external protocol, oracle, or keeper is used.",
    "If a swap sub-call reverts, the whole swap reverts atomically; no funds are trapped.",
    "The hook has no external dependency that can pause, upgrade, or depeg it.", "n/a (revert)")
ll["retirement"] = phase(False, None, None, None, None, None,
    "The launch position is permanently locked and the hook is immutable; there is no retirement path.")

# ---- pool ----
lp = d["pool"]["lpFee"]
d["pool"]["tickSpacing"] = 60
lp["mode"] = "dynamic"
lp["initialHundredthsOfBip"] = 3000
lp["initializationPath"] = None
lp["applicationMode"] = "before-swap-override"
lp["observationMode"] = "instantaneous"
lp["minimum"] = 3000
lp["maximum"] = 53000
lp["measurementUnit"] = "hundredths-of-bip"
lp["manipulationResistance"] = ("Surcharge is a pure function of prior-block state (elapsed blocks); a swap cannot "
    "lower its own surcharge, and sub-threshold dust swaps do not reset the staleness clock.")
lp["failureRule"] = "Bounded to [3000, 53000] hundredths-of-bip; never approaches the core maximum."
lp["recipient"] = "pool-liquidity-providers"

# ---- programmableFee ----
pf = d["programmableFee"]
pf["rates"]["selectedHundredthsOfBip"] = 1000
pf["rates"]["effectiveHundredthsOfBip"] = 1000
pf["rates"]["projectHundredthsOfBip"] = 0
MODES = ["zeroForOne-exactInput","zeroForOne-exactOutput","oneForZero-exactInput","oneForZero-exactOutput"]
pf["collection"]["status"] = "implemented"
pf["collection"]["supportedSwapModes"] = MODES
pf["collection"]["swapModePaths"] = {  # quote = native ETH = currency0 -> currency0 row
    "zeroForOneExactInput": "before-swap-return-delta", "zeroForOneExactOutput": "after-swap-return-delta",
    "oneForZeroExactInput": "after-swap-return-delta", "oneForZeroExactOutput": "before-swap-return-delta"}
pf["collection"]["selfCallPolicy"] = "same-pool-swap-forbidden"
pf["accounting"]["valueFlowId"] = "programmable-fee"
pf["accounting"]["collectionEvent"] = "ProgrammableFeeCollected(poolId, quote, platform)"
pf["accounting"]["claimEvent"] = "ProgrammableFeeClaimed(poolId, quote, to, amount)"
pf["evidence"]["sourcePaths"] = ["src/Undertow.sol"]
pf["evidence"]["testPaths"] = ["test/LvrRecaptureHook.t.sol","test/LvrInvariant.t.sol","test/LvrFork.t.sol"]

# ---- hook ----
h = d["hook"]
h["used"] = True
h["base"] = "@uniswap/v4-periphery/src/utils/BaseHook.sol"
h["upgradeable"] = False
h["sharedAcrossPools"] = False
h["poolNamespace"] = "All state is keyed by PoolId; one hook instance serves one canonical pool per launch."
h["poolAdmission"] = {"enforcement": "one-shot-afterInitialize-binding",
    "factoryOrRegistry": "The Programmable launch flow deploys the hook and initializes the canonical PoolKey.",
    "alternativePoolBehavior": "An alternative pool with the same hook binds its own PoolId state independently and "
    "does not inherit or contaminate the canonical pool; the canonical pool is proven by the launcher event and exact PoolKey.",
    "rejectionRule": "afterInitialize reverts on a non-dynamic-fee pool, a pool without the quote asset, or a re-bind (AlreadyBound)."}
h["permissions"] = {"beforeInitialize": False, "afterInitialize": True, "beforeAddLiquidity": False,
    "afterAddLiquidity": False, "beforeRemoveLiquidity": False, "afterRemoveLiquidity": False, "beforeSwap": True,
    "afterSwap": True, "beforeDonate": False, "afterDonate": False, "beforeSwapReturnDelta": True,
    "afterSwapReturnDelta": True, "afterAddLiquidityReturnDelta": False, "afterRemoveLiquidityReturnDelta": False}
h["hookData"] = {"used": False, "schema": None, "identitySource": None, "trustedRouterDeploymentRecordId": None,
    "callbackSenderRule": "pool-manager-callback-only", "validation": None}

def sq(basis):
    return {"currency": "currency0", "basis": basis, "formula": "ceil(grossQuote * 1000 / 1000000)",
            "rounding": "up", "maximumHundredthsOfBip": 1000}
h["feeMechanism"] = {"used": True, "classification": "hook-owned-fee", "chargedCurrency": "canonical-pool-quote-asset",
    "swapQuadrants": {"zeroForOneExactInput": sq("gross-input"), "zeroForOneExactOutput": sq("unspecified-amount"),
        "oneForZeroExactInput": sq("unspecified-amount"), "oneForZeroExactOutput": sq("gross-output")},
    "maximumHundredthsOfBip": 1000, "collectionPath": "quadrant-dependent-swap-return-delta",
    "collectionValueFlowId": "programmable-fee", "liabilityKeyDimensions": ["poolId","currency","beneficiary"],
    "collectionEvent": "ProgrammableFeeCollected",
    "recipients": [{"role": "programmable-platform", "sharePpm": 1000000, "addressSource": "fixed-address",
        "address": "0x4957f49620AFf3Adbbe8195a4f633E49cc93376c", "binding": "exact-address", "derivationRule": None,
        "mutable": False, "mutationController": "none", "newAddressValidation": "none", "mutationEvent": None}],
    "ownership": "immutable-owner", "claimPolicy": "owner-only-to-self-or-selected-destination"}
h["customAccounting"] = {"used": False, "backingSource": None, "conservationEquation": None, "settlement": None,
    "partialFillBehavior": None, "liabilityNamespace": None, "liabilityKeyDimensions": [], "crossPoolNetting": False,
    "duplicateCurrencyPolicy": None, "failureIsolation": None, "withdrawalOrdering": None}

TAKE_ACTION = {"order": 0, "actor": "hook", "operation": "take", "currency": "specified", "assetKind": "native",
    "deltaOwner": "hook", "deltaEffect": "positive", "counterparty": "PoolManager", "authorizationRule": None,
    "msgValueRule": None, "amountRule": "ceil(grossQuote * 1000 / 1000000)  (10 bps of the specified quote amount)",
    "completionDeadline": "before-hook-return"}
FEE_COMP = {"mode": "positive-only", "formula": "ceil(grossQuote * 1000 / 1000000)", "minimum": "0", "maximum": None,
    "minimumSign": "zero", "maximumSign": "positive", "positiveSettlementActions": [TAKE_ACTION],
    "negativeSettlementActions": []}
ZERO_COMP = {"mode": "zero-only", "formula": "0", "minimum": "0", "maximum": "0", "minimumSign": "zero",
    "maximumSign": "zero", "positiveSettlementActions": [], "negativeSettlementActions": []}
def quad(supported, spec, unspec, sign, spec_comp):
    return {"supported": supported, "specifiedCurrency": spec, "unspecifiedCurrency": unspec, "amountSign": sign,
        "specifiedComponent": spec_comp, "unspecifiedComponent": None,
        "residualAmmEquation": "amountSpecified-plus-specifiedDelta",
        "finalCallerDeltaEquation": "pool-manager-swap-delta-minus-hook-delta",
        "specifiedDeltaCanConsumeEntireAmount": False, "rounding": "up", "zeroAmmLeg": "forbidden",
        "partialFillRule": "before-quadrant basis is |amountSpecified| (quote is specified and known pre-swap)",
        "slippageInvariant": "fee is additive and bounded; cannot flip the caller-delta sign",
        "failureRule": "revert the whole swap on any settlement failure"}
h["returnDeltaAccounting"]["used"] = True
h["returnDeltaAccounting"]["quadrants"] = {
    "zeroForOneExactInput": quad(True, "currency0", "currency1", "negative-exact-input", FEE_COMP),
    "zeroForOneExactOutput": quad(False, "currency1", "currency0", "positive-exact-output", ZERO_COMP),
    "oneForZeroExactInput": quad(False, "currency1", "currency0", "negative-exact-input", ZERO_COMP),
    "oneForZeroExactOutput": quad(True, "currency0", "currency1", "positive-exact-output", FEE_COMP)}
h["returnDeltaAccounting"]["executionEvent"] = "ProgrammableFeeCollected"

h["postReturnDeltaAccounting"]["afterSwap"] = {"used": True, "returnedDeltaShape": "unspecified-currency-int128",
    "positiveMeaning": "hook-credit-caller-debit", "negativeMeaning": None,
    "backingSource": "ERC-6909 quote claims taken from the PoolManager in the same unlock",
    "callerDeltaEquation": "protocol-delta-minus-hook-delta",
    "componentPolicies": {"unspecified": None, "currency0": None, "currency1": None},
    "bounds": "exactly 10 bps (ceil) of the executed quote amount", "rounding": "up",
    "slippageOrMinimums": "additive and bounded", "failureRule": "revert the whole swap",
    "executionEvent": "ProgrammableFeeCollected"}
for k in ("afterAddLiquidity","afterRemoveLiquidity"):
    h["postReturnDeltaAccounting"][k] = {"used": False, "returnedDeltaShape": None, "positiveMeaning": None,
        "negativeMeaning": None, "backingSource": None, "callerDeltaEquation": None,
        "componentPolicies": {"unspecified": None, "currency0": None, "currency1": None}, "bounds": None,
        "rounding": None, "slippageOrMinimums": None, "failureRule": None, "executionEvent": None}

h["erc6909Claims"] = {"used": True, "currencyIdDerivation": "currency-address-uint160",
    "claimBalanceScope": "claim-owner-and-currency", "poolIdIncludedInClaimId": False, "owner": "the hook contract",
    "operatorPolicy": "no operators approved", "mintFlow": "Currency.take(..., mint=true) on fee collection",
    "burnFlow": "PoolManager.transfer moves claims to the owner's chosen destination on claim",
    "takeSettleFlow": "take on collect; transfer on claim", "liabilityKeys": "(poolId, quote, beneficiary)",
    "liabilityKeyDimensions": ["poolId","currency","beneficiary"], "crossPoolNetting": False,
    "transferPolicy": "only claimProgrammableFee (owner-only) moves claims out",
    "redemption": "owner redeems the ERC-6909 claims at the PoolManager",
    "roundingDust": "ceil rounding favors the liability; the hook is always solvent (proven by invariant)",
    "aggregateSolvencyEquation": "manager.balanceOf(hook, quoteId) == sum over pools of programmableFeeOwed"}
h["nestedActions"] = {"used": False, "directPoolManagerCalls": False, "routerCalls": False, "allowedActions": [],
    "samePoolPolicy": "the hook never initiates a same-pool swap (selfCallPolicy: same-pool-swap-forbidden)",
    "crossPoolPolicy": "none", "callbackSuppression": None, "directCallbackBehavior": None, "routerCallbackBehavior": None,
    "maximumDepth": None, "stateCommitOrder": None, "transientDeltaOwner": None, "syncInterleaving": None,
    "slippageAggregation": None, "failureAtomicity": "any failure reverts the whole swap"}

# ---- capabilities: none used ----
for cap in ["externalCalls","permissionedAsset","oracle","keeper","proof","crossChain","externalLiquidity","asyncSwap","customCurve"]:
    d["capabilities"][cap]["used"] = False

# ---- value flows ----
d["valueFlows"] = [
    {"id": "programmable-fee", "action": "fee", "asset": "canonical-pool-quote-asset", "from": "swapper",
     "to": "0x4957f49620AFf3Adbbe8195a4f633E49cc93376c (owner-claimable liability)",
     "amountRule": "exactly 10 bps (1000 hundredths-of-bip) of executed gross quote-side volume, ceil-rounded",
     "settlement": "taken as ERC-6909 quote claims in the same unlock; owner claims to a chosen destination",
     "failure": "revert the whole swap"},
    {"id": "lvr-surcharge", "action": "fee", "asset": "canonical-pool-lp-fee", "from": "swapper",
     "to": "in-range liquidity providers (via v4 core fee growth)",
     "amountRule": "dynamic LP fee = base 3000 + min(50000, 500 * staleBlocks) hundredths-of-bip",
     "settlement": "charged by the v4 core as the pool LP fee; distributed to in-range LPs by fee-growth accounting",
     "failure": "bounded to [3000, 53000]; revert on core failure"}]

# ---- authorities ----
d["authorities"] = [{"role": "programmable-fee-owner", "controller": "0x4957f49620AFf3Adbbe8195a4f633E49cc93376c",
    "capabilities": ["claim the accrued 10 bps platform liability for a pool to self or a per-claim destination"],
    "mutable": False, "delay": "none",
    "userExitImpact": "None: the owner cannot touch LP funds, the LVR surcharge, or trader funds; no pause/upgrade/sweep exists and swaps and LP exits are never blocked."}]

# ---- dependencies ----
d["dependencies"]["onchain"] = [{"id": "uniswap-v4-pool-manager", "name": "Uniswap v4 PoolManager", "kind": "protocol",
    "repository": "https://github.com/Uniswap/v4-core.git", "revision": "59d3ecf53afa9264a16bba0e38f4c5d2231f80bc",
    "packageVersion": None, "license": "BUSL-1.1", "sourceProvenance": "pinned-source", "deploymentRecordId": "ethereum-mainnet-pool-manager",
    "chainAddress": "0x000000000004444c5dc75cB358380D2e3dE08A90", "runtimeHash": None,
    "deploymentEvidencePath": "test/LvrFork.t.sol", "trust": "runtime-unverified-reference",
    "failure": "if a PoolManager sub-call reverts, the whole swap reverts atomically",
    "fallback": "none; the pool is inoperable if the PoolManager is paused, which is outside this model's control"}]
d["dependencies"]["offchain"] = []

# ---- operations ----
d["operations"]["monitoring"] = ("Off-chain indexers watch LvrSurcharge, ProgrammableFeeCollected and "
    "ProgrammableFeeClaimed to reconstruct fee accrual and the surcharge schedule per pool.")
d["operations"]["incidentResponse"] = ("The hook is immutable with no pause, upgrade, or admin. The only privileged "
    "action is the owner-only fee claim. A discovered issue would be handled by the Programmable launch flow declining "
    "to route new launches to the model.")

# ---- integration ----
ig = d["integration"]
ig["routerGeneration"] = "V2_2_0"
ig["swapModes"] = MODES
ig["partialFills"] = "After-quadrant fee basis is the executed quote delta, so a partial fill is never over-charged."
ig["slippage"] = "The hook adds only a bounded additive fee; trader slippage is the ordinary v4 swap plus a disclosed <=10 bps."
ig["deadline"] = "Deadlines are handled by the router/caller; the hook imposes none."
ig["permit2"] = "Not used by the hook; standard router Permit2 flows are unaffected."
ig["stateReads"] = "The hook reads only its own storage and block.number; no external state reads."
ig["events"] = ["PoolBound","LvrSurcharge","ProgrammableFeeCollected","ProgrammableFeeClaimed"]
ig["quoteExecutionParity"] = "A quoter must apply the same dynamic LP fee and 10 bps return delta to match execution."
rd = ig["routingAndDiscoverability"]
rd["routingMode"] = "programmable-app"
rd["allowlistTriggers"] = {"usesDeltaFlag": True, "addressStartsWith91": False, "targetsMajorPair": False, "permissionedPool": False}
rd["uniswapRoutingStatus"] = "required-not-submitted"
rd["hookRegistryStatus"] = "not-submitted"
rd["customHookDataRequired"] = False
rd["standardRouterCompatible"] = False
rd["permissionedRouting"] = {"required": False, "minimumRouterGeneration": None, "adapterCurrencyUsed": False,
    "allowedWrapperBindings": None, "positionManagerBinding": None, "routingAllowlistRequiredPerChain": True}
rd["sourcePaths"] = ["src/Undertow.sol"]
rd["testPaths"] = ["test/LvrRecaptureHook.t.sol"]
ig["dataReconstruction"]["mode"] = "events-only"
ph = ig["platformHandoff"]
ph.update({"intended": True, "reviewStatus": "pending-maintainer-review", "maintainerReviewRequired": True,
    "selfApproval": False, "availabilityClaimed": False,
    "handoffNotes": "Prototype for maintainer review. Not accepted, audited, routed, deployed, or available. The "
    "autonomous atomic launch graph (launch.json) is a planned follow-up; this revision binds the hook source, tests, "
    "invariants, and a live mainnet-fork rehearsal against the real PoolManager."})

# ---- risk (integers 0-5) ----
dims = {"complexity": 3, "customMath": 1, "externalDependencies": 1, "externalLiquidity": 0, "valueAtRisk": 2,
    "teamMaturity": 2, "upgradeability": 0, "autonomy": 2, "priceImpact": 1}
d["risk"]["dimensions"] = dims
d["risk"]["rationales"] = {
    "complexity": "One hook, two swap callbacks, no custom curve; return-delta fee accounting mirrors an audited pattern.",
    "customMath": "No AMM curve is replaced; only bounded fee arithmetic (mulDivRoundingUp) and a linear surcharge.",
    "externalDependencies": "The PoolManager is the sole dependency; no oracle, keeper, or external protocol.",
    "externalLiquidity": "No external liquidity, vault, or rehypothecation.",
    "valueAtRisk": "The hook holds only the owner-claimable 10 bps liability as ERC-6909 claims, always fully backed (proven by invariant); it never custodies LP or trader principal.",
    "teamMaturity": "New independent builder; no prior deployed model. Independent audit not yet done.",
    "upgradeability": "Immutable: no proxy, admin, pause, or upgrade path.",
    "autonomy": "The LP fee auto-adjusts from on-chain staleness with hard bounds [3000, 53000]; no autonomous value movement beyond the disclosed fee.",
    "priceImpact": "The hook adds only a bounded additive fee; it does not change the AMM curve."}
d["risk"]["declaredTotal"] = sum(dims.values())
d["risk"]["declaredTier"] = "high"
d["risk"]["featureTriggers"] = ["dynamic-lp-fee","per-swap-fee-override","beforeSwapReturnDelta","afterSwapReturnDelta","time-or-block-condition"]

# ---- implementation ----
d["implementation"]["sourcePaths"] = ["src/Undertow.sol"]
d["implementation"]["testPaths"] = ["test/LvrRecaptureHook.t.sol","test/LvrInvariant.t.sol","test/LvrEconomics.t.sol","test/LvrFork.t.sol"]
d["implementation"]["specificationPath"] = "submissions/undertow/PROPOSAL.md"

# ---- disclosures ----
d["disclosures"] = [
    "This submission is not accepted, audited, routed, deployed, or available. Local checks and a mainnet-fork rehearsal are builder evidence, not live collection or maintainer approval.",
    "An arbitrageur may split one large realigning trade so only the first material tranche is surcharged; the dust-threshold guard blocks sub-threshold priming. This residual is disclosed and bounded.",
    "Independent security audit is not yet performed."]

d["unresolved"] = []

json.dump(d, io.open(P, "w", encoding="utf-8"), indent=2)
print("written", P)
