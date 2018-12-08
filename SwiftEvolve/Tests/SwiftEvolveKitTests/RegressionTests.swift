import XCTest
import SwiftSyntax
@testable import SwiftEvolveKit

struct UnusedGenerator: RandomNumberGenerator {
  mutating func next<T>() -> T where T : FixedWidthInteger, T : UnsignedInteger {
    XCTFail("RNG used unexpectedly")
    return 0
  }
}

class RegressionTests: XCTestCase {
  var unusedRNG = UnusedGenerator()

  func testUnshuffledDeclsStayInOrder() throws {
    // Checks that we don't mess up the order of declarations we're not trying
    // to shuffle. In particular, if we store the properties in a Set or other
    // unordered collection, we could screw this up.
    try SyntaxTreeParser.withParsedCode(
      """
      @_fixed_layout struct X {
        var p0: Int
        var p1: Int
        var p2: Int
        var p3: Int
        var p4: Int
        var p5: Int
        var p6: Int
        var p7: Int
        var p8: Int
        var p9: Int
      }
      """
    ) { code in
      let evo = ShuffleMembersEvolution(mapping: [])

      for node in code.filter(whereIs: MemberDeclListSyntax.self) {
        let evolved = evo.evolve(node)
        let evolvedCode = evolved.description

        let locs = (0...9).compactMap {
          evolvedCode.range(of: "p\($0)")?.lowerBound
        }

        XCTAssertEqual(locs.count, 10, "All ten properties were preserved")

        for (prev, next) in zip(locs, locs.dropFirst()) {
          XCTAssertLessThan(prev, next, "Adjacent properties are in order")
        }
      }
    }
  }

  func testStoredIfConfigBlocksMemberwiseInitSynthesis() throws {
    try SyntaxTreeParser.withParsedCode(
      """
      struct A {
        #if os(iOS)
          var a1: Int
        #endif
        var a2: Int { fatalError() }
      }
      """
    ) { code in
      for decl in code.filter(whereIs: StructDeclSyntax.self) {
        let dc = DeclContext(declarationChain: [code, decl])

        XCTAssertThrowsError(
          try SynthesizeMemberwiseInitializerEvolution(
            for: decl.members.members, in: dc, using: &unusedRNG
          ),
          "Should throw when a stored property is in a #if block"
        )
      }
    }

    try SyntaxTreeParser.withParsedCode(
      """
      struct B {
        var b1: Int
        #if os(iOS)
          var b2: Int { fatalError() }
        #endif
      }
      """
    ) { code in
      for decl in code.filter(whereIs: StructDeclSyntax.self) {
        let dc = DeclContext(declarationChain: [code, decl])

        XCTAssertNoThrow(
          try SynthesizeMemberwiseInitializerEvolution(
            for: decl.members.members, in: dc, using: &unusedRNG
          ),
          "Should not throw when properties are only non-stored"
        )
      }
    }

    try SyntaxTreeParser.withParsedCode(
      """
      struct C {
        #if os(iOS)
          var c1: Int
        #endif
        var c2: Int { fatalError() }
        init() { c1 = 1 }
      }
      """
    ) { code in
      for decl in code.filter(whereIs: StructDeclSyntax.self) {
        let dc = DeclContext(declarationChain: [code, decl])

        XCTAssertNoThrow(
          try SynthesizeMemberwiseInitializerEvolution(
            for: decl.members.members, in: dc, using: &unusedRNG
          ),
          "Should not throw when there's an explicit init"
        )
      }
    }
  }
}

extension SyntaxTreeParser {
  static func withParsedCode(
    _ code: String, do body: (SourceFileSyntax) throws -> Void
  ) throws -> Void {
    let url = try code.write(toTemporaryFileWithPathExtension: "swift")
    defer {
      try? FileManager.default.removeItem(at: url)
    }
    try body(parse(url))
  }
}

extension Syntax {
  func filter<T: Syntax>(whereIs type: T.Type) -> [T] {
    let visitor = FilterVisitor { $0 is T }
    walk(visitor)
    return visitor.passing as! [T]
  }
}

class FilterVisitor: SyntaxVisitor {
  let predicate: (Syntax) -> Bool
  var passing: [Syntax] = []

  init(predicate: @escaping (Syntax) -> Bool) {
    self.predicate = predicate
  }
  
  override func visitPre(_ node: Syntax) {
    if predicate(node) { passing.append(node) }
  }
}
