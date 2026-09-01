export type Point = {
  n: number;
  block: number;
  tx: string;
  mean: number;
  dev: number;
  threshold: number;
  impact: number;
  signal: string | null;
  penalty: number;
  observed: number | null;
};

export type History = {
  hook: string;
  poolId: string;
  chainId: number;
  minSamples: number;
  baseFee: number;
  maxTotalFee: number;
  points: Point[];
  sandwich: Sandwich;
  poolA: PoolMeta;
  poolB: PoolMeta;
  vaccination: VaccinationMeta;
  immunity: ImmunityMeta;
  mainnetReplay: MainnetReplayMeta;
  liquidityCase: LiquidityCaseMeta;
};

export type Leg = {
  role: "front-run" | "victim" | "exit";
  actor: "attacker" | "victim";
  amountIn: number;
  amountOut: number;
  tokenIn: string;
  tokenOut: string;
  fee: number;
  tx: string;
};

export type Sandwich = {
  block: number;
  baseFee: number;
  legs: Leg[];
  attackerNet: { t0: number; t1: number };
  feesWithAntibody: number;
  feesAtBaseOnly: number;
};

export type PoolMeta = {
  poolId: string;
  tickSpacing: number;
  regime: string;
  points?: Point[];
};

export type VaccinationMeta = {
  donor: string;
  recipient: string;
  block: number;
  tx: string;
  threshold: number;
  swapsObservedAtBirth: number;
};

/**
 * Cross-pool memory, as recorded at the time of the attack.
 *
 * The fee figures here are the values observed when the evidence was captured. The Immunity panel
 * re-reads both live rather than displaying these, so a viewer sees the memory as it stands now —
 * including after it has decayed, which is the honest thing for it to do.
 */
export type ImmunityMeta = {
  attacker: string;
  attackBlock: number;
  confirmedExits: number;
  /** Blocks over which the memory fades to nothing. Read from the contract. */
  window: number;
  step: number;
  maxRemembered: number;
  /** Captured at attack time, for the record. The panel prefers live reads. */
  strangerFee: number;
  attackerFee: number;
  poolNeverSaw: string;
};

/**
 * The one measurement on this site taken from data nobody here authored: real mainnet blocks,
 * scanned for the mechanical signature of a sandwich, replayed against the hook.
 */
export type MainnetReplayMeta = {
  source: string;
  blocksWithSwaps: number;
  blocksWithoutSandwich: number;
  sandwiches: number;
  caughtBySandwichExit: number;
  caughtByBlockReversal: number;
  missed: number;
};

/** The adoption argument, measured: what LPs kept that an attacker would otherwise have taken. */
export type LiquidityCaseMeta = {
  block: number;
  lpWithAntibody: number;
  lpAtBaseFee: number;
  upliftMultiple: number;
  gasOverhead: number;
};
