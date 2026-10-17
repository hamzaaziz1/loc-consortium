# Deployed governance contracts

Chain 7753, local consortium.

| Contract | Address |
|---|---|
| MemberRegistry | 0x6A228198369D55fE8b9Bc69d68cfdc03011f85B5 |
| ValidatorSetView | 0x875f468833dFbbE7C3056cbFc0CaF9AbFc2BDef2 |
| Governor | 0x4209dcb375F2Af9186371906Aa56Ca06E43547Bb |

ValidatorSetView is the address QBFT reads the validator set from, fixed in
the genesis transitions block. Changing it means a coordinated restart of
every node, so treat it as permanent.
