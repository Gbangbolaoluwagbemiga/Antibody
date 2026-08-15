# Demo video — shooting script

**Target: 85 seconds.** A 40-second cut is at the bottom for anywhere with a hard limit.

Judges triage. The first ten seconds decide whether the next seventy get watched, so the strongest
claim goes first and the lineage story goes last or not at all.

---

## Before you record

- [ ] Site deployed and reachable at a public URL (localhost in a submission video reads as unfinished)
- [ ] Hard-reload, confirm the block counter bottom-left is **ticking** — if it's frozen the page is
      on snapshot data and every "live" claim in the narration is false
- [ ] Contract verified on Uniscan, so the tab you open shows Solidity and not bytecode
- [ ] Browser at 1440×900, zoom 100%, dark mode, no bookmarks bar, no notifications
- [ ] Deep link ready: `/?size=2.4` opens the slider already in the flagged state
- [ ] Run the attack once beforehand — it's probabilistic, and you want a fresh immunity record live
      when you film the cross-pool panel

---

## The 85-second cut

### 0:00 – 0:09 · The claim

**Screen:** Overview, top of page. Four stat tiles visible.

> "Most MEV defences are a rule somebody configured. Antibody has no rule to configure — every pool
> works out its own detection threshold from its own trading history."

*Don't move the mouse. Let the tiles be read.*

---

### 0:09 – 0:24 · The proof

**Screen:** Scroll slowly to the two-pool panel. Let both numbers land.

> "Same deployed contract. Same bytecode. Two pools that arrived at completely different boundaries,
> because they saw different flow. Nobody set either number — there's no per-pool setting to set."

*This is the whole pitch. If a judge stops watching here, they still got it.*

---

### 0:24 – 0:40 · Make them feel it

**Screen:** Navigate to **Try it**. Grab the slider. Drag it slowly left to right.

> "This reads the live contract. Ordinary size, ordinary fee — right up to the boundary this pool
> taught itself."

*Pause on the moment the verdict flips red.*

> "And then it isn't. No wallet, no gas — that's a view function on the deployed hook."

---

### 0:40 – 0:56 · Catch one

**Screen:** **The attack** page. Click **Run a live sandwich attack**. Let the legs land.

> "Three real transactions on Unichain Sepolia. Front-run, victim, exit — same block."

*Wait for the rows. Point at the exit.*

> "The attacker's exit pays the ceiling. The victim pays base fee and nothing more. The penalty goes
> to the pool's liquidity providers — extraction becomes LP revenue."

*If the legs split across blocks, say so and move on — it's on the page anyway, and a demo that
narrates the failure honestly is worth more than one that hides a re-take. Do not re-shoot.*

---

### 0:56 – 1:12 · The part nobody else has

**Screen:** Scroll to the cross-pool immunity panel. Both figures visible.

> "Here's the same address in a *different* pool — one that has never seen them. It's priced higher
> anyway, because the record follows the trader, not the pool. And it decays, so it's memory rather
> than a blacklist."

*Beat.*

> "Every pool running this feeds that memory. Every new pool inherits from the ones before it. It's
> a defence that gets stronger the more pools adopt it."

---

### 1:12 – 1:25 · Why believe any of it

**Screen:** **Verify** page, limitations section visible.

> "An early build of this flagged twenty-three out of twenty-three ordinary swaps as attacks —
> because 'same trader, same block, opposite direction' is also what a market maker rebalancing
> looks like. A sandwich is defined by its victim. My tests missed it because every one of them
> advanced a block between swaps."

*Let the limitations list stay on screen.*

> "That's on the site, along with everything else it can't do. Sixty-nine tests, deployed, and the
> numbers are all links."

**End card:** hook address + repo URL. Hold 2 seconds.

---

## The 40-second cut

Drop the slider and the failure story. Keep: claim (0:09) → two pools (0:15) → live attack (0:16).

The two-pool proof is the one thing that cannot be cut. It is the answer to the criticism this
project exists to address, and it is the part with no obvious equivalent in the field.

---

## Narration notes

- **Say numbers as numbers.** "Sixteen times the base fee" beats "a much higher fee."
- **Never say "as you can see."** Either it's visible or the shot is wrong.
- **Don't explain EWMA.** Nobody watching a submission video wants the maths; they want to know
  whether it's real. The chart carries it.
- **Don't mention Orbitwork.** The lineage is a strong answer *to a question*, not an opening. It
  belongs in the written submission where a judge chooses to read it.
- **Let the pauses sit.** The instinct under time pressure is to fill every second; the two-pool
  numbers need three seconds of silence to be read.

## What not to claim

- Not "prevents sandwiches." Makes them unprofitable. The mechanism is at the exit and the site
  says so — contradicting it on camera is the fastest way to lose a technical judge.
- Not "audited." There is no audit.
- Not "production ready." Testnet, one deployment, 37,278 gas of overhead on every swap including
  honest flow.
