# qp2 × cmux — integration reasoning (to be continued)

*Written 2026-09-03 by the cmux desk at hias's request, after reading
`~/qmp/docs/` end to end. **Nothing here is a decision.** It is the
reasoning as it stands, so the session that eventually picks this up
starts from evidence rather than from enthusiasm.*

## 1. What qmp has actually delivered (verified in the repo)

`~/qmp` is **qp2**, a user-owned cryptographic information network. It
formalises the **qee** line (`~/3tag/qee/docs/VISION.md`, 2026-05-26) via
**palma**'s `Q-META` — the lineage is written down in `docs/LINEAGE.md`,
which is itself a good sign: the project knows where its ideas came from.

- **Ratified constitution + primitives** — `PRIMITIVES.md`,
  `THREAT-MODEL.md`, and a `LIMITATIONS.md` with an enforcement rule that
  keeps it from becoming decoration.
- **A measured attack register** (`STATUS-MAP.md`), which is the
  substantial part, because the claims are *measured* rather than argued:
  - **Resists:** A18 time anchor (causal order by heads; timestamps
    demoted to tiebreak), Q1 cold-join, Q2 attested presence, Q3 sparse
    holder, Q4 partition, A3 forced proof (on a measured two-router
    path), A1 forged authorship.
  - **Does not resist:** A2 replay, A4 lying holder (omission reads as
    absence), A5 hostile witness (`accepts_presence_claim` is a stub),
    A6 backdated act (timestamp is attacker-controlled), A7, A10 nickname
    impersonation, A17 concurrency claim, L1–L4 substrate.
- **Two PoCs** — `poc/p2pstore` (A3/A4 preregistrations + results, network
  peer, proof envelope) and `poc/harness` (adversary engine,
  preregistration discipline, probes).

## 2. The question was already answered — by them, before we asked

`docs/SESSION-STATE-AS-QP2.md` §7, written 2026-09-02 *after* our wedge:

> **Build A3 (forced proof exchange), then T-7 (proof carriage). Do not
> build session state yet.** … Then cmux session state becomes qp2's
> first genuine dogfooding target.

Wiring qp2 into an agent harness now would be exactly the move their own
status map argues against, and the reason is arithmetic rather than
caution: **a substrate measured red on replay (A2) and backdating (A6)
must not carry authority over anyone's state.** The failure mode would be
silent, which is the class that cost this project two evenings running.

## 3. On "successor to cmux primitives regarding the wire"

The framing needs sharpening, and the sharpened version is more useful.

**cmux's wire today** is a local Unix socket speaking JSON-RPC v1/v2,
with single-machine trust: whoever can open the socket is the principal.
The feed is a local JSONL file. For what it does, that is correct — and
qp2 is **not** a successor to it. Replacing a local socket with a
cryptographic network buys nothing while there is only one principal.

**Where cmux genuinely stops is across machines.** The x12vm runs its own
instance with its own feed; letters do not cross; a desk on one machine
cannot make a verifiable claim to a desk on another. *That* gap is qp2's
subject — signed provenance, capability-scoped rooms, replication with no
broker to refuse.

So: **qp2 is a candidate for the wire cmux does not have yet, not a
replacement for the one it has.**

And the terminal half — panes, surfaces, scrollback, spawn, resume — is
OS-level work that stays whatever the network becomes. hias's instinct
on that was right.

## 4. The convergence that is already happening

`SESSION-STATE-AS-QP2.md` §1 notices something worth keeping: the cwd fix
this desk shipped on 2026-09-03 —

> never persist an empty value; make the substitution visible rather than
> silent

— **is qp2's typed-answer rule, derived independently in another domain.**
`""` collapsing into `$HOME` is `not-recorded` collapsing into `value`,
which their `lookup()` refuses six ways over (`value` / `absent` /
`not-synced` / `unserved` / `sealed` / `stale`, plus `unreachable`).

Neither desk knew about the other's work. That is the strongest available
evidence that the two lines belong together **eventually** — and also the
cheapest thing to harvest **now**, because a design rule costs no
dependency.

## 5. Recommendation as it stands

1. **Do not wire qp2 into the Pi harness (or any harness) yet.** A3 and
   T-7 are the gate, named by the people who measured the gaps.
2. **Adopt the typed-answer discipline in cmux immediately** — it is a
   code-review rule, not an integration. Audit for other places where
   "unknown" collapses into a plausible value. Known candidates: the
   auto-resume slot silently taken by the newest agent per surface; any
   `?? fallback` on persisted state.
3. **When A3 + T-7 go green, cmux session state is the first dogfood
   target** (their §7), and Pi extensions become a natural *second*
   surface — a tool that speaks the protocol, not the substrate.
4. **Name the boundary early, because it is cheap.** Write down the
   question cmux would ask a qp2 layer:
   *"what was this surface's cwd at time T, who says so, and how sure are
   we?"* — a typed answer, not a string. Both sides then build toward a
   named interface instead of an assumed one.

## 6. Why "fold the design, not the transport" applies to us too

qvision's banked conclusion about the old qee-core MQTT code — *fold the
design, not the transport; MQTT has a broker and ours cannot* — is the
same warning in our direction. If cmux imports a p2p substrate before it
needs one, it inherits assumptions it cannot honour (a broker, a witness,
a clock). The parts already folded — retained truth, history channels,
everything-is-a-qip, declarative — arrived as *ideas*, and that is the
transfer mechanism that has actually worked so far.

## 7. Open, for the session that continues this

- **Does cmux want a cross-machine wire at all, or is per-machine
  isolation a feature?** Nobody has argued the negative case yet. The VM
  being separate has never actually hurt.
- **What is the minimum qp2 surface a harness would need?** Probably not
  rooms or lenses — just "make a claim" and "read a typed answer".
- **Who owns the boundary document?** It is neither desk's territory
  today, which is how boundaries get assumed instead of designed.
- **What would falsify this whole direction?** Worth writing down before
  anyone is invested: e.g. if A3+T-7 need a witness quorum that a laptop
  pair cannot form, the cross-machine story changes shape entirely.
