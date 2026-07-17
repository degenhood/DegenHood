import {
  createDegenHoodClient,
  verifyLaunchPreparation
} from "@degenhood/sdk";
import {
  createPublicClient,
  http,
  type Address,
  type WalletClient
} from "viem";

const DEGENHOOD_API = "https://api.degenhood.fun";
const ROBINHOOD_CHAIN_ID = 4663;

type TokenMetadata = {
  name: string;
  symbol: string;
  description?: string;
  website?: string;
  x?: string;
  telegram?: string;
  imageURI?: string;
  templateId?: number;
};

type PrepareLaunchOptions = {
  account: Address;
  rpcUrl: string;
  token: TokenMetadata;
  walletClient: WalletClient;
};

export async function prepareDegenHoodLaunch({
  account,
  rpcUrl,
  token,
  walletClient
}: PrepareLaunchOptions) {
  const publicApi = createDegenHoodClient({ baseUrl: DEGENHOOD_API });
  const challenge = await publicApi.requestWalletChallenge({ wallet: account });

  // Your injected wallet owns this EIP-191 signature. DegenHood never receives its key.
  const signature = await walletClient.signMessage({
    account,
    message: challenge.message
  });
  const session = await publicApi.createWalletSession({
    challengeId: challenge.challengeId,
    signature
  });

  const creatorApi = createDegenHoodClient({
    baseUrl: DEGENHOOD_API,
    accessToken: session.accessToken
  });
  const preparation = verifyLaunchPreparation(
    await creatorApi.prepareLaunch({
      ...token,
      launcher: account,
      templateId: token.templateId ?? 2
    })
  );

  const rpc = createPublicClient({ transport: http(rpcUrl) });
  const chainId = await rpc.getChainId();
  if (chainId !== ROBINHOOD_CHAIN_ID) {
    throw new Error(`Expected Robinhood Chain ${ROBINHOOD_CHAIN_ID}, received ${chainId}`);
  }

  const transaction = {
    account,
    to: preparation.transaction.to as Address,
    data: preparation.transaction.data,
    value: 0n
  };
  const gasEstimate = await rpc.estimateGas(transaction);
  await rpc.call(transaction);

  // Still unsigned: signing, gas payment, and submission remain in the creator's wallet.
  return { preparation, gasEstimate, sessionExpiresAt: session.expiresAt };
}
