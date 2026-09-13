# The settlement battery on a Thebes chain

1. Stand up a chain (pocket-thebes, or any Thebes subnet) and create two identities:
   `thebes-deploy identity new tachyon-maker` and `thebes-deploy identity new tachyon-taker`.
2. Write `test/pocket/pocket.thebes.toml` from `deploy/example.thebes.toml`: the network's
   validators, the four contracts (`cash`, `shares`, `cash_flaky`, `core`), and an initial balance
   for each identity on the three ledgers (`initial_balances` in each ledger's `init`).
3. Build the wasms with `--legacy-persistence` (see the top-level README) and deploy:
   `thebes-deploy deploy --manifest test/pocket/pocket.thebes.toml --network pocket --no-facts`.
   Write the installed cids into the manifest (`thebes-deploy` writes them beside the manifest
   as `thebes.toml`).
4. `python3 test/pocket/battery.py test/pocket/pocket.thebes.toml pocket --out test/pocket/out`

The manifest and the output directory are local to the chain and are not committed; the run of
record is `docs/pocket-thebes-battery-<date>.log`.
