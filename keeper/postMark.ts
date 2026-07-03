import { ethers } from "ethers";
// PUT  mark = Σ 2^-i · BS_put(K, τ_i)
// CALL mark = Σ 2^-i · [BS_call(K, τ_i) − BS_call(K_hi, τ_i)]   (vertical spread, bounded by W)
const RPC = process.env.HYPEREVM_TESTNET_RPC!;
const KEEPER_PK = process.env.KEEPER_PRIVATE_KEY!;
const SIGMA = Number(process.env.SIGMA ?? "0.9");
const N = 12, PERIOD = 3600, YEAR = 31_536_000;
const MARKETS = [process.env.PUT_MARKET_ADDRESS!, process.env.CALL_MARKET_ADDRESS!].filter(Boolean);
const ABI = [
  "function K() view returns (uint256)",
  "function W() view returns (uint256)",
  "function side() view returns (uint8)",
  "function intrinsicWad() view returns (uint256)",
  "function oracle() view returns (address)",
  "function postMark(uint256) external",
];
const OABI = ["function spotWad() view returns (uint256)"];

function normCdf(x: number){ const t=1/(1+0.2316419*Math.abs(x)); const d=0.3989423*Math.exp(-x*x/2);
  let p=d*t*(0.3193815+t*(-0.3565638+t*(1.781478+t*(-1.821256+t*1.330274)))); return x>0?1-p:p; }
function bsPut(S:number,K:number,sig:number,tau:number){ if(tau<=0)return Math.max(K-S,0);
  const d1=(Math.log(S/K)+0.5*sig*sig*tau)/(sig*Math.sqrt(tau)); const d2=d1-sig*Math.sqrt(tau);
  return K*normCdf(-d2)-S*normCdf(-d1); }
function bsCall(S:number,K:number,sig:number,tau:number){ if(tau<=0)return Math.max(S-K,0);
  const d1=(Math.log(S/K)+0.5*sig*sig*tau)/(sig*Math.sqrt(tau)); const d2=d1-sig*Math.sqrt(tau);
  return S*normCdf(d1)-K*normCdf(d2); }

async function postOne(addr:string, provider:ethers.Provider, wallet:ethers.Wallet){
  const m = new ethers.Contract(addr, ABI, wallet);
  const side = Number(await m.side());                 // 0 PUT, 1 CALL
  const K = Number(ethers.formatUnits(await m.K(), 18));
  const W = Number(ethers.formatUnits(await m.W(), 18));
  const KHI = K + W;                                   // CALL upper strike
  const oracle = new ethers.Contract(await m.oracle(), OABI, provider);
  const S = Number(ethers.formatUnits(await oracle.spotWad(), 18));
  let basket = 0;
  for (let i=1;i<=N;i++){ const tau=i*PERIOD/YEAR;
    basket += Math.pow(2,-i) * (side===0 ? bsPut(S,K,SIGMA,tau) : (bsCall(S,K,SIGMA,tau)-bsCall(S,KHI,SIGMA,tau))); }
  const intrinsic = side===0 ? Math.max(K-S,0) : Math.min(Math.max(S-K,0), W);
  let mark = Math.max(basket, intrinsic);              // mark >= intrinsic
  mark = Math.min(mark, W);                            // mark <= W
  const markWad = ethers.parseUnits(mark.toFixed(12), 18);
  const tx = await m.postMark(markWad);
  console.log(`postMark side=${side} S=${S} K=${K} W=${W} mark=${mark} tx=${tx.hash}`);
  await tx.wait();
}
async function main(){
  const p = new ethers.JsonRpcProvider(RPC);
  const w = new ethers.Wallet(KEEPER_PK, p);
  for (const a of MARKETS) await postOne(a, p, w);
}
main().catch(e=>{ console.error(e); process.exit(1); });
