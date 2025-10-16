export const FIND_HANDLE_OWNERSHIP = (
  name: string,
  handle: string,
  service: string,
) => `
    query FindHandleOwnership {
        eNs(filter: {
            completeName: {
            equalTo : "${name.toLowerCase()}"
            }
        }, first: 1) {
            nodes {
                completeName
                textRecords(filter: {
                    key: {
                        equalTo: "${service.toLowerCase()}"
                    },
                    value: {
                        equalTo: "${handle.toLowerCase()}"
                    }
                }) {
                    nodes {
                        key
                        value
                    }
                }
            }
        }
    }
`;
export type FindHandleOwnershipResponse = {
  data: {
    eNs: {
      nodes: {
        name: string;
        textRecords: {
          nodes: {
            key: string;
            value: string;
          }[];
        };
      }[];
    };
  };
};
