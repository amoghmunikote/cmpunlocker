# ECC support (SHELVED — SM/SRAM + reporting only; DRAM ECC not achievable on CMP-fused cards)

This branch captures the ECC work. Two patches, both prod-portable (pure open-driver + the SEC2 Booter
mechanism already used for the PCIe unlocks):

- **`ecc-enable.patch`** — adds `FEAT_OVR_ECC_VAL` (`0x82380c = 0x00988999`) to the SEC2-Booter `xp3gTable`
  in `kernel_gsp.c` (the table `pcie-gen2.patch` builds; `FEAT_OVR_ECC_PLM` opens the PLM). Written at HS
  privilege at GSP boot, it enables the **SM-side ECC units** (SM_LRF / SM_L1_DATA / SM_L1_TAG / SM_CBU;
  nibbles `0x9`). LTC/DRAM are held **off** (nibbles `0x8` = override-disabled) on purpose — see below.
  Persists through GSP-RM init; `FEATURE_READOUT (0x823814) = 0x00027233` confirms the units are effective.

- **`ecc-reporting.patch`** — intercepts the ECC RM-control replies in `escape.c` (`NV_ESC_RM_CONTROL`
  chokepoint) so `nvidia-smi` reports **ECC Mode: Enabled** with clean counters. Needed because GA100 CMP
  GSP firmware returns "ECC not supported": the deciding control is `GET_INFOROM_OBJECT_VERSION` (`0x2080014b`)
  for object `"ECC"`, which returns OBJECT_NOT_FOUND — the hook returns a valid version, plus handles
  `QUERY_INFOROM_ECC_SUPPORT` / `QUERY_ECC_STATUS` / `QUERY_ECC_CONFIGURATION` / `GET_UNREPAIRABLE_MEMORY_FLAG`.

## Why DRAM (HBM) ECC is NOT here
Real DRAM ECC would need valid checkbits laid down by **devinit** (RM never re-scrubs the whole FB on GA100),
which requires ECC on **before** devinit — i.e. the `OPT_ECC_EN` fuse (0x820228) blown. On these cards that
fuse is **off** and locked hard: `SEC_FBPA_ECC_WR_SECURE` / `SEC_FEATURE_OVERRIDE_ECC_WR_SECURE` /
`SEC_SRAM_ECC_WR_SECURE` all blown, plus DSOV / SBFE / PRIV_SEC_EN. Separately, RM's `fbEccPreInit` SKU gate
(in signed GSP-RM) refuses to manage DRAM ECC while the VBIOS `SKU_SUPPORTS_ECC` flag is clear — and that
flag sits inside the FWSEC-signed VBIOS span `[0x2200,0x43A00)`, so an edit won't POST (no signature gap).
Runtime-toggling `MASTER_EN` storms (unscrubbed checkbits) and wedged the host once. Net: DRAM ECC is gated
in fuses + firmware; the only lever is the community's hardware fuse-glitch (burn `OPT_ECC_EN`), out of scope
here. So this branch ships the genuinely-working SM/SRAM ECC + reporting and is **canned** at that.
