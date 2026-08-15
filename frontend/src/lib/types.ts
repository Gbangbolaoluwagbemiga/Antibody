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
