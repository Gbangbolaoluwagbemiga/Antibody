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

const SIGNALS = ["None", "SandwichExit", "BlockReversal", "SizeAnomaly"] as const;

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
