# The exchange's foundation: members, instruments, sessions

The reference data every other part of the exchange reads: who may trade (members, their traders, house and client
accounts, each trader's right to trade per segment), what is traded (instruments with their segment, tick table, lot
and reference price) and when (each segment's session windows on the market's calendar, and the phase the scheduler
moves it to at the chain's clock). Built on the Thebes kernel as a pure core a contract composes: commands on a
certified log, folded into fixed-width rows in stable memory, nineteen command families frozen, fifteen of them under
four eyes.

```
exchange/src/          ExchangeTypes, ExchangeLogic (pure), ExchangeCanonical (the frozen bytes), ExchangeText (the
                       refusal codes in English and Arabic), ExchangeCore (catalogue, rows, validation, fold, lifecycle)
exchange/test/         the battery (Exchange.test.mo, WASI under wasmtime) and its off-chain check
exchange/integration/  the Python twin
exchange/tools/        check.sh, mutation_test.py and mutations.json, twin_control.sh
```

## The commands

| Command | Authority | What it does |
|---|---|---|
| `admitMember`, `setMemberStatus` | four eyes | a member by its code; suspended, reinstated, or expelled for good |
| `registerTrader`, `revokeTrader` | four eyes | a principal as a trader of an active member, once |
| `grantTradingRight`, `withdrawTradingRight` | four eyes | a trader's right to trade in a segment |
| `openAccount`, `closeAccount` | a trader of the member | a house account, or a client account carrying a 32-byte commitment to the client |
| `defineSegment`, `setSchedule` | four eyes | a segment's day as windows covering midnight to midnight without gap or overlap |
| `setRestDays`, `declareHoliday`, `setUtcOffset` | four eyes | the market's calendar and clock |
| `defineTickTable` | four eyes | price bands from zero, each band on the previous band's grid |
| `listInstrument`, `setInstrumentStatus`, `setLot` | four eyes | an instrument by its ISIN (ISO 6166 check digit), on its tick |
| `setReferencePrice` | the operator's system | the reference price on the tick, for a day |
| `advancePhase` | the scheduler | the segment moves to the phase its schedule names at the chain's clock; the act carries the market's day and second, refused unless they are the chain's at submission |

Every refusal is a stable code (`ExchangeText.code`) with an English and an Arabic text.

## Verification

`exchange/test/Exchange.test.mo`: the catalogue in both directions with its control; every family round-tripped and
hashed twice; an unknown family tag and an unknown vocabulary byte decode to nothing; every refusal code with both
texts, with a control; the market built under four eyes (the maker and a stranger refused, a second approval finding
nothing awaiting); 66 refusals, each leaving every row count, every id counter, the log's length and the fingerprint
where they were; the scheduler through every day of 2026 at every window boundary across two moves of the UTC offset
(1,785 acts executed, 3,325 refused as unchanged, 21 refused because the claimed second was not the chain's); who may
trade what; the replay. `exchange/test/Exchange.verify.sh` runs the Python twin, which recomputes every phase decision,
every ISIN check digit and every tick decision from the dumped inputs with its own code, and checks the summer-time
days against the calendar rule; `exchange/tools/twin_control.sh` plants three faults and requires the twin red on each;
`exchange/tools/mutation_test.py` applies ten mutants to the committed tree and requires the battery or its twin red
on each. The battery's transcript is judged on a chain by the test actor `custody/integration/VenueJudge.mo` (domain
`exchange`, configuration `custody/integration/judge/Exchange.json`).

```
mops install
exchange/tools/check.sh
exchange/test/run.sh
exchange/tools/twin_control.sh <battery log>
python3 exchange/tools/mutation_test.py
```

Attribution: Thebes Core Team.
