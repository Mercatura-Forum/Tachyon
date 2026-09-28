# Thebes kernel

The custody module (`custody/`) builds against the Thebes kernel at commit `f7bfa41dbae1b102c32846b88be1779b825d28eb`.
The kernel's repository is private and is published separately; this directory names the dependency and the commit,
and the custody module type-checks and its batteries run once a checkout of the kernel at that commit is placed here
(`custody/tools/packages.sh` reads `vendor/thebes-kernel/src`, and `custody/tools/committed_tree.sh` refuses a
checkout at any other commit). The settlement core, the matching engine and the listing registry do not depend on it.
