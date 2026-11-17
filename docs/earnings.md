# Does it pay?

Read this before you buy a board or leave a PC mining, to work out what you'll earn and what the power costs you.

Short answer: mining pays only when the power is free or cheap and the hardware is already yours. A board bought to mine never pays itself back.

## The formula

Your share of the coins a day is your hashrate over the network's, times the coins the network makes a day:

```text
XMR/day = H/s × 86 400 × block reward / network difficulty
```

86 400 is the seconds in a day. The network finds a block every 120 seconds on average, so its hashrate is the difficulty divided by 120. MoneroOcean takes no fee on PPLNS today. The luck of each round shifts the result a little, and the formula gives the average.

## Today's numbers

The difficulty and the block reward move every block. MoneroOcean's public API gives both, the reward in piconero, which the command divides by 1e12 to get XMR:

```bash
curl -fsSL https://api.moneroocean.stream/network/stats | jq '."18081" | {difficulty, reward_xmr: (.value / 1e12)}'
```

You need `jq`. The project never calls this API; you run it yourself when you want fresh numbers.

## A worked example

These are the numbers of 2026-11-16, with two cooled Raspberry Pi 5 in `eco` mining about 400 H/s each (see [Keep it cool](boards.md#keep-it-cool)).

| Value | On 2026-11-16 |
| --- | --- |
| Network difficulty | 858 690 000 000, about 7.16 GH/s for the whole network |
| Block reward | 0.617 XMR |
| Your hashrate | 800 H/s |
| XMR price | 479 EUR |

1. Coins a day: 800 × 86 400 × 0.617 / 858 690 000 000 ≈ 0.0000497 XMR.
2. Coins a month: 0.0000497 × 30.4 days ≈ 0.0015 XMR.
3. In euros: 0.0015 × 479 ≈ 0.72 EUR a month.

The difficulty is the raw number the API returns. Read it as 858.69 billion, not trillion, or you'll get a result a thousand times too small.

## What the power costs

A watt drawn all month is 0.73 kWh (730 hours):

```text
electricity a month = watts × 0.73 kWh × price per kWh
```

Measure the watts at the wall, with a plug-in meter. Give them to `make status` with your price per kWh, as in `make status WALL_WATTS=9.5 KWH_PRICE=0.25`, and it prints the cost per day (see [Dedicated board](boards.md#dedicated-board---mode)).

A Pi 5 in `eco` mines about 57 H/s per watt, so about 7 W at the wall for 400 H/s. That's an estimate until the wall power is measured: the board's own PMIC reading leaves out the power supply. Two boards at 7 W and 0.20 EUR/kWh cost 14 × 0.73 × 0.20 ≈ 2.04 EUR a month, nearly three times the 0.72 EUR they earn.

## Break-even

On the example's numbers, each H/s earns 0.72 / 800 ≈ 0.0009 EUR a month, and each watt costs 0.73 × 0.20 ≈ 0.146 EUR a month at 0.20 EUR/kWh. You break even at about 160 H/s per watt. A Pi 5 in `eco`, at about 57 H/s per watt, is well under it.

- At 0.20 EUR/kWh you lose money on the power. Redo the sum with your own price: break-even is about 8 H/s per watt for each cent a kWh costs you.
- With free power, from solar you'd waste or a flat-rate plug, every coin is gain.
- The hardware never pays back. Each board earns about 0.36 EUR a month, so a 100 EUR board needs more than twenty years to earn its price, even with free power. Mine on hardware you already own.

## Getting paid on MoneroOcean

MoneroOcean pays your wallet once your balance passes your payout threshold. You set the threshold on the pool's site, with your wallet address.

| Rule | Value |
| --- | --- |
| Lowest threshold | 0.003 XMR |
| Default threshold | 0.3 XMR |
| Payout fee | up to 0.0004 XMR, falling to 0 as the threshold rises to 4 XMR |

At a few hundred H/s the default threshold takes years to reach. Set a lower one, such as 0.01 XMR. The fee then takes a larger share of each payout, but you get paid at all.

## Bandwidth

Mining uses little data. A board used about 5 to 7.5 MB a day, 160 to 230 MB a month, measured through a WireGuard tunnel, so the tunnel's overhead is in the count.
