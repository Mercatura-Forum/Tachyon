"""venue_candid.py: the Candid the gateway speaks with the venue: the `place` argument's type, and reading the records and
variants ic-py decodes, which name a field or a tag by its text or by its Candid hash.

Attribution: Thebes Core Team.
"""
from ic.candid import Types, encode, decode  # noqa: F401  (re-exported for the gateway's modules)

P = Types.Principal
SideT = Types.Variant({"buy": Types.Null, "sell": Types.Null})
KindT = Types.Variant({k: Types.Null for k in ("limit", "market", "ioc", "fok", "stop", "stopLimit", "trailingStop")})
ValidityT = Types.Variant({k: Types.Null for k in ("day", "gtc", "gtd")})
SmpT = Types.Variant({k: Types.Null for k in ("cancelIncoming", "cancelResting", "cancelBoth")})
CapT = Types.Variant({"agency": Types.Null, "principal": Types.Null})
# the venue's `place` argument (venue/src/Venue.mo)
Place = Types.Record({"account": Types.Nat, "instrument": Types.Nat, "side": SideT, "kind": KindT, "qty": Types.Nat, "price": Types.Nat,
                      "stopPrice": Types.Nat, "peak": Types.Nat, "validity": ValidityT, "gtdDay": Types.Nat, "selfTrade": SmpT,
                      "capacity": CapT, "shortSale": Types.Bool, "clientRef": Types.Text, "oco": Types.Nat, "trail": Types.Nat})


def chash(name):
    """Candid's field hash of a name."""
    h = 0
    for ch in name.encode():
        h = (h * 223 + ch) % (2 ** 32)
    return h


def field(rec, name):
    """A record field from ic-py's decoding, which names a field by its text or by its hash."""
    if name in rec:
        return rec[name]
    k = "_" + str(chash(name))
    if k in rec:
        return rec[k]
    raise KeyError(f"{name} not in {list(rec)[:12]}")


def variant(v):
    """(tag, value) of a decoded variant, the tag as its text where it is one of the names the gateway reads."""
    (k, x), = v.items()
    for n in ("ok", "err", "Ok", "Err", "buy", "sell", "done"):
        if k == n or k == "_" + str(chash(n)):
            return n, x
    return k, x
