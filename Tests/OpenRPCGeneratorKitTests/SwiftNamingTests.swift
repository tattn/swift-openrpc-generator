import Testing

@testable import OpenRPCGeneratorKit

@Suite struct SwiftNamingTests {
    @Test("Type names are converted to PascalCase")
    func typeName() {
        #expect(SwiftNaming.typeName("pet store") == "PetStore")
        #expect(SwiftNaming.typeName("list_pets") == "ListPets")
        #expect(SwiftNaming.typeName("pet") == "Pet")
        #expect(SwiftNaming.typeName("eth_getBalance") == "EthGetBalance")
        #expect(SwiftNaming.typeName("123abc") == "_123abc")
        #expect(SwiftNaming.typeName("") == "Value")
    }

    @Test("Member names are converted to camelCase and keywords are escaped")
    func memberName() {
        #expect(SwiftNaming.memberName("list_pets") == "listPets")
        #expect(SwiftNaming.memberName("pets.create") == "petsCreate")
        #expect(SwiftNaming.memberName("eth_getBalance") == "ethGetBalance")
        #expect(SwiftNaming.memberName("newPetName") == "newPetName")
        #expect(SwiftNaming.memberName("pending-review") == "pendingReview")
        #expect(SwiftNaming.memberName("IN_PROGRESS") == "inProgress")
        #expect(SwiftNaming.memberName("URLValue") == "urlValue")
        #expect(SwiftNaming.memberName("class") == "`class`")
        #expect(SwiftNaming.memberName("") == "value")
    }

    @Test("Colliding names get a numeric suffix applied before keyword escaping")
    func uniqueMemberName() {
        var used: Set<String> = []
        #expect(SwiftNaming.uniqueMemberName("limit", in: &used) == "limit")
        #expect(SwiftNaming.uniqueMemberName("limit", in: &used) == "limit2")
        #expect(SwiftNaming.uniqueMemberName("limit", in: &used) == "limit3")
        // The suffix joins the raw name, so no invalid `keyword`N identifiers appear.
        #expect(SwiftNaming.uniqueMemberName("class", in: &used) == "`class`")
        #expect(SwiftNaming.uniqueMemberName("class", in: &used) == "class2")
    }
}
