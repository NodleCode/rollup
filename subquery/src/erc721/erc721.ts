import { Account } from "../types";

export function fetchAccount(address: string): Account {
  let account = new Account(address);
  account.save();
  return account;
}