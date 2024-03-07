import {
  BigInt,
} from "@graphprotocol/graph-ts";
import { fetchAccount } from "@openzeppelin/subgraphs/src/fetch/account";
import { ERC721Token } from "../schema";
import { IERC721 } from "../erc721/IERC721";
import { Address } from "@graphprotocol/graph-ts";
import { ERC721Contract } from "@openzeppelin/subgraphs/generated/schema";

export function fetchERC721Token(
  contract: ERC721Contract,
  identifier: BigInt
): ERC721Token {
  let id = contract.id.toHex().concat("/").concat(identifier.toHex());
  let token = ERC721Token.load(id);

  if (token == null) {
    token = new ERC721Token(id);
    token.contract = contract.id;
    token.identifier = identifier as BigInt;
    token.approval = fetchAccount(Address.zero()).id;

    if (contract.supportsMetadata) {
      let erc721 = IERC721.bind(Address.fromBytes(contract.id));
      let try_tokenURI = erc721.try_tokenURI(identifier);
      token.uri = try_tokenURI.reverted ? "" : try_tokenURI.value;
    }
  }

  return token as ERC721Token;
}
