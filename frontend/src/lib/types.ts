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
  immunity: {
    window: number;
    step: number;
    maxRemembered: number;
    attacker: string;
    attackBlock: number;
    beforeFee: number;
    afterFee: number;
    strangerFee: number;
    confirmedExits: number;
  };
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
