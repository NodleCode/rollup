export function isValidSubdomain(name: string): boolean {
  const subdomainRegex = /^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/;
  return subdomainRegex.test(name);
}
