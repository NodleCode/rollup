import { toUtf8Bytes, ErrorDescription } from "ethers";

export function toLengthPrefixedBytes(
  sub: string,
  domain: string,
  top: string,
): Uint8Array {
  const totalLength = sub.length + domain.length + top.length + 3;
  const buffer = new Uint8Array(totalLength);

  let offset = 0;
  for (const part of [sub, domain, top]) {
    buffer.set([part.length], offset);
    buffer.set(toUtf8Bytes(part), offset + 1);
    offset += part.length + 1;
  }

  return buffer;
}

export function isParsableError(
  error: any,
): error is { data: string | Uint8Array } {
  return (
    error &&
    typeof error === "object" &&
    "data" in error &&
    error.data &&
    (typeof error.data === "string" || error.data instanceof Uint8Array)
  );
}

export type OffchainLookupArgs = {
  sender: string;
  urls: string[];
  callData: string;
  callbackFunction: string;
  extraData: string;
};

export function isOffchainLookupError(
  errorDisc: null | ErrorDescription,
): errorDisc is ErrorDescription & { args: OffchainLookupArgs } {
  return (
    errorDisc !== null &&
    typeof errorDisc.name === "string" &&
    errorDisc.name === "OffchainLookup" &&
    Array.isArray(errorDisc.args) &&
    typeof errorDisc.args[0] === "string" &&
    Array.isArray(errorDisc.args[1]) &&
    errorDisc.args[1].every((url: unknown) => typeof url === "string") &&
    typeof errorDisc.args[2] === "string" &&
    typeof errorDisc.args[3] === "string" &&
    typeof errorDisc.args[4] === "string"
  );
}
