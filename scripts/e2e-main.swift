// The main.swift of the e2e scratch package built by scripts/e2e-check.sh.
// Exercises the client generated from examples/petstore.openrpc.json against
// a mock transport that asserts the JSON-RPC request shapes.
import Foundation

struct MockTransport: JSONRPCTransport {
    let expectObjectParams: Bool
    let expectID: Bool
    let result: String

    func send(_ body: Data) async throws -> Data {
        let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        precondition(request["jsonrpc"] as? String == "2.0", "missing jsonrpc version")
        if expectObjectParams {
            precondition(request["params"] is [String: Any], "expected by-name (object) params")
        } else {
            precondition(request["params"] is [Any], "expected by-position (array) params")
        }
        guard expectID else {
            precondition(request["id"] == nil, "a notification must not carry an id")
            return Data()
        }
        let id = request["id"] as! Int
        return Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8)
    }
}

let petJSON = #"{"id":1,"name":"Tama","status":"sold-out","size":2,"parent":{"id":0,"name":"Mama"}}"#

// list_pets declares paramStructure by-name → params must be an object.
let pets = try await PetstoreClient(
    transport: MockTransport(expectObjectParams: true, expectID: true, result: "[\(petJSON)]")
).listPets(limit: 10)
precondition(pets.count == 1 && pets[0].name == "Tama")
print("listPets: OK (by-name)")

// get_pet declares paramStructure by-position → params must be an array.
// PetSize is an integer enum backed by Int raw values.
let pet = try await PetstoreClient(
    transport: MockTransport(expectObjectParams: false, expectID: true, result: petJSON)
).getPet(petId: 1)
precondition(pet.status == .soldOut)
precondition(pet.size == ._2)
// Recursive property: boxed storage, plain public API, value semantics.
precondition(pet.parent?.name == "Mama")
var copy = pet
copy.parent?.name = "Papa"
precondition(pet.parent?.name == "Mama" && copy.parent?.name == "Papa")
print("getPet: OK (by-position, integer enum, recursive property)")

// search_pets returns a oneOf union, decoded untagged.
let single = try await PetstoreClient(
    transport: MockTransport(expectObjectParams: false, expectID: true, result: petJSON)
).searchPets(query: "Tama")
guard case .pet(let match) = single, match.name == "Tama" else {
    fatalError("expected the .pet variant")
}
let multiple = try await PetstoreClient(
    transport: MockTransport(expectObjectParams: false, expectID: true, result: "[\(petJSON)]")
).searchPets(query: "Ta")
guard case .pets(let candidates) = multiple, candidates.count == 1 else {
    fatalError("expected the .pets variant")
}
print("searchPets: OK (oneOf union)")

// delete_pet declares no result → sent as a notification without an id.
try await PetstoreClient(
    transport: MockTransport(expectObjectParams: false, expectID: false, result: "unused")
).deletePet(petId: 1)
print("deletePet: OK (notification)")

// A server error must surface as JSONRPCError.server.
struct ErrorTransport: JSONRPCTransport {
    let code: Int
    func send(_ body: Data) async throws -> Data {
        Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":\#(code),"message":"boom"}}"#.utf8)
    }
}
do {
    _ = try await PetstoreClient(transport: ErrorTransport(code: -32601)).listPets()
    fatalError("expected an error")
} catch let JSONRPCError.server(error) {
    precondition(error.code == -32601)
    print("server error: OK (code=\(error.code))")
}

// get_pet declares PetNotFound, so its code maps to the typed error enum...
do {
    _ = try await PetstoreClient(transport: ErrorTransport(code: 40400)).getPet(petId: 999)
    fatalError("expected an error")
} catch let PetstoreError.petNotFound(error) {
    precondition(error.code == 40400)
    print("typed error: OK (petNotFound)")
}
// ...while undeclared codes still surface as JSONRPCError.server.
do {
    _ = try await PetstoreClient(transport: ErrorTransport(code: -32000)).getPet(petId: 999)
    fatalError("expected an error")
} catch let JSONRPCError.server(error) {
    precondition(error.code == -32000)
    print("undeclared error: OK (JSONRPCError.server)")
}

// Loopback: the generated server serves the generated client in-process.
struct LoopbackHandler: PetstoreHandler {
    func listPets(limit: Int?) async throws -> Pets {
        [Pet(id: 1, name: "Tama")]
    }
    func createPet(newPetName: String, newPetTag: String?) async throws -> Pet {
        Pet(id: 2, name: newPetName, tag: newPetTag)
    }
    func getPet(petId: Int) async throws -> Pet {
        guard petId == 1 else { throw PetstoreError.petNotFound() }
        return Pet(id: 1, name: "Tama", parent: Pet(id: 0, name: "Mama"), size: ._2)
    }
    func deletePet(petId: Int) async throws {}
    func searchPets(query: String) async throws -> SearchResult {
        .pets([Pet(id: 1, name: "Tama")])
    }
}

struct LoopbackTransport: JSONRPCTransport {
    let server: PetstoreServer
    func send(_ body: Data) async throws -> Data {
        await server.handle(body) ?? Data()
    }
}

let loopback = PetstoreClient(
    transport: LoopbackTransport(server: PetstoreServer(handler: LoopbackHandler()))
)
let served = try await loopback.getPet(petId: 1)
precondition(served.size == ._2 && served.parent?.name == "Mama")
let created = try await loopback.createPet(newPetName: "Koro", newPetTag: "shiba")
precondition(created.name == "Koro" && created.tag == "shiba")
try await loopback.deletePet(petId: 1)
guard case .pets(let candidates) = try await loopback.searchPets(query: "Ta"), candidates.count == 1 else {
    fatalError("expected the .pets variant")
}
do {
    _ = try await loopback.getPet(petId: 999)
    fatalError("expected an error")
} catch let PetstoreError.petNotFound(error) {
    precondition(error.code == 40400)
}
print("loopback: OK (generated server serving the generated client)")

// Batching: concurrent calls collect into one batch request, served by the
// generated server's batch handling.
let batcher = JSONRPCBatcher(
    transport: LoopbackTransport(server: PetstoreServer(handler: LoopbackHandler())),
    expecting: 2
)
let batchClient = PetstoreClient(transport: batcher)
async let batchedPet = batchClient.getPet(petId: 1)
async let batchedPets = batchClient.listPets()
let (firstResult, secondResult) = try await (batchedPet, batchedPets)
precondition(firstResult.name == "Tama" && secondResult.count == 1)
print("batch: OK (two calls in one request)")

// Peer connection: two JSONRPCConnections wired back-to-back; one side
// exposes the generated server, the other calls it with the generated client.
final class ConnectionBox: @unchecked Sendable {
    var connection: JSONRPCConnection?
}
let callerBox = ConnectionBox()
let servingSide = JSONRPCConnection(
    send: { data in await callerBox.connection?.receive(data) },
    requestHandler: { body in await PetstoreServer(handler: LoopbackHandler()).handle(body) }
)
let callingSide = JSONRPCConnection(send: { data in await servingSide.receive(data) })
callerBox.connection = callingSide

let peerClient = PetstoreClient(transport: callingSide)
let peerPet = try await peerClient.getPet(petId: 1)
precondition(peerPet.name == "Tama")
try await peerClient.deletePet(petId: 1)
do {
    _ = try await peerClient.getPet(petId: 999)
    fatalError("expected an error")
} catch let PetstoreError.petNotFound(error) {
    precondition(error.code == 40400)
}
print("peer connection: OK (bidirectional JSONRPCConnection)")
