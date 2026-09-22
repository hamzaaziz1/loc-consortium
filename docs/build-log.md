# build log

written as i go, wrong turns included. one entry per working session.

the point of this file is to keep the reasoning attached to the decisions while
it is still fresh. the ADRs record what was decided and why. this records what
it was actually like to build, what broke, and what i would do differently.

---

## session 1 — scoping, and finding out two of my requirements no longer exist

started with a spec for eight things: qbft network, onchain permissioning,
private CA with mutual TLS, tessera privacy groups, solidity contracts,
compose plus helm, ci, and docs.

two of those turned out to be built on besu features that have been removed.

### the discovery

tessera-based privacy was deprecated in besu 24.12.0. smart-contract-based
(onchain) permissioning was deprecated alongside it, together with proof of work
and fast sync. both were then actually removed in the 25.6.0 line — the changelog
entries are "Remove onchain permissioning #8597" and "Remove Tessera Privacy
feature #8369".

so on any current client, `--privacy-enabled` and
`--permissions-nodes-contract-enabled` are gone, not deprecated. the spec as
written could not be built.

### three options i considered

**A. pin to 25.5.x and build the original spec.** i would get the real consensys
permissioning contracts and real tessera privacy groups, and the
non-member-cannot-read test would be trivially real. rejected because the
flagship repo would be pinned to a sunset stack, and anyone who knows besu opens
with "you know that's removed".

**B. current besu, rebuild both features myself.** more work, and i am inventing
where i could be citing.

**C. B as the main line, plus a pinned legacy demo profile.**

chose **B**. the legacy profile in C would have been a nice flourish but it
splits attention across two stacks, and the thing worth demonstrating is the
rebuild, not the museum piece.

### then the part that changed the design

besu removed the permissioning contract hook but **kept the QBFT validator
contract hook**. in contract validator selection mode, the validator set is read
from a smart contract implementing
`getValidators() external view returns (address[] memory)`. still present in the
26.x line.

that split is now the spine of the repo:

- **validator set governance is fully on chain.** a vote in the Governor
  contract changes the validator set as a direct consequence. no operator in
  the loop, no way for an operator to diverge from the vote.
- **node and account allowlist governance is a reconciling controller.** the
  registry is still on chain, but a service watches its events and applies them
  to each node over the admin RPC, because that hook is gone.

one repo, two governance paths, and a concrete reason they differ. that is a
better story than following the tutorial would have been.

it also handed me a runbook entry for free. if validator quorum is lost and no
transaction can be mined to vote validators back in, the documented escape hatch
is a genesis `transitions` entry switching temporarily to `blockheader` selection
mode with a hand-specified set, then transitioning back once the contract is
repaired. that is the stalled-round recovery procedure, and it is real rather
than something i made up.

### open question i have not resolved

if the permissioning controller dies, does the network fail open or closed. my
instinct is closed with a bounded staleness window, but i have not thought
through what "closed" means for a node that is already connected. revisit at m4.

### sizing

4 validators, one per member plus a consortium operator, giving n = 3f + 1 with
f = 1. two non-validator RPC nodes so application traffic never touches block
production. one faulty validator is survivable, two halts the chain — which
makes validator availability a contractual obligation on members, not an
operational detail.

### environment

15.4 GB host, WSL capped at 7.5 GB by default. decided against raising it. every
besu JVM gets heap-capped instead so the whole stack fits on a modest laptop,
which is the right constraint for a repo other people will clone. revisit at m7
when prometheus and grafana land.

---

## session 2 — m0, repo skeleton and ci

nothing conceptually hard, but three things bit.

**foundry 1.7 flipped a flag.** `forge init --no-commit` is gone; not committing
is the default now and `--commit` is the opt-in.

**`forge init` wrote `.gitmodules` into `contracts/` instead of the repo root.**
git only reads that file from the root, so the forge-std submodule was
registered nowhere git would look. combined with a `contracts/lib/` line in my
`.gitignore`, the testing library was invisible to git entirely. anyone cloning
the repo would have got a project where `forge test` fails on a missing import.
fixed by removing both and running `git submodule add` from the root.

**`foundry.lock` revision mismatch.** the lock pinned the forge-std commit that
`forge init` pulled, but re-adding the submodule fetched current tip. deleted
the lock and let forge regenerate it from what is actually checked out.

### decisions worth remembering

`.gitattributes` went in the **first** commit. adding it later, after files are
tracked, means a renormalise commit touching everything.

pinned `solc = "0.8.28"` in `foundry.toml`. without it, my machine and the ci
runner can compile with different compilers and produce different bytecode,
which is not acceptable if anyone ever checks deployed bytecode against source.

pinned `evm_version = "shanghai"`. this has to line up with the fork settings in
the genesis file at m2. if the compiler emits an instruction the chain's fork
does not know, deployment fails with an unhelpful invalid opcode. shanghai gives
`PUSH0` without pulling in newer features we do not need.

`submodules: recursive` in the ci checkout. without it the runner gets an empty
`contracts/lib` and every test fails on a missing import while passing locally.

### state

three commits, ci green in 16 seconds, both jobs passing. ADRs 0001 and 0002
written. next is m1, the PKI.

doing PKI before the network exists is deliberate — certs are baked into node
config and connection strings, so retrofitting TLS means changing everything
twice, and it means the repo never contains a "no TLS for now" mode someone
might copy.
