import { createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { unichainSepolia } from "./chain";

/**
 * Injected-only on purpose.
 *
 * WalletConnect would need a project id, a relay round trip, and a modal bundle — all of which can
 * fail on an unknown machine in ways this project cannot debug from here. An injected connector
 * either finds a wallet or it doesn't, and the page stays useful without one: every read on this
 * site works with no wallet at all.
 */
export const wagmiConfig = createConfig({
  chains: [unichainSepolia],
  connectors: [injected()],
  transports: { [unichainSepolia.id]: http() },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
