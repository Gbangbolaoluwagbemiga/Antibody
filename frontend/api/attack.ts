import { createPublicClient, createWalletClient, http, defineChain, parseEther, encodeFunctionData } from "viem";
import { privateKeyToAccount } from "viem/accounts";

/**
 * Fire a real three-leg sandwich at the live pool and report what the hook did about it.
 *
 * This exists as a server function for one reason: the demo actors' keys cannot ship in a browser
 * bundle. Everything else on the site is a read and runs client-side.
 *
 * ── Why it signs first and publishes in parallel ──────────────────────────────────────────────
 * `SandwichExit` requires the attacker's two legs to share a block *with a third party's trade
 * between them* — that is what separates a sandwich from a round trip. Signing each transaction at
 * send time costs a network round trip apiece and spreads them across blocks, so all three are
 * signed up front and published together with a short stagger to fix arrival order.
 *
 * Co-location is probable, not guaranteed: a public testnet offers no bundle endpoint. The response
 * reports the block each leg actually landed in and says plainly which detector fired. A demo that
 * claimed the strong result regardless of what the chain did would be the exact dishonesty this
 * project was built to correct.
 */

export const config = { maxDuration: 60 };

const unichainSepolia = defineChain({
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://sepolia.unichain.org"] } },
  testnet: true,
});

const ROUTER = "0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba" as const;
const DYNAMIC_FEE_FLAG = 8388608;
const SIGNALS = ["None", "SandwichExit", "BlockReversal", "SizeAnomaly"] as const;

const ROUTER_ABI = [
  {
    type: "function",
    name: "swapExactTokensForTokens",
    stateMutability: "payable",
    inputs: [
      { name: "amountIn", type: "uint256" },
      { name: "amountOutMin", type: "uint256" },
      { name: "zeroForOne", type: "bool" },
      {
        name: "poolKey",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
      { name: "hookData", type: "bytes" },
      { name: "receiver", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [{ type: "int256" }],
  },
] as const;

const TOXIC_TOPIC = "0xef397c2c30f9f52aa55ab4cb080258bbf338e2909642e6a08e119f3e038be13c";

/** Best-effort throttle. Serverless instances are not shared, so this is a speed bump, not a lock —
 *  the real protection is that these are testnet funds and each run costs a fraction of a cent. */
let lastRun = 0;
const COOLDOWN_MS = 20_000;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export default async function handler(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return Response.json({ error: "POST only" }, { status: 405 });
  }

  const now = Date.now();
  if (now - lastRun < COOLDOWN_MS) {
    return Response.json(
      { error: "cooling down", retryInMs: COOLDOWN_MS - (now - lastRun) },
      { status: 429 }
    );
  }
  lastRun = now;

  const { DEMO_ATTACKER_KEY, DEMO_VICTIM_KEY, HOOK_ADDRESS, TOKEN0, TOKEN1 } = process.env;
  if (!DEMO_ATTACKER_KEY || !DEMO_VICTIM_KEY || !HOOK_ADDRESS || !TOKEN0 || !TOKEN1) {
    return Response.json({ error: "server not configured" }, { status: 500 });
  }

  const transport = http(unichainSepolia.rpcUrls.default.http[0]);
  const publicClient = createPublicClient({ chain: unichainSepolia, transport });

  const attacker = privateKeyToAccount(DEMO_ATTACKER_KEY as `0x${string}`);
  const victim = privateKeyToAccount(DEMO_VICTIM_KEY as `0x${string}`);
  const attackerWallet = createWalletClient({ account: attacker, chain: unichainSepolia, transport });
  const victimWallet = createWalletClient({ account: victim, chain: unichainSepolia, transport });

  const poolKey = {
    currency0: TOKEN0 as `0x${string}`,
    currency1: TOKEN1 as `0x${string}`,
    fee: DYNAMIC_FEE_FLAG,
    tickSpacing: 60,
    hooks: HOOK_ADDRESS as `0x${string}`,
  };
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const ATTACK = parseEther("2");
  const VICTIM = parseEther("0.1"); // inside the calibrated band, so the victim is not itself flagged

  try {
    const [an, vn] = await Promise.all([
      publicClient.getTransactionCount({ address: attacker.address }),
      publicClient.getTransactionCount({ address: victim.address }),
    ]);

    // Sign all three up front so publishing costs no round trips.
    const [raw1, raw3, raw2] = await Promise.all([
      attackerWallet.signTransaction(
        await attackerWallet.prepareTransactionRequest({
          to: ROUTER,
          nonce: an,
          gas: 900_000n,
          data: encodeSwap(ATTACK, true, attacker.address, poolKey, deadline),
        })
      ),
      attackerWallet.signTransaction(
        await attackerWallet.prepareTransactionRequest({
          to: ROUTER,
          nonce: an + 1,
          gas: 900_000n,
          data: encodeSwap(ATTACK, false, attacker.address, poolKey, deadline),
        })
      ),
      victimWallet.signTransaction(
        await victimWallet.prepareTransactionRequest({
          to: ROUTER,
          nonce: vn,
          gas: 900_000n,
          data: encodeSwap(VICTIM, true, victim.address, poolKey, deadline),
        })
      ),
    ]);

    // Narrative order with a short stagger: the victim must land *between* the attacker's legs, and
    // the attacker's consecutive nonces guarantee the exit cannot execute before the entry.
    const p1 = publicClient.sendRawTransaction({ serializedTransaction: raw1 });
    await sleep(50);
    const p2 = publicClient.sendRawTransaction({ serializedTransaction: raw2 });
    await sleep(50);
    const p3 = publicClient.sendRawTransaction({ serializedTransaction: raw3 });

    const [h1, h2, h3] = await Promise.all([p1, p2, p3]);
    const receipts = await Promise.all(
      [h1, h2, h3].map((hash) => publicClient.waitForTransactionReceipt({ hash, timeout: 45_000 }))
    );

    const legs = receipts.map((r, i) => {
      const log = r.logs.find((l) => l.topics[0] === TOXIC_TOPIC);
      let signal: string | null = null;
      let penalty = 0;
      if (log) {
        const d = log.data.slice(2);
        signal = SIGNALS[parseInt(d.slice(0, 64), 16)] ?? null;
        penalty = parseInt(d.slice(192, 256), 16);
      }
      return {
        role: ["front-run", "victim", "exit"][i],
        tx: r.transactionHash,
        block: Number(r.blockNumber),
        signal,
        penalty,
      };
    });

    const sameBlock = legs[0].block === legs[2].block;
    return Response.json({
      legs,
      sameBlock,
      caught: legs[2].signal === "SandwichExit",
      note: sameBlock
        ? "The attacker's legs shared a block, so the strong detector was reachable."
        : "The legs split across blocks, so this was not a sandwich and the hook correctly declined to call it one. Run it again.",
    });
  } catch (e) {
    lastRun = 0; // a failed run should not lock the button
    return Response.json({ error: e instanceof Error ? e.message : String(e) }, { status: 500 });
  }
}

function encodeSwap(
  amountIn: bigint,
  zeroForOne: boolean,
  receiver: `0x${string}`,
  poolKey: {
    currency0: `0x${string}`;
    currency1: `0x${string}`;
    fee: number;
    tickSpacing: number;
    hooks: `0x${string}`;
  },
  deadline: bigint
): `0x${string}` {
  return encodeFunctionData({
    abi: ROUTER_ABI,
    functionName: "swapExactTokensForTokens",
    args: [amountIn, 0n, zeroForOne, poolKey, "0x", receiver, deadline],
  });
}
