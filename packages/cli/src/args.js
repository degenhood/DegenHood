const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const COMMANDS = {
  launch: new Set(["prepare", "verify", "simulate", "status"]),
  fees: new Set(["inspect", "prepare"])
};
const OPTIONS = new Set(["--file", "--account", "--api", "--access-token", "--rpc", "--token"]);

export function parseCliArgs(argv = []) {
  const [group, action, ...rest] = argv;
  if (!COMMANDS[group]?.has(action)) {
    throw new Error("DegenHood CLI only supports launch prepare/verify/simulate/status and fees inspect/prepare");
  }
  const parsed = { command: `${group}.${action}` };
  const keys = {
    "--file": "file",
    "--account": "account",
    "--api": "api",
    "--access-token": "accessToken",
    "--rpc": "rpc",
    "--token": "token"
  };
  for (let index = 0; index < rest.length; index += 2) {
    const option = rest[index];
    if (!OPTIONS.has(option)) throw new Error(`Unsupported option: ${option || "(empty)"}`);
    const value = rest[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`${option} requires a value`);
    parsed[keys[option]] = value;
  }
  if (group === "launch" && ["prepare", "verify", "simulate"].includes(action) && !parsed.file) {
    throw new Error("--file is required");
  }
  if (group === "launch" && action === "prepare" && !ADDRESS.test(parsed.account || "")) {
    throw new Error("--account must be a valid creator wallet address");
  }
  if ((group === "fees" || action === "status") && !ADDRESS.test(parsed.token || "")) {
    throw new Error("--token must be a valid token address");
  }
  return parsed;
}

export function buildLaunchInput(document, account) {
  if (!document || typeof document !== "object" || Array.isArray(document)) {
    throw new Error("token file must contain one JSON object");
  }
  return {
    ...document,
    launcher: account,
    tokenAdmin: document.tokenAdmin || account,
    feeAdmin: document.feeAdmin || account,
    beneficiary: document.beneficiary || account
  };
}
