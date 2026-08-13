// The main.swift of the e2e scratch package built by scripts/e2e-check.sh.
// Exercises the client generated from examples/features.openrpc.json:
// allOf merging, multi-type unions, mixed-type enums, and external
// cyclic references.
import Foundation

struct MockTransport: JSONRPCTransport {
    let result: String

    func send(_ body: Data) async throws -> Data {
        let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let id = request["id"] as! Int
        return Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8)
    }
}

func client(returning result: String) -> FeaturesClient {
    FeaturesClient(transport: MockTransport(result: result))
}

// allOf merge: Employee combines Person's and its own properties.
let employee = try await client(returning: #"{"name":"Hana","employeeId":42}"#).getEmployee()
precondition(employee.name == "Hana" && employee.employeeId == 42)
print("getEmployee: OK (allOf merge)")

// Multiple types normalize to an untagged union.
guard case .string("abc") = try await client(returning: #""abc""#).getId() else {
    fatalError("expected the .string variant")
}
guard case .int(7) = try await client(returning: "7").getId() else {
    fatalError("expected the .int variant")
}
print("getId: OK (multi-type union)")

// Mixed-type enum decodes by constant comparison.
let auto = try await client(returning: #""auto""#).getMode()
let zero = try await client(returning: "0").getMode()
let one = try await client(returning: "1").getMode()
precondition(auto == .auto && zero == ._0 && one == ._1)
print("getMode: OK (mixed-type enum)")

// Well-known string formats map to Foundation types.
let document = try await client(
    returning: """
        {"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F",\
        "createdAt":"2026-08-13T10:15:30.123Z",\
        "payload":"aGVsbG8=",\
        "link":"https://example.com/docs/1"}
        """
).getDocument()
precondition(document.id == UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
precondition(document.createdAt.timeIntervalSince1970 > 0)
precondition(document.payload == Data("hello".utf8))
precondition(document.link == URL(string: "https://example.com/docs/1"))
print("getDocument: OK (date-time / uuid / byte / uri formats)")

// The external cyclic schema is hoisted into components and boxed.
let tree = try await client(returning: #"{"label":"leaf","parent":{"label":"root"}}"#).getTree()
precondition(tree.label == "leaf" && tree.parent?.label == "root")
print("getTree: OK (external cyclic ref)")
