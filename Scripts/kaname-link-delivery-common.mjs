import path from "node:path";

export function canonicalJSON(value) {
  if (Array.isArray(value)) {
    return `[${value.map((entry) => canonicalJSON(entry)).join(",")}]`;
  }
  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export function rejectUnexpectedKeys(value, allowedKeys, label, reject) {
  const unexpected = Object.keys(value).filter((key) => !allowedKeys.includes(key));
  if (unexpected.length > 0) {
    reject(`${label} has unsupported key(s): ${unexpected.sort().join(", ")}`);
  }
}

export function validateExternalFilePath(candidate, repositoryRoot, label, reject) {
  if (typeof candidate !== "string" || !path.isAbsolute(candidate)) {
    reject(`${label} must be an explicit absolute path outside the checkout`);
  }
  const resolved = path.resolve(candidate);
  const root = path.resolve(repositoryRoot);
  const relative = path.relative(root, resolved);
  const insideRoot =
    relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== "..");
  if (resolved === path.parse(resolved).root || insideRoot) {
    reject(`${label} must be outside the checkout and filesystem root`);
  }
  return resolved;
}

export function parseOptionPairs(arguments_, reject) {
  if (arguments_.length % 2 !== 0) {
    reject(`${arguments_.at(-1)} requires a value`);
  }
  const pairs = [];
  for (let index = 0; index < arguments_.length; index += 2) {
    const flag = arguments_[index];
    if (typeof flag !== "string" || !flag.startsWith("--")) {
      reject(`invalid option: ${String(flag)}`);
    }
    pairs.push([flag, arguments_[index + 1]]);
  }
  return pairs;
}

export function parseCommandOptions(
  arguments_,
  { commands, defaults, optionProperties },
  reject,
) {
  if (arguments_.length === 0 || arguments_.includes("--help") || arguments_.includes("-h")) {
    return { help: true };
  }
  const command = arguments_[0];
  if (!commands.includes(command)) reject(`unknown command: ${command}`);
  const options = { help: false, command, ...defaults };
  for (const [flag, value] of parseOptionPairs(arguments_.slice(1), reject)) {
    const property = optionProperties[flag];
    if (!property) reject(`unknown option: ${flag}`);
    options[property] = value;
  }
  return options;
}
