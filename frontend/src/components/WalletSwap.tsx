import { useState } from "react";
import { motion } from "framer-motion";
import { parseEther, maxUint256 } from "viem";
import {
  useAccount,
  useConnect,
  useDisconnect,
  useReadContract,
  useWaitForTransactionReceipt,
  useWriteContract,
  useSwitchChain,
} from "wagmi";
import { ERC20_ABI, ROUTER_ABI, ROUTER, DYNAMIC_FEE_FLAG } from "../lib/abi";
import { unichainSepolia } from "../lib/chain";

/**
 * Swap against the live pool with your own wallet, and pay whatever fee the hook decides you owe.
 *
 * Reading a quote proves the hook has an opinion. Executing a swap proves the chain enforces it —
 * the fee that lands in the receipt is set by `beforeSwap`, not by anything this page controls.
 *
 * Every read on this site works without a wallet; this is strictly additive. The tokens are
 * unrestricted-mint mocks, so a visitor can fund themselves in one click rather than hunting a
 * faucet — the failure mode for a judge is otherwise "nice demo, can't try it".
 */

const EXPLORER = unichainSepolia.blockExplorers.default.url;

type Props = {
  hook: `0x${string}`;
  token0: `0x${string}`;
  token1: `0x${string}`;
  tickSpacing: number;
};

export function WalletSwap({ hook, token0, token1, tickSpacing }: Props) {
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors, isPending: connecting } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const { writeContractAsync, isPending: writing } = useWriteContract();

  const [amount, setAmount] = useState("0.1");
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>();
  const [error, setError] = useState<string | null>(null);

  const { data: receipt, isLoading: confirming } = useWaitForTransactionReceipt({ hash: txHash });

  const { data: balance, refetch: refetchBalance } = useReadContract({
    address: token0,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: token0,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: address ? [address, ROUTER] : undefined,
    query: { enabled: Boolean(address) },
  });

  const wrongChain = isConnected && chainId !== unichainSepolia.id;
  const parsed = (() => {
    try {
      return parseEther(amount || "0");
    } catch {
      return 0n;
    }
  })();
  const needsApproval = (allowance ?? 0n) < parsed;
  const needsTokens = (balance ?? 0n) < parsed;

  async function run(fn: () => Promise<`0x${string}`>) {
    setError(null);
    try {
      const hash = await fn();
      setTxHash(hash);
    } catch (e) {
      // Wallet rejections are routine, not failures worth shouting about.
      const msg = e instanceof Error ? e.message : String(e);
      setError(/User rejected|denied/i.test(msg) ? "Cancelled in wallet." : msg.split("\n")[0]);
    }
  }

  if (!isConnected) {
    return (
      <div className="ws-connect">
        <p className="sub" style={{ margin: 0 }}>
          Connect a wallet to swap against the live pool and pay the fee the hook sets for you.
          Everything else on this site works without one.
        </p>
        <button
          className="btn btn-primary"
          disabled={connecting || connectors.length === 0}
          onClick={() => connectors[0] && connect({ connector: connectors[0] })}
        >
          {connectors.length === 0 ? "No wallet detected" : connecting ? "Connecting…" : "Connect wallet"}
        </button>
      </div>
    );
  }

  return (
    <div className="ws">
      <div className="ws-head">
        <span className="chip">
          <span className="dot" />
          {address?.slice(0, 6)}…{address?.slice(-4)}
        </span>
        <button className="btn btn-ghost" onClick={() => disconnect()}>
          Disconnect
        </button>
      </div>

      {wrongChain ? (
        <div className="ws-warn">
          <span>Wrong network — this pool lives on Unichain Sepolia.</span>
          <button className="btn btn-primary" onClick={() => switchChain({ chainId: unichainSepolia.id })}>
            Switch network
          </button>
        </div>
      ) : (
        <>
          <label className="ws-field">
            <span>Swap amount (token0)</span>
            <input
              inputMode="decimal"
              value={amount}
              onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))}
            />
          </label>

          <div className="ws-balance">
            balance {balance != null ? (Number(balance) / 1e18).toFixed(3) : "—"} token0
          </div>

          <div className="ws-actions">
            {needsTokens && (
              <button
                className="btn"
                disabled={writing}
                onClick={() =>
                  run(async () => {
                    const h = await writeContractAsync({
                      address: token0,
                      abi: ERC20_ABI,
                      functionName: "mint",
                      args: [address!, parseEther("1000")],
                    });
                    setTimeout(() => refetchBalance(), 2500);
                    return h;
                  })
                }
              >
                1 · Get test tokens
              </button>
            )}

            {!needsTokens && needsApproval && (
              <button
                className="btn"
                disabled={writing}
                onClick={() =>
                  run(async () => {
                    const h = await writeContractAsync({
                      address: token0,
                      abi: ERC20_ABI,
                      functionName: "approve",
                      args: [ROUTER, maxUint256],
                    });
                    setTimeout(() => refetchAllowance(), 2500);
                    return h;
                  })
                }
              >
                2 · Approve router
              </button>
            )}

            <button
              className="btn btn-primary"
              disabled={writing || confirming || needsTokens || needsApproval || parsed === 0n}
              onClick={() =>
                run(() =>
                  writeContractAsync({
                    address: ROUTER,
                    abi: ROUTER_ABI,
                    functionName: "swapExactTokensForTokens",
                    args: [
                      parsed,
                      0n,
                      true,
                      {
                        currency0: token0,
                        currency1: token1,
                        fee: DYNAMIC_FEE_FLAG,
                        tickSpacing,
                        hooks: hook,
                      },
                      "0x",
                      address!,
                      BigInt(Math.floor(Date.now() / 1000) + 3600),
                    ],
                  })
                )
              }
            >
              {writing ? "Confirm in wallet…" : confirming ? "Landing…" : "3 · Swap"}
            </button>
          </div>
        </>
      )}

      {error && <p className="ws-error">{error}</p>}

      {txHash && (
        <motion.div className="ws-result" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}>
          <div>
            {confirming ? "waiting for the block…" : receipt?.status === "success" ? "swapped" : "reverted"}
          </div>
          <a href={`${EXPLORER}/tx/${txHash}`} target="_blank" rel="noreferrer">
            {txHash.slice(0, 10)}… ↗
          </a>
        </motion.div>
      )}

      <p className="footnote" style={{ marginTop: 12 }}>
        The fee applied to your swap is chosen by the hook in <code>beforeSwap</code> and enforced by
        the PoolManager. Nothing on this page can influence it — check the receipt.
      </p>
    </div>
  );
}
