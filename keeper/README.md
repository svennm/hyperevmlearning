# Everlasting-Put Keeper

Off-chain keeper that computes the geometric-basket Black-Scholes mark price and posts it on-chain hourly via `postMark(uint256)`.

## Mark formula

```
P = Σ_{i=1..12} 2^{-i} · BS_put(S, K, σ, i·3600/31_536_000)
mark = clamp(P, intrinsic, K)
```

Slice-1 uses a hand-set constant `σ` (env `SIGMA`, default 0.90 = 90 % annualized).

## Install

```bash
cd keeper
npm install
```

## Environment variables

Copy `.env.example` (never commit `.env`):

| Variable | Description |
|---|---|
| `HYPEREVM_TESTNET_RPC` | HyperEVM testnet JSON-RPC URL |
| `KEEPER_PRIVATE_KEY` | Private key of the keeper wallet (funded with HYPE for gas) |
| `MARKET_ADDRESS` | Deployed `EverlastingPut` contract address |
| `SIGMA` | Annualized volatility as a decimal (default `0.9`) |

## Run once

```bash
npm run post
```

## Hourly scheduling

### cron (Linux / macOS)

```cron
0 * * * * cd /path/to/keeper && npm run post >> /var/log/everlasting-keeper.log 2>&1
```

Add with `crontab -e`.

### launchd (macOS)

Create `~/Library/LaunchAgents/com.everlasting.keeper.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.everlasting.keeper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/npm</string>
    <string>run</string>
    <string>post</string>
  </array>
  <key>WorkingDirectory</key><string>/path/to/keeper</string>
  <key>StartInterval</key><integer>3600</integer>
  <key>StandardOutPath</key><string>/tmp/everlasting-keeper.log</string>
  <key>StandardErrorPath</key><string>/tmp/everlasting-keeper.err</string>
</dict>
</plist>
```

Then: `launchctl load ~/Library/LaunchAgents/com.everlasting.keeper.plist`

## Security

- **Never commit** `.env`, private keys, or secrets.
- The keeper wallet only needs permission to call `postMark`; keep its balance minimal.
