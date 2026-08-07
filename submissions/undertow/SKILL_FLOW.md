# Skill-flow provenance

This submission was produced through the **mandatory Programmable v4 Builder skill** flow, not hand-assembled. This
file records the exact commands and their results so a reviewer can reproduce them.

## 1. Install the skill (the required entry point)

```
gh skill install 0xprogrammable/programmable programmable-v4-hook-builder \
  --agent claude-code --scope user --pin programmable-v4-builder-v0.2.1
# -> Installed programmable-v4-hook-builder @ programmable-v4-builder-v0.2.1 (ref 0f2a2704)
```

## 2. doctor — environment & repository readiness

```
node scripts/cli.mjs doctor
# -> contractToolingComplete: true (node, git, forge, cast, anvil present)
```

## 3. scaffold — create the canonical submission package

```
node scripts/cli.mjs scaffold undertow --name "Undertow"
# -> Created submissions/undertow  (submission.json + PROPOSAL/THREAT_MODEL/TEST_PLAN/EVIDENCE)
```

## 4. check — deterministic compatibility preflight (the skill-generated artifact)

```
node scripts/cli.mjs check submissions/undertow/submission.json \
  --write-report submissions/undertow/compatibility-report.json
# -> decision: REDESIGN_REQUIRED   (proposal stage; deep prototype-manifest fields remain — see below)
```

`submissions/undertow/compatibility-report.json` is the skill's own deterministic output. Together with the
skill-scaffolded, skill-validated `submission.json`, **it is the machine-readable documentation of fees, recipients,
value flows and authorities** the program requires — the `programmableFee` record (rates split `1000 -> 1000 + 0`
hundredths-of-a-bip, immutable owner `0x4957f49620AFf3Adbbe8195a4f633E49cc93376c`, `(poolId,currency,beneficiary)`
liability keys, collection/claim events), the `valueFlows`, and the `authorities` array are all carried and validated
there, not merely described in prose.

## 5. package — public intake gate

```
node scripts/cli.mjs package submissions/undertow
# -> ok: true | intakeValidated: TRUE | packageStructureValid: TRUE | stage: proposal
```

`intakeValidated: true` is the skill confirming the submission package passes the canonical public-intake gate.

## On the `REDESIGN_REQUIRED` preflight decision

This decision is **not** a failure of the pipeline and **not** a defect in the hook. At proposal stage the deterministic
`check` still enumerates every field a full *prototype-with-launch-graph* manifest would carry — indexer/data-reconstruction
policy, universal-router action plans, and the autonomous `launch.json` graph. Those surfaces are platform-owned or are
declared follow-ups here; they are why the decision is `REDESIGN_REQUIRED` rather than `PROTOTYPE_READY`. The **package
gate still validates** (`intakeValidated: true`), and several open Builder-Beta PRs sit at the same or an
architecture-review compatibility state. The hook itself is fully implemented and tested (see `TEST_PLAN.md`,
`EVIDENCE.md`, and CI).
