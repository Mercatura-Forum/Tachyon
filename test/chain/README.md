# The settlement and matching battery on a Thebes chain

1. Stand up a chain. Either point the manifest at an existing subnet's validators, or run a
   localhost chain from the production binaries:
   `thebes-deploy start --manifest test/chain/pocket.thebes.toml --no-facts`
   (four validators on 127.0.0.1:18480-18483; the chain persists across `stop`/`start`).
2. Create the two identities: `thebes-deploy identity new tachyon-maker` and
   `thebes-deploy identity new tachyon-taker`.
3. Write `test/chain/pocket.thebes.toml` from `deploy/example.thebes.toml`: the network's
   validators, the nine contracts, and an initial balance for each identity on the cash,
   shares and cash_flaky ledgers (`initial_balances` in each ledger's `init`). Pre-allocate
   distinct numeric cids and write the matching engines' init records with the principals
   those cids map to (8-byte big-endian; `cid_principal` in battery.py is the derivation).
   A manifest with only cash, shares, cash_flaky and core runs the settlement rows alone.
4. Build the wasms with `--legacy-persistence` (see the top-level README) and deploy:
   `thebes-deploy deploy --manifest test/chain/pocket.thebes.toml --network pocket --no-facts`.
   The identity that deploys is the core's installer (it binds the matching engine), the
   listing registry's venue admin, the land ledger's minting controller and the flaky
   ledger's switch owner; run the battery under the same identity.
5. `python3 test/chain/battery.py test/chain/pocket.thebes.toml pocket --out test/chain/out`

The battery runs the settlement rows (T1, T3, T4, T5, D1-D4), then, when the manifest
installs the matching engines, the M and L rows (the relayer gate, one uniform clearing
price against a Python twin of MatchLogic.mo, settlement of every obligation through the
core with exact per-fill-fee balance deltas, the chunked clear resumed by the engine's own
Timer, time priority, the all-or-none kill, adversarial refusals, the relayer rotation, and
the listing gate with its live funded checks), and T2 (no fork) last. The bed persists
between runs: the battery drains resting orders and stale obligations, then measures every
residual row against the holdings it read at the start of the run.

The manifest and the output directory are local to the chain and are not committed; the run
of record is `docs/chain-battery-<date>.log`.
