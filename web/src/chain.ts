import { createPublicClient, http, defineChain } from 'viem'
import abi from './abi.json'

export const tempo = defineChain({
  id: 4217,
  name: 'Tempo',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.tempo.xyz'] } },
})

export const CONTRACT = '0x0Abb6362735a87a9b940Bcd2b7a35ead9927E92d' as const

export { abi }

export const client = createPublicClient({
  chain: tempo,
  transport: http(),
  pollingInterval: 4000,
})

export function fmt(raw: bigint | string) {
  return `$${(Number(raw) / 1e6).toFixed(2)}`
}

export function shortAddr(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}
