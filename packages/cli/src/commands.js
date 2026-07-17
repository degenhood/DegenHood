import { verifyLaunchPreparation, verifyV4FeeDeliveryPreparation } from "@degenhood/sdk";

export function verifyPreparationDocument(document) {
  const preparation = verifyLaunchPreparation(document);
  return {
    valid: true,
    chainId: preparation.chainId,
    factory: preparation.factory,
    launcher: preparation.request.launcher,
    requestDigest: preparation.requestDigest,
    predictedTokenAddress: preparation.predictedTokenAddress
  };
}

export async function simulatePreparation(document, { client }) {
  if (!client?.getChainId || !client?.estimateGas || !client?.call) throw new Error("RPC client is required");
  const preparation = verifyLaunchPreparation(document);
  const rpcChainId = await client.getChainId();
  if (rpcChainId !== preparation.chainId) {
    throw new Error(`Expected chain ${preparation.chainId}, received ${rpcChainId} from RPC`);
  }
  const transaction = {
    account: preparation.request.launcher,
    to: preparation.transaction.to,
    data: preparation.transaction.data,
    value: 0n
  };
  const gasEstimate = await client.estimateGas(transaction);
  await client.call(transaction);
  return {
    simulated: true,
    chainId: preparation.chainId,
    requestDigest: preparation.requestDigest,
    predictedTokenAddress: preparation.predictedTokenAddress,
    gasEstimate: gasEstimate.toString()
  };
}

export async function launchStatus(token, { client }) {
  if (!client?.getToken) throw new Error("DegenHood client is required");
  try {
    const record = await client.getToken(token);
    return {
      indexed: true,
      token,
      symbol: record.sym,
      launchId: record.launchId
    };
  } catch (error) {
    if (error.status === 404) return { indexed: false, token };
    throw error;
  }
}

export function inspectFeeDeliveryPreparation(document) {
  const preparation = verifyV4FeeDeliveryPreparation(document);
  return {
    token: preparation.token,
    symbol: preparation.symbol,
    beneficiary: preparation.beneficiary,
    earnings: preparation.earnings,
    steps: preparation.steps.map(({ id, label, transaction }) => ({ id, label, to: transaction.to }))
  };
}

export async function prepareFeeDelivery(token, { client }) {
  if (!client?.getFeeDeliveryPreparation) throw new Error("DegenHood client is required");
  return verifyV4FeeDeliveryPreparation(await client.getFeeDeliveryPreparation(token));
}
