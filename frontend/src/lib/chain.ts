import { createPublicClient, http, parseAbiItem, defineChain } from "viem";
import type { Point } from "./types";

/** Unichain Sepolia — Uniswap's own testnet, and the hookathon's dedicated prize track. */
export const unichainSepolia = defineChain({
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://sepolia.unichain.org"] } },
  blockExplorers: { default: { name: "Uniscan", url: "https://sepolia.uniscan.xyz" } },
  testnet: true,
});

export const client = createPublicClient({ chain: unichainSepolia, transport: http() });

const BASELINE_UPDATED = parseAbiItem(
  "event BaselineUpdated(bytes32 indexed poolId, uint64 ewmaSizeRatio, uint64 ewmaDeviation, uint64 ewmaImpact, uint256 thresholdScore, uint32 sampleCount)"
);
const TOXIC_FLOW = parseAbiItem(
  "event ToxicFlowDetected(bytes32 indexed poolId, address indexed trader, uint8 signal, uint256 observedScore, uint256 thresholdScore, uint24 penaltyPips)"
);

const SIGNALS = ["None", "SandwichExit", "BlockReversal", "SizeAnomaly", "CrossPoolMemory"] as const;

/** Ratios are 1e18-scaled fractions of pool liquidity; the chart plots percent. */
const pct = (v: bigint) => Number(v) / 1e16;

/**
 * Rebuild the chart series straight from chain logs.
 *
 * The bundled snapshot exists so the page paints instantly and still works if the public RPC is
 * rate-limiting — but this is the real source, and a refresh here is what makes the demo live
 * rather than a screenshot of a past run.
 */
/** Unichain Sepolia's RPC rejects any `eth_getLogs` window wider than this. */
const MAX_LOG_RANGE = 9_000n;

/**
 * Page through `eth_getLogs` in bounded windows.
 *
 * A single fromBlock→latest query is the obvious implementation and it is a time bomb: the pool's
 * history sits at a fixed height, the chain advances ~1 block/second, so the span crosses the
 * 10,000-block cap a few hours after deployment and every later call fails. The page then falls
 * back to its bundled snapshot and quietly claims to be live. This demo has to still work weeks
 * from now, unattended, in front of someone who will not refresh twice.
 */
/** Inclusive block windows of at most MAX_LOG_RANGE, covering [from, to]. */
function windows(from: bigint, to: bigint): Array<{ fromBlock: bigint; toBlock: bigint }> {
  const out: Array<{ fromBlock: bigint; toBlock: bigint }> = [];
  for (let start = from; start <= to; start += MAX_LOG_RANGE) {
    const end = start + MAX_LOG_RANGE - 1n;
    out.push({ fromBlock: start, toBlock: end > to ? to : end });
  }
  return out;
}

export async function fetchHistory(hook: `0x${string}`, poolId: `0x${string}`, fromBlock: bigint): Promise<Point[]> {
  const head = await client.getBlockNumber();
  const pages = windows(fromBlock, head);

  // Paged inline rather than through a generic helper: viem derives `args` from the event literal,
  // and routing both events through one generic collapses that back to `unknown`.
  const baseline = (
    await Promise.all(
      pages.map((w) => client.getLogs({ address: hook, event: BASELINE_UPDATED, args: { poolId }, ...w }))
    )
  ).flat();
  const toxic = (
    await Promise.all(
      pages.map((w) => client.getLogs({ address: hook, event: TOXIC_FLOW, args: { poolId }, ...w }))
    )
  ).flat();

  const detections = new Map(toxic.map((l) => [l.transactionHash, l.args]));

  return baseline
    .map((l) => {
      const a = l.args;
      const d = detections.get(l.transactionHash);
      return {
        n: Number(a.sampleCount),
        block: Number(l.blockNumber),
        tx: l.transactionHash,
        mean: pct(a.ewmaSizeRatio!),
        dev: pct(a.ewmaDeviation!),
        threshold: pct(a.thresholdScore!),
        impact: Number(a.ewmaImpact),
        signal: d ? SIGNALS[Number(d.signal)] : null,
        penalty: d ? Number(d.penaltyPips) : 0,
        observed: d ? pct(d.observedScore!) : null,
      } as Point;
    })
    .sort((x, y) => x.n - y.n);
}

const QUOTE_ABI = [
  {
    type: "function",
    name: "quote",
    stateMutability: "view",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "trader", type: "address" },
      { name: "zeroForOne", type: "bool" },
      { name: "amountAbs", type: "uint256" },
    ],
    outputs: [
      { name: "signal", type: "uint8" },
      { name: "totalFee", type: "uint24" },
      { name: "observedScore", type: "uint256" },
      { name: "thresholdScore", type: "uint256" },
    ],
  },
] as const;

export type Quote = { signal: number; totalFee: number; observed: number; threshold: number };

/**
 * Ask the deployed hook what it would charge a swap of this size, right now.
 *
 * This is a `view` — no wallet, no signature, no gas. It runs the exact same `_assess` the swap
 * path runs, so the number it returns is not a model of the mechanism, it *is* the mechanism.
 */
export async function quoteSwap(
  hook: `0x${string}`,
  poolId: `0x${string}`,
  trader: `0x${string}`,
  zeroForOne: boolean,
  amount: number
): Promise<Quote> {
  const [signal, totalFee, observedScore, thresholdScore] = await client.readContract({
    address: hook,
    abi: QUOTE_ABI,
    functionName: "quote",
    args: [poolId, trader, zeroForOne, BigInt(Math.round(amount * 1e18))],
  });
  return {
    signal: Number(signal),
    totalFee: Number(totalFee),
    observed: pct(observedScore),
    threshold: pct(thresholdScore),
  };
}

export type Activity = {
  poolLabel: string;
  poolId: string;
  n: number;
  block: number;
  tx: string;
  signal: string | null;
  penalty: number;
  observed: number | null;
  baseFee: number;
};

/**
 * Recent swaps across every pool the hook serves, newest first.
 *
 * Deliberately scoped to a short trailing window rather than the pool's whole history: this runs on
 * a timer, and re-reading thousands of blocks every few seconds to display twelve rows would be
 * rude to a public RPC and would eventually trip the same range limit that broke the history fetch.
 */
export async function fetchRecentActivity(
  hook: `0x${string}`,
  pools: Array<{ id: `0x${string}`; label: string }>,
  baseFee = 3000,
  lookback = 4_000n
): Promise<Activity[]> {
  const head = await client.getBlockNumber();
  const fromBlock = head > lookback ? head - lookback : 0n;

  const perPool = await Promise.all(
    pools.map(async ({ id, label }) => {
      const [baseline, toxic] = await Promise.all([
        client.getLogs({ address: hook, event: BASELINE_UPDATED, args: { poolId: id }, fromBlock, toBlock: head }),
        client.getLogs({ address: hook, event: TOXIC_FLOW, args: { poolId: id }, fromBlock, toBlock: head }),
      ]);
      const flagged = new Map(toxic.map((l) => [l.transactionHash, l.args]));

      return baseline.map((l) => {
        const d = flagged.get(l.transactionHash);
        return {
          poolLabel: label,
          poolId: id,
          n: Number(l.args.sampleCount),
          block: Number(l.blockNumber),
          tx: l.transactionHash,
          signal: d ? SIGNALS[Number(d.signal)] : null,
          penalty: d ? Number(d.penaltyPips) : 0,
          observed: d ? pct(d.observedScore!) : null,
          baseFee,
        } as Activity;
      });
    })
  );

  return perPool.flat().sort((a, b) => b.block - a.block || b.n - a.n);
}

const TOXIC_TOPIC = "0xef397c2c30f9f52aa55ab4cb080258bbf338e2909642e6a08e119f3e038be13c";

export type LegResult = {
  role: string;
  tx: `0x${string}`;
  block: number;
  signal: string | null;
  penalty: number;
};

/**
 * Watch one attack leg land and read the hook's verdict out of its receipt.
 *
 * Confirmation is the browser's job, not the server's — see the note in api/attack.ts. Doing it
 * here also means each leg can be revealed the moment it confirms.
 */
export async function watchLeg(role: string, tx: `0x${string}`): Promise<LegResult> {
  const receipt = await client.waitForTransactionReceipt({ hash: tx, timeout: 90_000 });
  const log = receipt.logs.find((l) => l.topics[0]?.toLowerCase() === TOXIC_TOPIC);

  let signal: string | null = null;
  let penalty = 0;
  if (log) {
    const d = log.data.slice(2);
    signal = SIGNALS[parseInt(d.slice(0, 64), 16)] ?? null;
    penalty = parseInt(d.slice(192, 256), 16);
  }

  return { role, tx, block: Number(receipt.blockNumber), signal, penalty };
}
