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
};
