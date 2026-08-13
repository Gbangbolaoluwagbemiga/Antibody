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
export async function fetchHistory(hook: `0x${string}`, poolId: `0x${string}`, fromBlock: bigint): Promise<Point[]> {
  const [baseline, toxic] = await Promise.all([
    client.getLogs({ address: hook, event: BASELINE_UPDATED, args: { poolId }, fromBlock, toBlock: "latest" }),
    client.getLogs({ address: hook, event: TOXIC_FLOW, args: { poolId }, fromBlock, toBlock: "latest" }),
  ]);

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
