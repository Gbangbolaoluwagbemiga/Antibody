import { createPublicClient, http, defineChain, parseEther, encodeFunctionData } from "viem";
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
 * Co-location is probable, not guaranteed: a public testnet offers no bundle endpoint. The client
 * reports the block each leg actually landed in and says plainly which detector fired. A demo that
 * claimed the strong result regardless of what the chain did would be the exact dishonesty this
 * project was built to correct.
 *
 * ── Why it does not wait for receipts ─────────────────────────────────────────────────────────
 * Publishing takes ~2s; confirmation takes 15-30s. Waiting for all three inside the request would
 * push the function against its execution ceiling for no benefit, and a demo that times out under
 * load is worse than no demo. So this returns the hashes as soon as they are accepted and the
 * browser watches them land — which also lets the UI reveal each leg as it confirms rather than
 * dumping the whole result at once.
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

  // The public endpoint throttles datacenter IPs far harder than laptops, which is how this
  // function came to time out on Vercel while running fine locally. RPC_URL lets a dedicated
  // endpoint be swapped in from the dashboard without a redeploy of the code.
  const rpcUrl = process.env.RPC_URL || unichainSepolia.rpcUrls.default.http[0];
  const transport = http(rpcUrl, { timeout: 8_000, retryCount: 1 });
  const publicClient = createPublicClient({ chain: unichainSepolia, transport });

  const attacker = privateKeyToAccount(DEMO_ATTACKER_KEY as `0x${string}`);
  const victim = privateKeyToAccount(DEMO_VICTIM_KEY as `0x${string}`);

  const poolKey = {
    currency0: TOKEN0 as `0x${string}`,
    currency1: TOKEN1 as `0x${string}`,
    fee: DYNAMIC_FEE_FLAG,
    tickSpacing: 60,
    hooks: HOOK_ADDRESS as `0x${string}`,
  };
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

  // Every step is timed and returned. A 504 tells you nothing about which call hung; this does.
  const t0 = Date.now();
  const marks: Record<string, number> = {};
  const mark = (k: string) => { marks[k] = Date.now() - t0; };

  // ?dry=1 reads nonces and signs, but publishes nothing. Isolates "is the RPC reachable at all"
  // from "did the sends fail", without spending anything.
  const dry = new URL(req.url).searchParams.get("dry") === "1";
  const ATTACK = parseEther("2");
  const VICTIM = parseEther("0.1"); // inside the calibrated band, so the victim is not itself flagged

  try {
    const [an, vn] = await Promise.all([
      publicClient.getTransactionCount({ address: attacker.address }),
      publicClient.getTransactionCount({ address: victim.address }),
    ]);
    mark("nonces");

    // Sign all three offline, on the ACCOUNT rather than the wallet client.
    //
    // walletClient.signTransaction still makes a round trip per signature even with every field
    // supplied -- measured at ~270ms each against this endpoint. account.signTransaction is pure
    // local crypto and returns in under 2ms.
    //
    // This previously used prepareTransactionRequest, which looks up chain id and fee data per
    // transaction even when gas is fixed. Together with the client-side signing round trips that is
    // roughly fourteen calls against the public Unichain Sepolia endpoint, and it pushed the
    // function past Vercel's 60s ceiling: the deployed attack button returned
    // FUNCTION_INVOCATION_TIMEOUT while the identical code ran fine locally, because a datacenter
    // IP is throttled harder than a laptop. It is five calls now -- two nonce reads and three
    // sends -- and none of them are avoidable.
    //
    // Fees are hardcoded well above the measured 0.0005 gwei this chain actually charges. 0.05 gwei
    // is a hundred times that, which absorbs any spike, and at ~200k gas a leg still costs about
    // 0.00001 ETH -- the demo wallets fund hundreds of runs.
    const MAX_FEE = 50_000_000n; // 0.05 gwei
    const PRIORITY = 5_000_000n; // 0.005 gwei
    const common = {
      to: ROUTER,
      gas: 900_000n,
      maxFeePerGas: MAX_FEE,
      maxPriorityFeePerGas: PRIORITY,
      chainId: unichainSepolia.id,
      type: "eip1559",
    } as const;

    const [raw1, raw3, raw2] = await Promise.all([
      attacker.signTransaction({
        ...common,
        nonce: an,
        data: encodeSwap(ATTACK, true, attacker.address, poolKey, deadline),
      }),
      attacker.signTransaction({
        ...common,
        nonce: an + 1,
        data: encodeSwap(ATTACK, false, attacker.address, poolKey, deadline),
      }),
      victim.signTransaction({
        ...common,
        nonce: vn,
        data: encodeSwap(VICTIM, true, victim.address, poolKey, deadline),
      }),
    ]);

    mark("signed");

    if (dry) {
      return Response.json({ dry: true, rpc: rpcUrl, nonces: { attacker: an, victim: vn }, marks });
    }

    // Narrative order with a short stagger: the victim must land *between* the attacker's legs, and
    // the attacker's consecutive nonces guarantee the exit cannot execute before the entry.
    const p1 = publicClient.sendRawTransaction({ serializedTransaction: raw1 });
    await sleep(50);
    const p2 = publicClient.sendRawTransaction({ serializedTransaction: raw2 });
    await sleep(50);
    const p3 = publicClient.sendRawTransaction({ serializedTransaction: raw3 });

    const [h1, h2, h3] = await Promise.all([p1, p2, p3]);
    mark("published");

    return Response.json({
      marks,
      legs: [
        { role: "front-run", tx: h1 },
        { role: "victim", tx: h2 },
        { role: "exit", tx: h3 },
      ],
    });
  } catch (e) {
    lastRun = 0; // a failed run should not lock the button
    return Response.json(
      { error: e instanceof Error ? e.message : String(e), marks, rpc: rpcUrl },
      { status: 500 }
    );
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
