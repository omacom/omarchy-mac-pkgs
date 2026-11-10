---
title: Status
description: What the first release of the Apple Silicon stack ships, and what is deliberately left out of it.
section: Reference
---

Omarchy 4.5 is the first release of this stack: its Mac packages are on the `stable` channel, and the installer's stable catalog is published. The packages are built here, in omacom/omarchy-mac-pkgs, for official Omarchy, which took in the generic Mac changes through [omacom/omarchy#14431](https://github.com/omacom/omarchy/pull/14431), following [the convergence spec](https://github.com/omacom/omarchy-mac/blob/quattro-upstream/docs/apple-silicon-convergence.md).

## In the first release

- M1 and M2 Macs. The stable catalog also admits M3 Macs and the MacBook Neo, each marked untested. See [Hardware support]({{page:hardware}}).
- Touch ID, experimental and off until you turn it on, on MacBooks with an M2, M2 Pro or M2 Max, the M3 MacBook Air and the MacBook Neo. M1-family Macs are not offered it yet: their Secure Enclave starts behind a guard that blocks matching. See [Encryption and passwords]({{page:security}}).

## Still to come

The move for existing Macs is switched on once it has been accepted for each kind of install. [Moving an existing Mac]({{page:migrate}}) says where it stands.

## Not in the first release

- M4 Macs, MLX and Secure Enclave disk encryption. Each is separate work.
- Encrypting an unencrypted Mac in place while moving it from an earlier install. It may come later as an opt-in.
- The Asahi kernel as a supported choice. Every Mac runs Aurora.
- A portable installer that runs without installing a privileged helper.
- Moving the installer's signing identity and catalog hosting to Omarchy's own. That is a later configuration change.

Known hardware issues are listed under [Hardware support]({{page:hardware}}).
