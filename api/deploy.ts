import { createWalletClient, createPublicClient, http, encodeDeployData } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { tempo as tempoChain } from 'viem/chains'
import { readFileSync } from 'fs'
import path from 'path'

const PRIVATE_KEY = process.env.SERVER_PRIVATE_KEY as `0x${string}`
const TREASURY    = '0xe8b03012e1d508574d1714b9dfe7d25f51d88ca9' as `0x${string}`
const USDC        = '0x20C000000000000000000000b9537d11c60E8b50' as `0x${string}`
const PATH_USD    = '0x20c0000000000000000000000000000000000000' as `0x${string}`
const RPC_URL     = 'https://rpc.tempo.xyz'

const account = privateKeyToAccount(PRIVATE_KEY)
console.log('Deploying from:', account.address)

const walletClient = createWalletClient({
  account,
  chain: tempoChain,
  transport: http(RPC_URL),
})

const publicClient = createPublicClient({
  chain: tempoChain,
  transport: http(RPC_URL),
})

const artifactPath = path.resolve(import.meta.dir, '../out/BountyMarket.sol/BountyMarket.json')
const artifact = JSON.parse(readFileSync(artifactPath, 'utf8'))
const deployData = encodeDeployData({
  abi: artifact.abi,
  bytecode: artifact.bytecode.object as `0x${string}`,
  args: [USDC, TREASURY],
})

console.log('Sending deployment tx...')

const hash = await walletClient.sendTransaction({
  data: deployData,
  gas: 3_000_000n,
  // Pay gas in pathUSD instead of native ETH
  // @ts-ignore — Tempo-specific field
  feeToken: PATH_USD,
})

console.log('Tx hash:', hash)
const receipt = await publicClient.waitForTransactionReceipt({ hash })

console.log('\n✓ BountyMarket deployed at:', receipt.contractAddress)
console.log(`\nBOUNTY_MARKET_ADDRESS=${receipt.contractAddress}`)
