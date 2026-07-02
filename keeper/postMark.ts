import { ethers } from "ethers";
// Basket: P = Σ_{i=1..N} 2^-i * BS_put(S,K,sigma,tau_i); tau_i = i * FUNDING_PERIOD (years)
// Slice-1: sigma is a hand-set constant (env SIGMA), later trailing realized vol.
const RPC = process.env.HYPEREVM_TESTNET_RPC!;
const KEEPER_PK = process.env.KEEPER_PRIVATE_KEY!;
const MARKET = process.env.MARKET_ADDRESS!;
const SIGMA = Number(process.env.SIGMA ?? "0.9");   // 90% annualized (HYPE ~ high vol)
const N = 12, PERIOD = 3600, YEAR = 31_536_000;
const ABI = [
  "function K() view returns (uint256)",
  "function intrinsicWad() view returns (uint256)",
  "function oracle() view returns (address)",
  "function postMark(uint256) external",
];
const OABI = ["function spotWad() view returns (uint256)"];

function normCdf(x: number){ // Abramowitz-Stegun
  const t = 1/(1+0.2316419*Math.abs(x));
  const d = 0.3989423*Math.exp(-x*x/2);
  let p = d*t*(0.3193815+t*(-0.3565638+t*(1.781478+t*(-1.821256+t*1.330274))));
  return x>0 ? 1-p : p;
}
function bsPut(S:number,K:number,sig:number,tau:number){
  if (tau<=0) return Math.max(K-S,0);
  const d1=(Math.log(S/K)+0.5*sig*sig*tau)/(sig*Math.sqrt(tau));
  const d2=d1-sig*Math.sqrt(tau);
  return K*normCdf(-d2)-S*normCdf(-d1);
}
async function main(){
  const p = new ethers.JsonRpcProvider(RPC);
  const w = new ethers.Wallet(KEEPER_PK, p);
  const m = new ethers.Contract(MARKET, ABI, w);
  const K = Number(ethers.formatUnits(await m.K(), 18));
  const oracle = new ethers.Contract(await m.oracle(), OABI, p);
  const S = Number(ethers.formatUnits(await oracle.spotWad(), 18));
  let basket = 0;
  for (let i=1;i<=N;i++){ basket += Math.pow(2,-i) * bsPut(S,K,SIGMA, i*PERIOD/YEAR); }
  const intrinsic = Math.max(K-S,0);
  let mark = Math.max(basket, intrinsic);          // enforce mark ≥ intrinsic
  mark = Math.min(mark, K);                         // enforce mark ≤ K
  const markWad = ethers.parseUnits(mark.toFixed(12), 18);
  const tx = await m.postMark(markWad);
  console.log(`postMark S=${S} K=${K} mark=${mark} tx=${tx.hash}`);
  await tx.wait();
}
main().catch(e=>{ console.error(e); process.exit(1); });
